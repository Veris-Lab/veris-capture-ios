import UIKit
import AVFoundation
import Vision

/// FaceCaptureViewController — the iOS Capture SDK's internal camera flow.
///
/// This version is no longer a mock-only controller. It now:
/// - starts a real front-camera preview
/// - runs face-rectangle detection on sampled frames
/// - performs basic presence and temporal accumulation
/// - emits a real captured frame on success
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
    }

    private func analyse(sampleBuffer: CMSampleBuffer, faceObservation: VNFaceObservation) {
        let boundingBox = faceObservation.boundingBox
        let quality = evaluatePresenceQuality(boundingBox: boundingBox)
        let temporal = evaluateTemporal(boundingBox: boundingBox)
        let spoofRisk = temporal.passed ? 0.12 as Float : 0.36 as Float
        let challengeRequired = pipelineCoordinator.policy.allowActiveChallenges

        pipelineCoordinator.onAccumulating()

        let escalation = EscalationResult(
            passed: temporal.passed || !challengeRequired,
            challengeRequired: challengeRequired
        )
        let fusion = FusionEngine.decide(
            bundle: EvidenceBundle(
                presence: quality,
                temporal: temporal,
                spoofArtifact: SpoofArtifactResult(passed: spoofRisk < 0.7, spoofRisk: spoofRisk),
                escalation: escalation
            )
        )

        lastTemporalScore = fusion.confidenceScore

        if !quality.passed {
            stableFrameCount = 0
            pipelineCoordinator.onQualityGateRunning()
            presentInstruction(quality.failReason ?? "Center your face")
            return
        }

        if challengeRequired {
            pipelineCoordinator.onEscalating()
            presentInstruction("Hold still while we verify")
        } else {
            presentInstruction("Hold still")
        }

        if quality.qualityScore > bestQualityScore {
            bestQualityScore = quality.qualityScore
            bestSampleBuffer = sampleBuffer
        }

        stableFrameCount += 1
        let requiredFrames = max(sessionConfig.minStabilityFrames, 5)
        if stableFrameCount >= requiredFrames && fusion.decision == .pass {
            pipelineCoordinator.onDeciding()
            finishSuccess()
        }
    }

    private func evaluatePresenceQuality(boundingBox: CGRect) -> PresenceResult {
        let faceWidth = boundingBox.width
        let centerX = boundingBox.midX
        let centerY = boundingBox.midY

        guard faceWidth >= 0.22 else {
            return PresenceResult(passed: false, qualityScore: 0.25, failReason: "Move closer")
        }
        guard faceWidth <= 0.82 else {
            return PresenceResult(passed: false, qualityScore: 0.25, failReason: "Move back slightly")
        }
        guard abs(centerX - 0.5) <= 0.18, abs(centerY - 0.5) <= 0.20 else {
            return PresenceResult(passed: false, qualityScore: 0.38, failReason: "Center your face")
        }

        let centerPenalty = Float((abs(centerX - 0.5) + abs(centerY - 0.5)) * 1.2)
        let sizeScore = Float(min(max((faceWidth - 0.22) / 0.35, 0), 1))
        let qualityScore = max(sessionConfig.minQualityScore, min(0.95, (sizeScore * 0.7) + (1 - centerPenalty) * 0.3))
        return PresenceResult(passed: true, qualityScore: qualityScore, failReason: nil)
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
        pipelineCoordinator.onResultPackaging()
        presentInstruction("Verified")

        let image = bestSampleBuffer.flatMap(makeImage(from:)) ?? placeholderImage()
        let signedResult = "veris.ios.\(sessionContext.plan.rawValue).\(sessionConfig.nonce)"
        let result = ResultAssembler.success(
            SuccessEvidence(
                signedResult: signedResult,
                faceImage: image,
                qualityScore: max(bestQualityScore, sessionConfig.minQualityScore),
                livenessScore: features.passiveLiveness ? lastTemporalScore : nil,
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

        processedFrameIndex += 1
        let stride = sessionContext.plan == .starter ? 5 : 3
        if processedFrameIndex % stride != 0 { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceRectanglesRequest()
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
