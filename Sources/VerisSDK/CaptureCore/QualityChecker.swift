import Foundation
import CoreGraphics

/// QualityChecker — Layer 1 of the capture pipeline, runs on every analysed frame.
/// iOS port of the Android checker; same ordered checks, streaks and thresholds.
///
/// Checks (fail-fast): face count → size → centering → pose (yaw/pitch/roll) →
/// sharpness (Laplacian) → brightness (EMA + streaks) → eyes-closed streak →
/// static-image detection (brightness-variance and box-jitter rolling buffers).
final class QualityChecker {

    struct Input {
        let faceCount: Int
        let faceBox: CGRect          // Vision normalised, y-up
        let yawDeg: Float
        let pitchDeg: Float
        let rollDeg: Float
        let leftEyeOpen: Float       // -1 when unavailable
        let rightEyeOpen: Float
        let frameGray64: [UInt8]?    // 64×64 full frame — sharpness
        let frameGray32: [UInt8]?    // 32×32 full frame — brightness
        let faceGray16: [UInt8]?     // 16×16 face crop — static-image variance
    }

    struct Result {
        let passed: Bool
        let score: Float
        let instruction: String
        let isStaticImage: Bool
    }

    // Thresholds — tuned for handheld capture (see Android QualityChecker).
    private let minFaceRatio:    Float  = 0.25
    private let maxFaceRatio:    Float  = 0.78
    private let maxYaw:          Float  = 15
    private let maxPitch:        Float  = 15
    private let maxRoll:         Float  = 20
    private let minEyeOpen:      Float  = 0.32
    private let minBrightness:   Float  = 70
    private let maxBrightness:   Float  = 225
    private let minBlurVariance: Double = 55
    private let centreTol:       Float  = 0.42
    // 1px on a ~720px frame, expressed in normalised units.
    private let jitterThreshold: CGFloat = 0.0015

    // Rolling state
    private var brightnessHistory: [Float] = []
    private var boxJitterHistory: [CGFloat] = []
    private var lastBoxOrigin: CGPoint?
    private var offCenterStreak = 0
    private var poseAngleStreak = 0
    private var darkStreak = 0
    private var brightStreak = 0
    private var tooCloseStreak = 0
    private var eyesClosedStreak = 0
    private var brightnessEma: Float = 0
    private var hasBrightnessEma = false

