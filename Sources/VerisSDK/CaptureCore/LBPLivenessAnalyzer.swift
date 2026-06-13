import Foundation
import CoreGraphics
import CoreVideo

/// LBPLivenessAnalyzer — single-frame LBP texture analysis. iOS port of the Android
/// analyzer; algorithm, crop sizes and thresholds are identical so the calibration
/// transfers (64×64 skin crop, 10-bin uniform LBP).
///
/// Three signals combined:
///  - Shannon entropy  (weight 0.45) — higher = more texture complexity = more likely real
///  - Uniformity ratio (weight 0.30) — skin has characteristic LBP ratio 0.60–0.90
///  - Gradient variance (weight 0.25) — 3D surface depth cue, flat prints score low
///
/// Calibration (64×64 crop, mobile camera):
///   Real face:     entropy 2.8–3.5   gradVar 180–450    score 0.65–0.90
///   Printed photo: entropy 1.8–2.8   gradVar  30–140    score 0.05–0.35
///   Phone screen:  entropy 2.2–3.0   gradVar  60–200    score 0.15–0.50
enum LBPLivenessAnalyzer {

    struct Result {
        let score: Double         // 0.0–1.0 combined — use for pass/fail
        let entropy: Double
        let uniformity: Double
        let gradVariance: Double
    }

    // MARK: - Analysis (expects a 64×64 grayscale crop of the inner skin region)

    static func analyze(gray: [UInt8], width: Int = 64, height: Int = 64) -> Result {
        let hist       = lbpHistogram(gray, w: width, h: height)
        let entropy    = shannonEntropy(hist)
        let uniformity = uniformityRatio(hist)
        let gradVar    = gradientVariance(gray, w: width, h: height)
        return Result(
            score: score(entropy: entropy, uniformity: uniformity, gradVar: gradVar),
            entropy: entropy,
            uniformity: uniformity,
            gradVariance: gradVar
        )
    }

    /// Inner skin region of a face box (normalised, y-up): insets matching Android —
    /// 12% horizontal, 16% off the top, 20% off the bottom.
    static func innerSkinRect(of faceBox: CGRect) -> CGRect {
        CGRect(
            x: faceBox.minX + faceBox.width * 0.12,
            y: faceBox.minY + faceBox.height * 0.20,          // y-up: bottom inset
            width: faceBox.width * 0.76,
            height: faceBox.height * (1 - 0.16 - 0.20)
        )
    }

    // MARK: - LBP histogram — 8-neighbour uniform LBP, 10 bins

