import Foundation
import CoreGraphics

/// ActiveLivenessEngine — iOS port of the Android LivenessEngine challenge state machine.
///
/// Challenge pool: HEAD_TURN, BLINK, NOD — same as Android. Dot-follow is retired.
/// Detection mechanics mirror the Android engine:
///
/// - HEAD_TURN / NOD use the nose position RELATIVE to the face bounding-box centre,
///   normalised by face half-size (IOR-normalised). Camera tilt moves nose and box
///   together so the relative offset is motion-of-the-head only. A baseline is locked
///   after a 300ms settle window; the EMA-smoothed delta on the relevant axis must
///   exceed the pass threshold and hold for 350ms wall-clock. Any direction accepted.
///
/// - BLINK uses raw eye-open probability: a fractional drop ≥20% from the user's own
///   baseline followed by recovery to ≥55% of baseline. Evaluation pauses while the
///   head is away from its starting pose (looking down reads as closed eyes).
///
/// Timeouts: 10s for motion challenges, 15s for blink (screen-staring suppresses the
/// blink reflex). On timeout the engine swaps to a different challenge type — never
/// mid-challenge (tester feedback: instructions must stay stable).
final class ActiveLivenessEngine {

    // MARK: - Public types

    enum ChallengeType: String {
        case headTurn = "head_turn"
        case blink    = "blink"
        case nod      = "nod"
    }

    struct Signals {
        let faceCount: Int
        let faceBox: CGRect          // normalised [0,1] coordinates
        let nosePoint: CGPoint?      // normalised [0,1] image coordinates
        let yawDeg: Float
        let pitchDeg: Float
        let leftEyeOpen: Float       // 0–1, raw (un-smoothed)
        let rightEyeOpen: Float
    }

    enum State {
        case checking
        case challenge(prompt: String, progress: Float)
        case passed(challengesCompleted: [String])
        case failed(reason: String)
    }

    // MARK: - Tuning (mirrors Android constants)

    private static let warmupMaxWaitMs:      Int64 = 3_000
    private static let challengeTimeoutMs:   Int64 = 10_000
    private static let blinkTimeoutMs:       Int64 = 15_000
    private static let nextChallengeGapMs:   Int64 = 160
    private static let baselineSettleMs:     Int64 = 300
    private static let reactionGateMs:       Int64 = 700
    private static let minHoldDurationMs:    Int64 = 350
    private static let minPassElapsedMs:     Int64 = 900
    private static let blinkMinElapsedMs:    Int64 = 300
    private static let minFramesMotion           = 5
    private static let minFramesBlink            = 2
    private static let passThreshold:       Float = 0.022   // IOR units, above sway ceiling
    private static let holdThreshold:       Float = 0.014
    private static let emaAlpha:            Float = 0.35
    private static let blinkDropFraction:   Float = 0.20
    private static let blinkRecoveryFraction: Float = 0.55
    private static let blinkDeadZone:       Float = 0.08
    private static let maxChallengeAttempts      = 3

    // MARK: - Session state

    private enum Phase { case warmingUp, waitingForNeutral, inChallenge, complete, failed }

    private var phase: Phase = .warmingUp
    private var sequence: [ChallengeType] = []
    private var currentIndex = 0
    private var completed: [String] = []
    private var attemptCount = 0
    private var lastTimedOut: ChallengeType?

    private var warmupStartMs:    Int64 = 0
    private var neutralWaitStart: Int64 = 0
    private var challengeStartMs: Int64 = 0
    private var challengeFrames  = 0

    // Motion-challenge state
    private var baselineLocked = false
    private var baselineLockedAtMs: Int64 = 0
    private var baselineRelX: Float = 0
    private var baselineRelY: Float = 0
    private var emaRelX: Float = 0
    private var emaRelY: Float = 0
    private var peakReached = false
    private var peakAtMs: Int64 = 0

    // Blink state
    private var blinkBaseline: Float = -1
    private var blinkMinEye:   Float = 1
    private var blinkBaseYaw:   Float = .nan
    private var blinkBasePitch: Float = .nan

    private let targetCount: Int

    // MARK: - Init

    /// - Parameter challengeCount: 1 for single-challenge plans; 2–4 for Pro (clamped).
    init(challengeCount: Int) {
        self.targetCount = max(1, min(challengeCount, 4))
        var pool: [ChallengeType] = [.headTurn, .blink, .nod].shuffled()
        while pool.count < targetCount { pool += pool }
        self.sequence = Array(pool.prefix(targetCount))
    }

    // MARK: - Frame processing

    func process(signals: Signals, nowMs: Int64) -> State {
        switch phase {
        case .warmingUp:         return handleWarmup(signals, nowMs)
        case .waitingForNeutral: return handleNeutralWait(signals, nowMs)
        case .inChallenge:       return handleChallenge(signals, nowMs)
        case .complete:          return .passed(challengesCompleted: completed)
        case .failed:            return .failed(reason: "Liveness check failed")
        }
    }

