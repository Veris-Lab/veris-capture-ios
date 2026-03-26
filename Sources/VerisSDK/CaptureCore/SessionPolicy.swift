import Foundation

struct SessionPolicy {
    let minAccumulationWindowMs: Int
    let forceEscalation: Bool
    let allowPassiveLiveness: Bool
    let allowActiveChallenges: Bool
    let maxRetries: Int
}

enum TierPolicyLoader {
    static func load(context: SessionContext) -> SessionPolicy {
        switch context.plan {
        case .starter:
            return SessionPolicy(
                minAccumulationWindowMs: 1200,
                forceEscalation: false,
                allowPassiveLiveness: false,
                allowActiveChallenges: false,
                maxRetries: min(context.maxRetries, 3)
            )
        case .regular:
            return SessionPolicy(
                minAccumulationWindowMs: 1800,
                forceEscalation: true,
                allowPassiveLiveness: true,
                allowActiveChallenges: true,
                maxRetries: min(context.maxRetries, 3)
            )
        case .pro, .enterprise:
            return SessionPolicy(
                minAccumulationWindowMs: 2000,
                forceEscalation: true,
                allowPassiveLiveness: true,
                allowActiveChallenges: true,
                maxRetries: min(max(context.maxRetries, 1), 5)
            )
        }
    }
}