    private static func lbpHistogram(_ gray: [UInt8], w: Int, h: Int) -> [Int] {
        var hist = [Int](repeating: 0, count: 10)
        var total = 0
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                let center = gray[y * w + x]
                var code = 0
                let neighbors: [UInt8] = [
                    gray[(y-1)*w+(x-1)], gray[(y-1)*w+x], gray[(y-1)*w+(x+1)],
                    gray[y*w+(x+1)],
                    gray[(y+1)*w+(x+1)], gray[(y+1)*w+x], gray[(y+1)*w+(x-1)],
                    gray[y*w+(x-1)],
                ]
                for (i, v) in neighbors.enumerated() where v >= center {
                    code |= 1 << i
                }
                let bin = bitTransitions(code) <= 2 ? min(code.nonzeroBitCount, 8) : 9
                hist[bin] += 1
                total += 1
            }
        }
        guard total > 0 else { return hist }
        return hist.map { Int(Double($0) * 1000.0 / Double(total)) }
    }

    private static func bitTransitions(_ code: Int) -> Int {
        var transitions = 0
        var prev = (code >> 7) & 1
        for i in 0...7 {
            let bit = (code >> i) & 1
            if bit != prev { transitions += 1 }
            prev = bit
        }
        return transitions
    }

    // MARK: - Feature metrics

    private static func shannonEntropy(_ hist: [Int]) -> Double {
        let total = Double(hist.reduce(0, +))
        guard total > 0 else { return 0 }
        return hist.filter { $0 > 0 }.reduce(0.0) { acc, bin in
            let p = Double(bin) / total
            return acc - p * log2(p)
        }
    }

    private static func uniformityRatio(_ hist: [Int]) -> Double {
        let total = Double(hist.reduce(0, +))
        guard total > 0 else { return 0 }
        let uniform = Double(hist.dropLast().reduce(0, +))   // bins 0–8, skip bin 9
        return uniform / total
    }

    private static func gradientVariance(_ gray: [UInt8], w: Int, h: Int) -> Double {
        var grads: [Double] = []
        grads.reserveCapacity((w - 2) * (h - 2))
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                let gx = Double(gray[y*w+(x+1)]) - Double(gray[y*w+(x-1)])
                let gy = Double(gray[(y+1)*w+x]) - Double(gray[(y-1)*w+x])
                grads.append((gx * gx + gy * gy).squareRoot())
            }
        }
        guard !grads.isEmpty else { return 0 }
        let mean = grads.reduce(0, +) / Double(grads.count)
        return grads.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(grads.count)
    }

    // MARK: - Scoring (identical tables to Android — calibrated for the 64×64 crop)

    private static func score(entropy: Double, uniformity: Double, gradVar: Double) -> Double {
        let entropyScore: Double
        switch entropy {
        case let e where e > 3.5: entropyScore = 1.0
        case let e where e > 2.8: entropyScore = 0.75
        case let e where e > 2.2: entropyScore = 0.50
        case let e where e > 1.5: entropyScore = 0.25
        default:                  entropyScore = 0.0
        }

        // Range 0.60–0.90 accommodates darker skin tones (less concentrated histogram).
        let uniformityScore: Double
        switch uniformity {
        case 0.60...0.90: uniformityScore = 1.0
        case 0.50...0.96: uniformityScore = 0.60
        default:          uniformityScore = 0.15
        }

        let gradScore: Double
        switch gradVar {
        case let g where g > 450: gradScore = 1.0
        case let g where g > 200: gradScore = 0.75
        case let g where g > 100: gradScore = 0.55
        case let g where g > 50:  gradScore = 0.35
        case let g where g > 25:  gradScore = 0.20
        default:                  gradScore = 0.0
        }

        return entropyScore * 0.45 + uniformityScore * 0.30 + gradScore * 0.25
    }

    // MARK: - Occlusion probe — sub-region texture comparison (shadow mode, advisory only)
    //
    // Sunglasses/masks/hands collapse band entropy relative to the wearer's own cheeks
    // in the same frame — self-normalising for lighting and skin tone. Never blocks
    // capture; results feed backend risk-scoring only.

    struct OcclusionProbe {
        let eyeBandScore: Double
        let mouthBandScore: Double
        let eyesSuspect: Bool
        let mouthSuspect: Bool
    }

    private static let bandSuspectRatio = 0.62

    static func probeOcclusion(
        sampler: FrameSampler,
        pixelBuffer: CVPixelBuffer,
        faceBox: CGRect
    ) -> OcclusionProbe {
        // Bands are specified as fractions from the TOP of the face (Android convention);
        // converted here to Vision's y-up space.
        func bandEntropy(fromTop topFrac: CGFloat, to bottomFrac: CGFloat, inset: CGFloat = 0.18) -> Double {
            let band = CGRect(
                x: faceBox.minX + faceBox.width * inset,
                y: faceBox.minY + faceBox.height * (1 - bottomFrac),
                width: faceBox.width * (1 - 2 * inset),
                height: faceBox.height * (bottomFrac - topFrac)
            )
            guard band.width > 0.01, band.height > 0.005,
                  let gray = sampler.gray(from: pixelBuffer, normRect: band, width: 48, height: 24) else {
                return -1
            }
            return shannonEntropy(lbpHistogram(gray, w: 48, h: 24))
        }

        let eyeBand   = bandEntropy(fromTop: 0.18, to: 0.42)
        let cheekBand = bandEntropy(fromTop: 0.44, to: 0.62)
        let mouthBand = bandEntropy(fromTop: 0.64, to: 0.88)

        guard cheekBand > 0.5 else {
            return OcclusionProbe(eyeBandScore: 1, mouthBandScore: 1, eyesSuspect: false, mouthSuspect: false)
        }
        let eyeScore   = eyeBand   > 0 ? eyeBand / cheekBand : 1
        let mouthScore = mouthBand > 0 ? mouthBand / cheekBand : 1
        return OcclusionProbe(
            eyeBandScore: eyeScore,
            mouthBandScore: mouthScore,
            eyesSuspect: eyeScore < bandSuspectRatio,
            mouthSuspect: mouthScore < bandSuspectRatio
        )
    }
}
