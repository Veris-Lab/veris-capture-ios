import Foundation
import AVFoundation

/// InjectionSignalDetector — heuristics against virtual-camera / frame-injection on iOS.
///
/// iOS equivalent of the Android InjectionSignalDetector. Two independent signals:
///   1. Camera hardware fingerprint (front camera present, not external/virtual)
///   2. Frame-cadence regularity (physical sensors always jitter; injected streams are metronomic)
///
/// Results are advisory — included in the signed payload for backend risk-scoring.
/// None of these are hard blocks.
internal final class InjectionSignalDetector {

    struct Report {
        let cameraHardwareLevel: String
        let boundLensFacing: String
        let hasFrontPhysicalCamera: Bool
        let frameIntervalCov: Float  // coefficient of variation; -1 until enough samples
        let metronomicFrames: Bool
        let riskScore: Float         // 0.0 (clean) – 1.0 (highly suspect)
    }

    private var frameDeltas: [TimeInterval] = []
    private var lastFrameTime: TimeInterval = 0
    private var hasFrontPhysical = true
    private var boundLensFacing = "unknown"
    private var hardwareLevel   = "unknown"

    private static let maxDeltas      = 40
    private static let minDeltas      = 20
    private static let metronomicCov  = Float(0.04)

    // MARK: - Camera inspection

    func inspectCameras() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .front
        )
        let frontDevices = session.devices
        hasFrontPhysical = !frontDevices.isEmpty
        if let front = frontDevices.first {
            boundLensFacing  = "front"
            hardwareLevel    = deviceLevel(front)
        } else {
            boundLensFacing  = "none_or_external"
            hardwareLevel    = "unknown"
        }
    }

    private func deviceLevel(_ device: AVCaptureDevice) -> String {
        // iOS doesn't expose hardware level directly; use device type as a proxy.
        switch device.deviceType {
        case .builtInTrueDepthCamera: return "full"
        case .builtInWideAngleCamera: return "limited"
        default:                      return "legacy"
        }
    }

    // MARK: - Frame cadence

    func onFrame(at timestamp: TimeInterval) {
        if lastFrameTime != 0 {
            let delta = timestamp - lastFrameTime
            frameDeltas.append(delta)
            if frameDeltas.count > Self.maxDeltas { frameDeltas.removeFirst() }
        }
        lastFrameTime = timestamp
    }

    // MARK: - Snapshot

    func snapshot() -> Report {
        let cov = cadenceCov()
        let metronomic = cov >= 0 && cov < Self.metronomicCov

        var risk = Float(0)
        if !hasFrontPhysical        { risk += 0.45 }
        if hardwareLevel == "legacy" { risk += 0.20 }
        if boundLensFacing == "none_or_external" { risk += 0.25 }
        if metronomic               { risk += 0.30 }

        return Report(
            cameraHardwareLevel:  hardwareLevel,
            boundLensFacing:      boundLensFacing,
            hasFrontPhysicalCamera: hasFrontPhysical,
            frameIntervalCov:     cov,
            metronomicFrames:     metronomic,
            riskScore:            min(risk, 1.0)
        )
    }

    private func cadenceCov() -> Float {
        guard frameDeltas.count >= Self.minDeltas else { return -1 }
        let mean = frameDeltas.reduce(0, +) / Double(frameDeltas.count)
        guard mean > 0 else { return -1 }
        let variance = frameDeltas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(frameDeltas.count)
        return Float(sqrt(variance) / mean)
    }
}