    func evaluate(
        _ input: Input,
        minPassScore: Float = 0.70,
        ignorePose: Bool = false,
        ignoreEyesClosed: Bool = false
    ) -> Result {
        if input.faceCount == 0 { return fail("Position your face in the oval") }
        if input.faceCount > 1  { return fail("Only one face please") }

        // Size — the normalised box width IS the face/frame width ratio.
        let sizeRatio = Float(input.faceBox.width)
        if sizeRatio < minFaceRatio { return fail("Move closer") }
        if sizeRatio > maxFaceRatio {
            tooCloseStreak += 1
            if tooCloseStreak >= 2 { return fail("Move further away") }
        } else {
            tooCloseStreak = 0
        }

        // Centering — vs frame centre, tolerance as fraction of half-dimensions.
        let ox = abs(Float(input.faceBox.midX) - 0.5) / 0.5
        let oy = abs(Float(input.faceBox.midY) - 0.5) / 0.5
        if !ignorePose && (ox > centreTol || oy > centreTol) {
            offCenterStreak += 1
            let severe = ox > centreTol + 0.14 || oy > centreTol + 0.14
            if severe || offCenterStreak >= 4 { return fail("Center your face in the oval") }
        } else {
            offCenterStreak = 0
        }

        // Pose — 2-frame streak; single-frame Euler spikes must not flash warnings.
        if !ignorePose {
            let badYaw   = abs(input.yawDeg)   > maxYaw
            let badPitch = abs(input.pitchDeg) > maxPitch
            let severe   = abs(input.yawDeg) > maxYaw * 1.8 || abs(input.pitchDeg) > maxPitch * 1.8
            if badYaw || badPitch {
                poseAngleStreak += 1
                if severe || poseAngleStreak >= 2 {
                    poseAngleStreak = 0
                    return fail("Look directly at the camera")
                }
            } else {
                poseAngleStreak = 0
            }
            if abs(input.rollDeg) > maxRoll { return fail("Hold your phone upright") }
        }

        // Sharpness
        var blurVar: Double = minBlurVariance
        if let g64 = input.frameGray64 {
            blurVar = Self.laplacianVariance(g64, w: 64, h: 64)
            if blurVar < minBlurVariance { return fail("Hold your phone steady") }
        }

        // Brightness — EMA-smoothed with 2-frame streaks in each direction.
        var brightness: Float = 128
        if let g32 = input.frameGray32 {
            brightness = Self.average(g32)
            if !hasBrightnessEma {
                brightnessEma = brightness
                hasBrightnessEma = true
            } else {
                brightnessEma = brightnessEma * 0.80 + brightness * 0.20
            }
            if brightnessEma < minBrightness - 3 {
                darkStreak += 1; brightStreak = 0
                if darkStreak >= 2 { return fail("Move to a brighter area") }
            } else if brightnessEma > maxBrightness + 10 {
                brightStreak += 1; darkStreak = 0
                if brightStreak >= 2 { return fail("Avoid harsh backlight") }
            } else {
                darkStreak = 0; brightStreak = 0
            }
        }

        // Eyes — 2-frame streak so a natural blink doesn't flash a warning.
        if !ignoreEyesClosed, input.leftEyeOpen >= 0, input.rightEyeOpen >= 0 {
            if min(input.leftEyeOpen, input.rightEyeOpen) < minEyeOpen {
                eyesClosedStreak += 1
                if eyesClosedStreak >= 2 { return fail("Keep your eyes open") }
            } else {
                eyesClosedStreak = 0
            }
        }

        // Static-image detection 1: brightness variance of the face crop.
        // Real sensors always carry noise; prints/screens are flat. 14/15 flat frames fails.
        if let f16 = input.faceGray16 {
            let bVar = Self.normalisedVariance(f16)
            brightnessHistory.append(bVar)
            if brightnessHistory.count > 15 { brightnessHistory.removeFirst() }
            if brightnessHistory.count == 15 && brightnessHistory.filter({ $0 < 0.05 }).count >= 14 {
                brightnessHistory.removeAll()
                return Result(passed: false, score: 0, instruction: "Use your live camera", isStaticImage: true)
            }
        }

        // Static-image detection 2: bounding-box jitter. Real faces drift with hand
        // tremor and breathing; 10/10 perfectly still frames fails.
        let origin = input.faceBox.origin
        if let prev = lastBoxOrigin {
            let jitter = abs(origin.x - prev.x) + abs(origin.y - prev.y)
            boxJitterHistory.append(jitter)
            if boxJitterHistory.count > 10 { boxJitterHistory.removeFirst() }
            if boxJitterHistory.count == 10 && boxJitterHistory.allSatisfy({ $0 < jitterThreshold }) {
                boxJitterHistory.removeAll()
                return Result(passed: false, score: 0, instruction: "Use your live camera", isStaticImage: true)
            }
        }
        lastBoxOrigin = origin

        // Composite score: sharpness 50%, lighting 30%, pose 20%.
        let p = 1 - (abs(input.yawDeg) / maxYaw + abs(input.pitchDeg) / maxPitch) / 2
        let l = 1 - abs(brightness - 128) / 128
        let b = Float(min(max(blurVar / 600.0, 0), 1))
        let score = min(max(b * 0.50 + min(max(l, 0), 1) * 0.30 + min(max(p, 0), 1) * 0.20, 0), 1)
        return Result(passed: score >= minPassScore, score: score, instruction: "Hold still", isStaticImage: false)
    }

    /// Reset rolling buffers — call at session start and on retry.
    func reset() {
        brightnessHistory.removeAll()
        boxJitterHistory.removeAll()
        lastBoxOrigin = nil
        offCenterStreak = 0; poseAngleStreak = 0
        darkStreak = 0; brightStreak = 0
        tooCloseStreak = 0; eyesClosedStreak = 0
        brightnessEma = 0; hasBrightnessEma = false
    }

    // MARK: - Pixel metrics

    static func average(_ gray: [UInt8]) -> Float {
        guard !gray.isEmpty else { return 0 }
        var total = 0
        for v in gray { total += Int(v) }
        return Float(total) / Float(gray.count)
    }

    static func laplacianVariance(_ gray: [UInt8], w: Int, h: Int) -> Double {
        var sum = 0.0, sumSq = 0.0
        var count = 0
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                let lap = Double(gray[y*w+x]) * 8
                    - Double(gray[(y-1)*w+(x-1)]) - Double(gray[(y-1)*w+x]) - Double(gray[(y-1)*w+(x+1)])
                    - Double(gray[y*w+(x-1)])                               - Double(gray[y*w+(x+1)])
                    - Double(gray[(y+1)*w+(x-1)]) - Double(gray[(y+1)*w+x]) - Double(gray[(y+1)*w+(x+1)])
                sum += lap * lap
                count += 1
            }
        }
        _ = sumSq
        return count > 0 ? sum / Double(count) : 0
    }

    private static func normalisedVariance(_ gray: [UInt8]) -> Float {
        guard !gray.isEmpty else { return 0 }
        let values = gray.map { Float($0) / 255 }
        let mean = values.reduce(0, +) / Float(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
    }

    private func fail(_ instruction: String) -> Result {
        Result(passed: false, score: 0.3, instruction: instruction, isStaticImage: false)
    }
}
