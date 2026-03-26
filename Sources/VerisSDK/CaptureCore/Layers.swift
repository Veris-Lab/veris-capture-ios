import Foundation

struct PresenceResult {
    let passed: Bool
    let qualityScore: Float
    let failReason: String?
}

struct TemporalResult {
    let passed: Bool
    let motionScore: Float
}

struct SpoofArtifactResult {
    let passed: Bool
    let spoofRisk: Float
}

struct EscalationResult {
    let passed: Bool
    let challengeRequired: Bool
}

struct EvidenceBundle {
    let presence: PresenceResult
    let temporal: TemporalResult?
    let spoofArtifact: SpoofArtifactResult?
    let escalation: EscalationResult?
}

enum FusionDecision {
    case pass
    case retry
    case fail
}

struct FusionResult {
    let decision: FusionDecision
    let confidenceScore: Float
}

enum FusionEngine {
    static func decide(bundle: EvidenceBundle) -> FusionResult {
        let presenceScore = bundle.presence.qualityScore
        let temporalScore = bundle.temporal?.motionScore ?? 0.5
        let artifactSafety = 1 - Double(bundle.spoofArtifact?.spoofRisk ?? 0.15)
        let escalationScore = bundle.escalation?.passed == true ? 0.8 : 0.4
        let confidence = Float(
            (Double(presenceScore) * 0.35) +
            (Double(temporalScore) * 0.25) +
            (artifactSafety * 0.20) +
            (escalationScore * 0.20)
        )
        if !bundle.presence.passed {
            return FusionResult(decision: .retry, confidenceScore: confidence)
        }
        if (bundle.spoofArtifact?.spoofRisk ?? 0) > 0.82 {
            return FusionResult(decision: .fail, confidenceScore: confidence)
        }
        switch confidence {
        case 0.72...:
            return FusionResult(decision: .pass, confidenceScore: confidence)
        case 0.48...:
            return FusionResult(decision: .retry, confidenceScore: confidence)
        default:
            return FusionResult(decision: .fail, confidenceScore: confidence)
        }
    }
}
