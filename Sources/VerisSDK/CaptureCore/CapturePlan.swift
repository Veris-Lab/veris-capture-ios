import Foundation

enum CapturePlan: String {
    case starter
    case regular
    case pro
    case enterprise

    static func resolve(features: VerisFeatureFlags) -> CapturePlan {
        if features.activeLiveness && features.activeLivenessConfigurable {
            return .pro
        }
        if features.activeLiveness {
            return .regular
        }
        return .starter
    }
}