    // MARK: - Warmup

    private func handleWarmup(_ s: Signals, _ now: Int64) -> State {
        if warmupStartMs == 0 { warmupStartMs = now }

        let neutral = s.faceCount == 1
            && abs(s.yawDeg) < 22 && abs(s.pitchDeg) < 22
            && s.leftEyeOpen > 0.28 && s.rightEyeOpen > 0.28

        if neutral || (now - warmupStartMs) >= Self.warmupMaxWaitMs {
            startChallenge(now)
            return currentState()
        }
        return .challenge(prompt: "Look straight at the camera", progress: 0)
    }

    // MARK: - Between challenges

    private func handleNeutralWait(_ s: Signals, _ now: Int64) -> State {
        let neutral = abs(s.yawDeg) < 22 && abs(s.pitchDeg) < 22
        if (now - neutralWaitStart) >= Self.nextChallengeGapMs && neutral {
            startChallenge(now)
        }
        return currentState()
    }

    // MARK: - Challenge lifecycle

    private func startChallenge(_ now: Int64) {
        phase = .inChallenge
        challengeStartMs = now
        challengeFrames = 0
        baselineLocked = false
        emaRelX = 0; emaRelY = 0
        peakReached = false
        blinkBaseline = -1
        blinkMinEye = 1
        blinkBaseYaw = .nan
        blinkBasePitch = .nan
    }

    private var activeChallenge: ChallengeType { sequence[currentIndex] }

    private func prompt(for c: ChallengeType) -> String {
        switch c {
        case .blink:    return "Blink your eyes"
        case .nod:      return "Nod your head"
        case .headTurn: return "Turn your head"
        }
    }

    private func currentState() -> State {
        .challenge(prompt: prompt(for: activeChallenge), progress: sessionProgress(0))
    }

    private func sessionProgress(_ challengeProgress: Float) -> Float {
        let total = Float(max(targetCount, 1))
        let base = 0.20 + (Float(currentIndex) / total) * 0.80
        let span = 0.80 / total
        return min(max(base + challengeProgress * span, 0), 1)
    }

    private func handleChallenge(_ s: Signals, _ now: Int64) -> State {
        guard s.faceCount == 1 else {
            return .challenge(prompt: "Position your face in the oval", progress: sessionProgress(0))
        }
        challengeFrames += 1
        let elapsed = now - challengeStartMs

        let timeout = activeChallenge == .blink ? Self.blinkTimeoutMs : Self.challengeTimeoutMs
        if elapsed >= timeout {
            return onChallengeTimeout(now)
        }

        let (progress, done) = activeChallenge == .blink
            ? evaluateBlink(s, now: now, elapsed: elapsed)
            : evaluateMotion(s, now: now, elapsed: elapsed)

        if done {
            return onChallengePassed(now)
        }
        return .challenge(prompt: prompt(for: activeChallenge), progress: sessionProgress(progress))
    }

    private func onChallengePassed(_ now: Int64) -> State {
        completed.append(activeChallenge.rawValue)
        currentIndex += 1
        attemptCount = 0
        if currentIndex >= sequence.count {
            phase = .complete
            return .passed(challengesCompleted: completed)
        }
        phase = .waitingForNeutral
        neutralWaitStart = now
        return currentState()
    }

    private func onChallengeTimeout(_ now: Int64) -> State {
        attemptCount += 1
        if attemptCount >= Self.maxChallengeAttempts {
            phase = .failed
            return .failed(reason: "Liveness challenge timed out")
        }
        // Swap to a different challenge type for the retry — never mid-challenge.
        lastTimedOut = activeChallenge
        let replacements: [ChallengeType] = [.headTurn, .blink, .nod]
            .filter { $0 != activeChallenge && $0 != lastTimedOut }
        if let replacement = replacements.randomElement()
            ?? [ChallengeType.headTurn, .blink, .nod].filter({ $0 != activeChallenge }).randomElement() {
            sequence[currentIndex] = replacement
        }
        phase = .waitingForNeutral
        neutralWaitStart = now
        return currentState()
    }

    // MARK: - Motion challenge (HEAD_TURN / NOD)

