import UIKit
import AVFoundation
import Vision

/// FaceCaptureViewController — the iOS Capture SDK's internal camera flow.
final class FaceCaptureViewController: UIViewController {

    private let sdkConfig: VerisConfig
    private let sessionConfig: VerisSessionConfig
    private let features: VerisFeatureFlags
    private let sessionContext: SessionContext
    private let pipelineCoordinator: PipelineCoordinator

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var completion: ((VerisResult) -> Void)?
    private var resultDelivered = false
    private var retryCount = 0
    private var timeoutWorkItem: DispatchWorkItem?
    private var stableFrameCount = 0
    private var processedFrameIndex = 0
    private var bestSampleBuffer: CMSampleBuffer?
    private var bestQualityScore: Float = 0

    private lazy var voiceGuide = VoiceGuide(enabled: sdkConfig.voiceEnabled)
    private let injectionDetector = InjectionSignalDetector()

    // Active liveness (head turn / blink / nod). Created lazily once the quality
    // gate first passes, so warmup timing starts when the user is actually ready.
    private var livenessEngine: ActiveLivenessEngine?
    private var livenessPassed = false
    private var challengesCompleted: [String] = []
    private var activeChallengesRequired: Bool {
        pipelineCoordinator.policy.allowActiveChallenges && features.activeLiveness
    }
    private var challengeInProgress: Bool {
        activeChallengesRequired && !livenessPassed && livenessEngine != nil
    }

    private let qualityChecker = QualityChecker()
    private let frameSampler = FrameSampler()
    private var bestFaceBox: CGRect?
    private var passiveScore: Float = -1
    private var lastFaceCenter: CGPoint?
    private var lastTemporalScore: Float = 0
    private var currentInstruction = ""

    private let sessionQueue = DispatchQueue(label: "com.veris.ios.capture.session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "com.veris.ios.capture.analysis", qos: .userInitiated)
    private let instructionLabel = UILabel()
    private let overlayLayer = CAShapeLayer()

    private static weak var active: FaceCaptureViewController?

    init(
        sdkConfig: VerisConfig,
        sessionConfig: VerisSessionConfig,
        features: VerisFeatureFlags,
        sessionContext: SessionContext,
        pipelineCoordinator: PipelineCoordinator,
        completion: @escaping (VerisResult) -> Void
    ) {
        self.sdkConfig = sdkConfig
        self.sessionConfig = sessionConfig
        self.features = features
        self.sessionContext = sessionContext
        self.pipelineCoordinator = pipelineCoordinator
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use designated initialiser") }

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.active = self
        pipelineCoordinator.onSessionStarted()
        setupUI()
        setupCamera()
        scheduleTimeout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        overlayLayer.frame = view.bounds
        updateOverlay()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCamera()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !resultDelivered {
            deliver(.cancelled)
        }
    }

    private func setupUI() {
        view.backgroundColor = .black

        overlayLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        overlayLayer.fillColor = UIColor.clear.cgColor
        overlayLayer.lineWidth = 3
        view.layer.addSublayer(overlayLayer)

        instructionLabel.text = "Position your face in the oval"
        instructionLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        instructionLabel.textColor = .white
        instructionLabel.textAlignment = .center
        instructionLabel.numberOfLines = 2
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instructionLabel)

        NSLayoutConstraint.activate([
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -48),
            instructionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            instructionLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func updateOverlay() {
        let insetX = view.bounds.width * 0.18
        let insetY = view.bounds.height * 0.18
        let rect = view.bounds.insetBy(dx: insetX, dy: insetY)
        overlayLayer.path = UIBezierPath(ovalIn: rect).cgPath
    }

    private func setupCamera() {
        injectionDetector.inspectCameras()
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            if authStatus == .denied || authStatus == .restricted {
                DispatchQueue.main.async {
                    self.deliver(ResultAssembler.failure(.cameraPermissionDenied, retryable: false))
                }
                return
            }

            if authStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        self.setupCamera()
                    } else {
                        DispatchQueue.main.async {
                            self.deliver(ResultAssembler.failure(.cameraPermissionDenied, retryable: false))
                        }
                    }
                }
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                DispatchQueue.main.async {
                    self.deliver(ResultAssembler.failure(.cameraNotAvailable, retryable: false))
                }
                return
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            output.setSampleBufferDelegate(self, queue: self.analysisQueue)
            guard session.canAddOutput(output) else {
                DispatchQueue.main.async {
                    self.deliver(ResultAssembler.failure(.cameraNotAvailable, retryable: false))
                }
                return
            }
            session.addOutput(output)
            if let connection = output.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    connection.videoRotationAngle = 90
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }

