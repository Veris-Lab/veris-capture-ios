import Foundation
import UIKit

/// VerisCapture is the preferred public entry point for the face capture SDK.
///
/// VerisSDK remains available as a backwards-compatible alias for older integrations.
public final class VerisCapture: NSObject {
    public static let shared = VerisSDK.shared

    public static func initialise(
        config: VerisConfig,
        completion: @escaping (VerisInitResult) -> Void
    ) {
        VerisSDK.shared.initialise(config: config, completion: completion)
    }

    public static func startVerification(
        from presentingViewController: UIViewController,
        session: VerisSessionConfig,
        completion: @escaping (VerisResult) -> Void
    ) {
        VerisSDK.shared.startVerification(
            from: presentingViewController,
            session: session,
            completion: completion
        )
    }

    public static func applicationDidEnterBackground() {
        VerisSDK.shared.applicationDidEnterBackground()
    }
}