    private func evaluateMotion(_ s: Signals, now: Int64, elapsed: Int64) -> (Float, Bool) {
        guard let nose = s.nosePoint, s.faceBox.width > 0, s.faceBox.height > 0 else {
            // Euler fallback: use raw yaw/pitch in degrees against a 9° threshold.
            return evaluateMotionEuler(s, now: now, elapsed: elapsed)
        }

        // IOR-normalised relative offset — tilt-independent (see Android engine).
        let relX = Float((nose.x - s.faceBox.midX) / (s.faceBox.width / 2))
        let relY = Float((nose.y - s.faceBox.midY) / (s.faceBox.height / 2))

        if !baselineLocked {
            if elapsed >= Self.baselineSettleMs {
                baselineRelX = relX
                baselineRelY = relY
                baselineLocked = true
                baselineLockedAtMs = now
            }
            return (0, false)
        }

        let dX = relX - baselineRelX
        let dY = relY - baselineRelY
        emaRelX = emaRelX * (1 - Self.emaAlpha) + dX * Self.emaAlpha
        emaRelY = emaRelY * (1 - Self.emaAlpha) + dY * Self.emaAlpha

        // Any-direction: HEAD_TURN reads the X axis, NOD reads the Y axis, abs() both ways.
        let onAxis = activeChallenge == .headTurn ? abs(emaRelX) : abs(emaRelY)

        // Reaction gate: movement within 700ms of baseline lock is sway, not a response.
        guard (now - baselineLockedAtMs) >= Self.reactionGateMs else { return (0, false) }

        if !peakReached && onAxis >= Self.passThreshold {
            peakReached = true
            peakAtMs = now
        }
        if peakReached && onAxis < Self.holdThreshold {
            peakReached = false   // dropped out of hold band — restart hold
        }

        let holdElapsed = peakReached ? now - peakAtMs : 0
        let progress = peakReached
            ? min(Float(holdElapsed) / Float(Self.minHoldDurationMs), 0.95)
            : min(onAxis / Self.passThreshold * 0.5, 0.45)

        let done = peakReached
            && holdElapsed >= Self.minHoldDurationMs
            && elapsed >= Self.minPassElapsedMs
            && challengeFrames >= Self.minFramesMotion
        return (progress, done)
    }

    private func evaluateMotionEuler(_ s: Signals, now: Int64, elapsed: Int64) -> (Float, Bool) {
        if !baselineLocked {
            if elapsed >= Self.baselineSettleMs {
                baselineRelX = s.yawDeg
                baselineRelY = s.pitchDeg
                baselineLocked = true
                baselineLockedAtMs = now
            }
            return (0, false)
        }
        guard (now - baselineLockedAtMs) >= Self.reactionGateMs else { return (0, false) }

        let delta = activeChallenge == .headTurn
            ? abs(s.yawDeg - baselineRelX)
            : abs(s.pitchDeg - baselineRelY)
        let thresholdDeg: Float = 9.0

        if !peakReached && delta >= thresholdDeg {
            peakReached = true
            peakAtMs = now
        }
        if peakReached && delta < thresholdDeg * 0.6 {
            peakReached = false
        }
        let holdElapsed = peakReached ? now - peakAtMs : 0
        let done = peakReached
            && holdElapsed >= Self.minHoldDurationMs
            && elapsed >= Self.minPassElapsedMs
            && challengeFrames >= Self.minFramesMotion
        let progress = peakReached
            ? min(Float(holdElapsed) / Float(Self.minHoldDurationMs), 0.95)
            : min(delta / thresholdDeg * 0.5, 0.45)
        return (progress, done)
    }

    // MARK: - Blink challenge

    private func evaluateBlink(_ s: Signals, now: Int64, elapsed: Int64) -> (Float, Bool) {
        if blinkBaseYaw.isNaN {
            blinkBaseYaw = s.yawDeg
            blinkBasePitch = s.pitchDeg
        }
        // Head-motion gate: eye-open values are unreliable while the head moves —
        // looking down reads as closed eyes. Pause and discard any partial dip.
        let headMoved = abs(s.pitchDeg - blinkBasePitch) > 8 || abs(s.yawDeg - blinkBaseYaw) > 10
        if headMoved {
            if blinkBaseline > 0 { blinkMinEye = blinkBaseline }
            return (0, false)
        }

        let avg = (s.leftEyeOpen + s.rightEyeOpen) / 2
        guard avg >= 0 else { return (0, false) }

        // Lock baseline at the user's ACTUAL resting level — no floor (see Android engine).
        if blinkBaseline < 0 { blinkBaseline = avg }
        blinkMinEye = min(blinkMinEye, avg)

        let dropFraction = blinkBaseline > 0.05 ? (blinkBaseline - blinkMinEye) / blinkBaseline : 0
        let dipDetected = dropFraction >= Self.blinkDropFraction
        let recovered = dipDetected && avg >= blinkBaseline * Self.blinkRecoveryFraction

        if recovered && elapsed >= Self.blinkMinElapsedMs && challengeFrames >= Self.minFramesBlink {
            return (1, true)
        }

        // Dead-zone below 8% drop: natural eye jitter must not show progress.
        let progress = dropFraction < Self.blinkDeadZone ? 0
            : min((dropFraction - Self.blinkDeadZone) / (Self.blinkDropFraction - Self.blinkDeadZone), 0.9)
        return (progress, false)
    }
}