            session.commitConfiguration()

            self.captureSession = session
            self.videoOutput = output

            DispatchQueue.main.async {
                let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                previewLayer.videoGravity = .resizeAspectFill
                previewLayer.frame = self.view.bounds
                self.view.layer.insertSublayer(previewLayer, at: 0)
                self.previewLayer = previewLayer
                self.pipelineCoordinator.onCameraReady()
                self.pipelineCoordinator.onQualityGateRunning()
                self.presentInstruction("Position your face in the oval")
            }

            session.startRunning()
        }
    }

    private func stopCamera() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
            self?.videoOutput = nil
        }
    }

    private func scheduleTimeout() {
        guard sessionConfig.sessionTimeoutSecs > 0 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deliver(ResultAssembler.failure(.sessionTimeout, retryable: false))
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(sessionConfig.sessionTimeoutSecs), execute: workItem)
    }

    private func presentInstruction(_ text: String) {
        guard text != currentInstruction else { return }
        currentInstruction = text
        DispatchQueue.main.async {
            self.instructionLabel.text = text
        }
        voiceGuide.speak(text)
    }

    private func analyse(sampleBuffer: CMSampleBuffer, faceObservation: VNFaceObservation) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let boundingBox = faceObservation.boundingBox
        let signals = makeSignals(from: faceObservation)
        var rollDeg: Float = 0
        if let roll = faceObservation.roll { rollDeg = Float(truncating: roll) * 180 / .pi }

        // ── Quality gate (Layer 1) ───────────────────────────────────────────
        // Pose and eye checks are suspended during active challenges — nodding and
        // blinking are exactly what the challenge asks for.
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let qc = qualityChecker.evaluate(
            QualityChecker.Input(
                faceCount: 1,
                faceBox: boundingBox,
                yawDeg: signals.yawDeg,
                pitchDeg: signals.pitchDeg,
                rollDeg: rollDeg,
                leftEyeOpen: signals.leftEyeOpen,
                rightEyeOpen: signals.rightEyeOpen,
                frameGray64: frameSampler.gray(from: pixelBuffer, normRect: unitRect, width: 64, height: 64),
                frameGray32: frameSampler.gray(from: pixelBuffer, normRect: unitRect, width: 32, height: 32),
                faceGray16: frameSampler.gray(from: pixelBuffer, normRect: boundingBox, width: 16, height: 16)
            ),
            minPassScore: sessionConfig.minQualityScore,
            ignorePose: challengeInProgress,
            ignoreEyesClosed: challengeInProgress
        )

        if qc.isStaticImage {
            deliver(ResultAssembler.failure(.staticFrameDetected, retryable: false))
            return
        }

        let temporal = evaluateTemporal(boundingBox: boundingBox)
        let spoofRisk = temporal.passed ? 0.12 as Float : 0.36 as Float
        let challengeRequired = activeChallengesRequired

        pipelineCoordinator.onAccumulating()

        let presence = PresenceResult(passed: qc.passed, qualityScore: qc.score,
                                      failReason: qc.passed ? nil : qc.instruction)
        let escalation = EscalationResult(
            passed: livenessPassed || !challengeRequired,
            challengeRequired: challengeRequired
        )
        let fusion = FusionEngine.decide(
            bundle: EvidenceBundle(
                presence: presence,
                temporal: temporal,
                spoofArtifact: SpoofArtifactResult(passed: spoofRisk < 0.7, spoofRisk: spoofRisk),
                escalation: escalation
            )
        )
        lastTemporalScore = fusion.confidenceScore

        if !qc.passed {
            stableFrameCount = 0
            pipelineCoordinator.onQualityGateRunning()
            presentInstruction(qc.instruction)
            return
        }

        // ── Human face validation (Layer 3) ──────────────────────────────────
        // Suspended during challenges — head pitch legitimately distorts geometry.
        if features.humanValidation && !challengeInProgress {
            let aspect = view.bounds.height > 0
                ? view.bounds.width / view.bounds.height
                : 0.75
            let human = HumanFaceValidator.validate(
                face: faceObservation,
                leftEyeOpen: signals.leftEyeOpen,
                rightEyeOpen: signals.rightEyeOpen,
                imageAspect: aspect
            )
            if !human.passed {
                stableFrameCount = 0
                presentInstruction(human.instruction)
                return
            }
        }

        if qc.score > bestQualityScore {
            bestQualityScore = qc.score
            bestSampleBuffer = sampleBuffer
            bestFaceBox = boundingBox
        }

        // ── Active liveness ──────────────────────────────────────────────────
        if challengeRequired && !livenessPassed {
            pipelineCoordinator.onEscalating()
            runLivenessChallenge(faceObservation: faceObservation)
            return
        }

        presentInstruction("Hold still")
        stableFrameCount += 1
        let requiredFrames = max(sessionConfig.minStabilityFrames, 5)
        if stableFrameCount >= requiredFrames && fusion.decision == .pass {
            pipelineCoordinator.onDeciding()
            finishSuccess()
        }
    }

    private func runLivenessChallenge(faceObservation: VNFaceObservation) {
        if livenessEngine == nil {
            let count = sessionContext.plan == .pro || sessionContext.plan == .enterprise
                ? max(2, min(sessionConfig.proRandomChallengeCount, 4))
                : 1
            livenessEngine = ActiveLivenessEngine(challengeCount: count)
        }
        guard let engine = livenessEngine else { return }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let state = engine.process(signals: makeSignals(from: faceObservation), nowMs: nowMs)
        switch state {
        case .checking:
            break
        case .challenge(let prompt, _):
            presentInstruction(prompt)
        case .passed(let names):
            livenessPassed = true
            challengesCompleted = names
            stableFrameCount = 0
            presentInstruction("Hold still")
        case .failed:
            deliver(ResultAssembler.failure(.livenessTimeout, retryable: true))
        }
    }

    private func makeSignals(from face: VNFaceObservation) -> ActiveLivenessEngine.Signals {
        let box = face.boundingBox
        let yawDeg = Float(truncating: face.yaw ?? 0) * 180 / .pi
        var pitchDeg: Float = 0
        if #available(iOS 15.0, *) {
            pitchDeg = Float(truncating: face.pitch ?? 0) * 180 / .pi
        }

        var nosePoint: CGPoint?
        if let nose = face.landmarks?.nose, nose.pointCount > 0 {
            let pts = nose.normalizedPoints
            let avg = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let mean = CGPoint(x: avg.x / CGFloat(pts.count), y: avg.y / CGFloat(pts.count))
            // Landmark points are normalised within the face bounding box — map to image space.
            nosePoint = CGPoint(
                x: box.minX + mean.x * box.width,
                y: box.minY + mean.y * box.height
            )
        }

        return ActiveLivenessEngine.Signals(
            faceCount: 1,
            faceBox: box,
            nosePoint: nosePoint,
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            leftEyeOpen: eyeOpenness(face.landmarks?.leftEye),
            rightEyeOpen: eyeOpenness(face.landmarks?.rightEye)
        )
    }

    /// Eye-open probability from the eye landmark contour: height/width aspect ratio (EAR)
    /// mapped to 0–1. A closed eye flattens to EAR ≈ 0.05; fully open is ≈ 0.30+. The blink
    /// evaluator works on fractional drops from the user's own baseline so absolute
    /// calibration only needs to be monotonic.
    private func eyeOpenness(_ region: VNFaceLandmarkRegion2D?) -> Float {
        guard let region, region.pointCount >= 4 else { return -1 }
        let pts = region.normalizedPoints
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let width = maxX - minX
        guard width > 0.001 else { return -1 }
        let ear = Float((maxY - minY) / width)
        return min(max((ear - 0.06) / (0.24 - 0.06), 0), 1)
    }

    private func evaluateTemporal(boundingBox: CGRect) -> TemporalResult {
        let center = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
        defer { lastFaceCenter = center }
        guard let lastFaceCenter else {
            return TemporalResult(passed: sessionContext.plan == .starter, motionScore: sessionContext.plan == .starter ? 0.52 : 0.66)
        }
        let dx = center.x - lastFaceCenter.x
        let dy = center.y - lastFaceCenter.y
        let motion = sqrt((dx * dx) + (dy * dy))
        let motionScore = Float(min(max(motion * 18, 0.35), 0.92))
        let passed = sessionContext.plan == .starter || motion > 0.0035
        return TemporalResult(passed: passed, motionScore: motionScore)
    }

    private func finishSuccess() {
        guard !resultDelivered else { return }

        // ── Passive liveness (Layer 4) — single best-frame LBP texture analysis ──
        // Plan-aware gate matching Android's PassiveLivenessEvaluator: Pro hard-gates
        // only definitive spoofs (active liveness is the primary trust signal there);
        // other plans use the stricter floor.
        var occlusionNote = ""
        if features.passiveLiveness,
           let buffer = bestSampleBuffer,
           let pixelBuffer = CMSampleBufferGetImageBuffer(buffer),
           let faceBox = bestFaceBox {
            let skinRect = LBPLivenessAnalyzer.innerSkinRect(of: faceBox)
            if let gray = frameSampler.gray(from: pixelBuffer, normRect: skinRect, width: 64, height: 64) {
                let lbp = LBPLivenessAnalyzer.analyze(gray: gray)
                passiveScore = Float(lbp.score)
                let isPro = sessionContext.plan == .pro || sessionContext.plan == .enterprise
                let failFloor: Float = isPro ? 0.22 : 0.28
                if passiveScore < failFloor {
                    deliver(ResultAssembler.failure(.spoofingDetected, retryable: true))
                    return
                }
            }
            // Occlusion probe — shadow mode, advisory only: surfaced to the backend
            // via the signed payload, never blocks capture.
            let probe = LBPLivenessAnalyzer.probeOcclusion(
                sampler: frameSampler, pixelBuffer: pixelBuffer, faceBox: faceBox
            )
            if probe.eyesSuspect || probe.mouthSuspect {
                occlusionNote = String(
                    format: " occlusion(eye=%.2f mouth=%.2f)",
                    probe.eyeBandScore, probe.mouthBandScore
                )
            }
        }

        pipelineCoordinator.onResultPackaging()
        presentInstruction("Verified")

        let image    = bestSampleBuffer.flatMap(makeImage(from:)) ?? placeholderImage()
        let jpegData = image.jpegData(compressionQuality: 0.85) ?? Data()
        let injection = injectionDetector.snapshot()

        let livenessScore: Float = {
            if passiveScore >= 0 { return livenessPassed ? max(passiveScore, 0.75) : passiveScore }
            return livenessPassed ? max(lastTemporalScore, 0.75) : (features.passiveLiveness ? lastTemporalScore : 0)
        }()
        let injectionBase = injection.riskScore > 0.3
            ? "level=\(injection.cameraHardwareLevel) facing=\(injection.boundLensFacing)"
            : ""
        let signed = VerisResultSigner.sign(
            jpegData:           jpegData,
            qualityScore:       max(bestQualityScore, sessionConfig.minQualityScore),
            livenessScore:      livenessScore,
            nonce:              sessionConfig.nonce,
            environment:        sessionContext.environment,
            plan:               sessionContext.plan.rawValue,
            packageName:        Bundle.main.bundleIdentifier ?? "",
            challengesCompleted: challengesCompleted,
            licenseKeyId:       sessionContext.licenseKeyId,
            validationState:    sessionContext.validationState,
            injectionRisk:      injection.riskScore,
            injectionDetail:    (injectionBase + occlusionNote).trimmingCharacters(in: .whitespaces)
        )

        let result = ResultAssembler.success(
            SuccessEvidence(
                signedResult: signed.token,
                faceImage:    image,
                qualityScore: signed.qualityScore,
                livenessScore: features.passiveLiveness ? signed.livenessScore : nil,
                confidenceScore: lastTemporalScore
            )
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.deliver(result)
        }
    }

    private func makeImage(from sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .rightMirrored)
    }

    private func placeholderImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320))
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
            UIColor.white.setStroke()
            ctx.cgContext.setLineWidth(6)
            ctx.cgContext.strokeEllipse(in: CGRect(x: 60, y: 40, width: 200, height: 240))
        }
    }

    private func deliver(_ result: VerisResult) {
        guard !resultDelivered else { return }
        resultDelivered = true
        timeoutWorkItem?.cancel()
        pipelineCoordinator.onComplete()
        stopCamera()
        voiceGuide.stop()
        DispatchQueue.main.async { [weak self] in
            self?.completion?(result)
            self?.completion = nil
            self?.dismiss(animated: true)
        }
    }

    static func releaseCamera() {
        active?.stopCamera()
    }
}

extension FaceCaptureViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !resultDelivered else { return }

        let frameTime = CACurrentMediaTime()
        injectionDetector.onFrame(at: frameTime)

        processedFrameIndex += 1
        let stride = sessionContext.plan == .starter ? 5 : 3
        if processedFrameIndex % stride != 0 { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Landmarks request: provides bounding box + yaw/pitch + eye/nose contours,
        // all of which the active liveness engine consumes.
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])

        do {
            try handler.perform([request])
            let observations = request.results ?? []
            if observations.count != 1 {
                stableFrameCount = 0
                pipelineCoordinator.onQualityGateRunning()
                presentInstruction(observations.isEmpty ? "Position your face in the oval" : "Only one face please")
                return
            }
            analyse(sampleBuffer: sampleBuffer, faceObservation: observations[0])
        } catch {
            if retryCount >= pipelineCoordinator.policy.maxRetries {
                deliver(ResultAssembler.failure(.poorImageQuality, retryable: false))
            } else {
                retryCount += 1
            }
        }
    }
}
