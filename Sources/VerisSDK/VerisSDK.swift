import Foundation
import AVFoundation
import UIKit

// MARK: - SDK Entry Point

/// VerisCapture — Veris Face SDK for iOS
///
/// VerisSDK remains available as a backwards-compatible alias.
///
/// Usage:
/// ```swift
/// let config = VerisConfig(licenseKey: "vrs_live_...", initNonce: nonce)
/// VerisCapture.shared.initialise(config: config) { result in
///     switch result {
///     case .ready: // integrate
///     case .expired: // show upgrade prompt
///     }
/// }
/// VerisCapture.shared.startVerification(from: viewController, session: session) { result in
///     switch result {
///     case .success(let r): verifySignedToken(r.signedResult)
///     case .failure(let e): handleError(e)
///     case .cancelled: break
///     }
/// }
/// ```
///
/// - Never crashes the host app
/// - Never stores biometric data
/// - Always delivers a result (success / failure / cancelled)
/// - Releases camera on viewWillDisappear / background
@objc public final class VerisSDK: NSObject {

    @objc public static let shared = VerisSDK()
    private override init() {}

    private var config: VerisConfig?
    private var subscriptionState: VerisSubscriptionState = .unknown
    private let featureFlagManager = FeatureFlagManager()

    // MARK: - Initialise

    /// Initialise the SDK. Call once, typically in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    public func initialise(
        config: VerisConfig,
        completion: @escaping (VerisInitResult) -> Void
    ) {
        self.config = config
        LicenseValidator.validate(config: config) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let info):
                    self.subscriptionState = .active(info)
                    self.featureFlagManager.updateFlags(info.features)
                    completion(.ready(info))

                case .gracePeriod(let info):
                    self.subscriptionState = .gracePeriod(info)
                    self.featureFlagManager.updateFlags(info.features)
                    completion(.gracePeriod(info))

                case .expired:
                    self.subscriptionState = .expired
                    completion(.subscriptionExpired)

                case .error(let msg):
                    self.subscriptionState = .unknown
                    completion(.initError(msg))
                }
            }
        }
    }

    // MARK: - Start Verification

    /// Launch the Veris face verification flow modally.
    public func startVerification(
        from presentingViewController: UIViewController,
        session: VerisSessionConfig,
        completion: @escaping (VerisResult) -> Void
    ) {
        guard let config = config else {
            completion(.error(.sdkNotInitialised, VerisErrorMessages.message(for: .sdkNotInitialised)))
            return
        }

        if case .expired = subscriptionState {
            completion(.subscriptionInactive("Your Veris subscription has expired. Please renew to continue."))
            return
        }

        let features = featureFlagManager.currentFlags ?? config.fallbackFeatures
        let plan = CapturePlan.resolve(features: features)
        let licenseInfo: VerisLicenseInfo? = {
            switch subscriptionState {
            case .active(let i), .gracePeriod(let i): return i
            default: return nil
            }
        }()
        var sessionContext = SessionContext(
            nonce: session.nonce,
            plan: plan,
            maxRetries: session.maxRetries,
            strictness: session.strictness
        )
        sessionContext.environment    = licenseInfo?.environment  ?? (config.environment == .sandbox ? "sandbox" : "production")
        sessionContext.licenseKeyId   = licenseInfo?.licenseKeyId ?? ""
        sessionContext.validationState = licenseInfo != nil ? "verified" : "unverified_offline"
        let stateManager = StateManager()
        let pipelineCoordinator = PipelineCoordinator(
            context: sessionContext,
            policy: TierPolicyLoader.load(context: sessionContext),
            stateManager: stateManager
        )
        let vc = FaceCaptureViewController(
            sdkConfig: config,
            sessionConfig: session,
            features: features,
            sessionContext: sessionContext,
            pipelineCoordinator: pipelineCoordinator,
            completion: completion
        )
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        presentingViewController.present(nav, animated: true)
    }

    // MARK: - Lifecycle

    /// Call from AppDelegate.applicationDidEnterBackground. Releases camera immediately.
    public func applicationDidEnterBackground() {
        FaceCaptureViewController.releaseCamera()
    }
}
