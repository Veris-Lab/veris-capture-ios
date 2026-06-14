import Foundation

/// LicenseValidator — Validates the license key against the Veris backend (iOS).
///
/// Called at SDK init. First successful verification is cached per
/// license/environment/app so later initialisations can work offline.
enum LicenseValidator {
    private static let offlineGraceDays = 10
    private static let cachePrefix = "veris_sdk_license_cache_v1"

    enum ValidationResult {
        case success(VerisLicenseInfo)
        case gracePeriod(VerisLicenseInfo)
        case expired
        case error(String)
    }

    static func validate(config: VerisConfig, completion: @escaping (ValidationResult) -> Void) {
        let environment = inferEnvironment(from: config)
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown.ios.bundle"
        let cached = loadCachedLicense(licenseKey: config.licenseKey, environment: environment, bundleId: bundleId)
        if let cached, environment != "sandbox" {
            switch cacheStatus(for: cached) {
            case .active:
                completion(.success(cached))
                return
            case .grace:
                completion(.gracePeriod(cached))
                return
            case .expired:
                break
            }
        }

        let endpoint = config.apiBaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/sdk/validate"
        guard let validateURL = URL(string: endpoint) else {
            completion(.error("Invalid API base URL"))
            return
        }

        // Ensure the per-install signing key exists before the first server contact.
        // The public key is registered on the backend so it can later verify signed results.
        DeviceKeyStore.ensureKeyPair()

        var body: [String: Any] = [
            "license_key": config.licenseKey,
            "package_name": bundleId,
            "platform": "ios",
            "sdk_version": SDKVersion.current,
            "session_nonce": config.initNonce,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        if let pubKeyPem = DeviceKeyStore.publicKeyPem() {
            body["device_public_key"] = pubKeyPem
            body["device_key_id"]     = DeviceKeyStore.publicKeyId()
            body["hardware_backed"]   = DeviceKeyStore.isHardwareBacked
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.error("Failed to encode validation request"))
            return
        }

        var request = URLRequest(url: validateURL, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                if let cached {
                    switch cacheStatus(for: cached) {
                    case .active:
                        completion(.success(cached))
                        return
                    case .grace:
                        completion(.gracePeriod(cached))
                        return
                    case .expired:
                        completion(.expired)
                        return
                    }
                }
                completion(.error("Network error: \(error.localizedDescription)"))
                return
            }
            guard let data,
                  let http = response as? HTTPURLResponse else {
                if let cached {
                    switch cacheStatus(for: cached) {
                    case .active:
                        completion(.success(cached))
                        return
                    case .grace:
                        completion(.gracePeriod(cached))
                        return
                    case .expired:
                        completion(.expired)
                        return
                    }
                }
                completion(.error("No response from server"))
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            Self.handleResponse(
                statusCode: http.statusCode,
                json: json,
                licenseKey: config.licenseKey,
                environment: environment,
                bundleId: bundleId,
                completion: completion
            )
        }.resume()
    }

    private static func handleResponse(
        statusCode: Int,
        json: [String: Any],
        licenseKey: String,
        environment: String,
        bundleId: String,
        completion: (ValidationResult) -> Void
    ) {
        switch statusCode {
        case 200:
            guard json["valid"] as? Bool == true else {
                completion(.error("License validation returned valid=false"))
                return
            }
            let info = parseLicenseInfo(json)
            saveCachedLicense(info, licenseKey: licenseKey, environment: environment, bundleId: bundleId)
            completion(info.inGracePeriod ? .gracePeriod(info) : .success(info))

        case 402:
            completion(.expired)

        case 401, 403:
            completion(.error("Invalid or revoked license key (HTTP \(statusCode))"))

        default:
            completion(.error("Unexpected response from Veris server (HTTP \(statusCode))"))
        }
    }

    private static func parseLicenseInfo(_ json: [String: Any]) -> VerisLicenseInfo {
        let features = json["features"] as? [String: Any] ?? [:]

        let expiresAt: Date
        if let iso = json["expires_at"] as? String,
           let date = ISO8601DateFormatter().date(from: iso) {
            expiresAt = date
        } else {
            expiresAt = .distantFuture
        }
        let graceExpiresAt: Date
        if let iso = json["grace_expires_at"] as? String,
           let date = ISO8601DateFormatter().date(from: iso) {
            graceExpiresAt = date
        } else {
            graceExpiresAt = Calendar.current.date(byAdding: .day, value: offlineGraceDays, to: expiresAt) ?? expiresAt
        }

        let plan = (json["plan"] as? String ?? "starter").lowercased()
        let now = Date()
        let inGracePeriod = now > expiresAt && now <= graceExpiresAt
        let graceHours = max(0, Int(graceExpiresAt.timeIntervalSince(expiresAt) / 3600))

        // Normalise legacy plan names to canonical tiers so server-omitted fields
        // get consistent defaults regardless of the wire name. Mirrors Android.
        let canonicalPlan: String
        switch plan {
        case "starter", "basic", "free":      canonicalPlan = "launch"
        case "regular", "standard", "growth":  canonicalPlan = "scale"
        case "premium":                        canonicalPlan = "pro"
        default:                               canonicalPlan = plan
        }
        let livenessPlans: Set<String>     = ["launch", "scale", "pro", "enterprise", "sandbox"]
        let activePlans: Set<String>       = ["scale", "pro", "enterprise", "sandbox"]
        let configurablePlans: Set<String> = ["pro", "enterprise"]
        let advancedPlans: Set<String>     = ["pro", "enterprise", "sandbox"]
        let scanPlans: Set<String>         = ["launch", "scale", "pro", "enterprise", "sandbox"]
        let defaultChallengeCount: Int
        switch canonicalPlan {
        case "scale":                          defaultChallengeCount = 1
        case "pro", "enterprise", "sandbox":   defaultChallengeCount = 2
        default:                               defaultChallengeCount = 0
        }

        // `capture_branding` arrives as a string: "required" | "cobrand" | "removed".
        // captureBranding == true means Veris-only branding is enforced.
        let captureBranding = (features["capture_branding"] as? String ?? "required") == "required"

        var info = VerisLicenseInfo(
            clientId: json["client_id"] as? String ?? "",
            plan: plan,
            features: VerisFeatureFlags(
                faceCapture: true,
                qualityChecks: true,
                voiceInstructions: features["voice_instructions"] as? Bool ?? true,
                humanValidation:   features["human_face_validation"] as? Bool ?? (canonicalPlan != "spark"),
                facialLandmarkAnalysis: features["facial_landmark_analysis"] as? Bool ?? true,
                passiveLiveness:   features["passive_liveness"] as? Bool ?? livenessPlans.contains(canonicalPlan),
                activeLiveness:    features["active_liveness"] as? Bool ?? activePlans.contains(canonicalPlan),
                activeLivenessChallenges: features["active_liveness_challenges"] as? Int ?? defaultChallengeCount,
                activeLivenessConfigurable: features["active_liveness_configurable"] as? Bool ?? configurablePlans.contains(canonicalPlan),
                videoCapture:      features["video_capture"] as? Bool ?? (canonicalPlan == "pro" || canonicalPlan == "enterprise"),
                advancedConfig:    features["advanced_config"] as? Bool ?? advancedPlans.contains(canonicalPlan),
                captureBranding:   captureBranding,
                captureMonthlyLimit: features["capture_monthly_limit"] as? Int,
                scanEnabled:       features["scan_enabled"] as? Bool ?? scanPlans.contains(canonicalPlan),
                scanMonthlyLimit:  features["scan_monthly_limit"] as? Int,
                compare:           features["compare"] as? Bool ?? false,
                compareQuotaRemaining: features["compare_quota_remaining"] as? Int ?? 0,
                compareQuotaMonthly:   features["compare_quota_monthly"] as? Int ?? 0
            ),
            expiresAt: expiresAt,
            graceExpiresAt: graceExpiresAt,
            inGracePeriod: inGracePeriod,
            gracePeriodHours: graceHours
        )
        info.environment  = json["environment"]   as? String ?? "production"
        info.licenseKeyId = json["license_key_id"] as? String ?? ""
        return info
    }

    private enum CacheStatus { case active, grace, expired }

    private static func cacheStatus(for info: VerisLicenseInfo) -> CacheStatus {
        if info.expiresAt == .distantFuture || info.graceExpiresAt == .distantFuture { return .active }
        let now = Date()
        if now <= info.expiresAt { return .active }
        if now <= info.graceExpiresAt { return .grace }
        return .expired
    }

    private static func inferEnvironment(from config: VerisConfig) -> String {
        switch config.environment {
        case .sandbox:
            return "sandbox"
        case .production:
            return "production"
        }
    }

    private static func cacheKey(licenseKey: String, environment: String, bundleId: String) -> String {
        let raw = "\(cachePrefix)|\(licenseKey)|\(environment)|\(bundleId)"
        return raw.data(using: .utf8)?.base64EncodedString() ?? raw
    }

    private static func loadCachedLicense(licenseKey: String, environment: String, bundleId: String) -> VerisLicenseInfo? {
        let key = cacheKey(licenseKey: licenseKey, environment: environment, bundleId: bundleId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseLicenseInfo(json)
    }

    private static func saveCachedLicense(_ info: VerisLicenseInfo, licenseKey: String, environment: String, bundleId: String) {
        let key = cacheKey(licenseKey: licenseKey, environment: environment, bundleId: bundleId)
        let payload: [String: Any] = [
            "valid": true,
            "client_id": info.clientId,
            "plan": info.plan,
            "environment": environment,
            "expires_at": ISO8601DateFormatter().string(from: info.expiresAt),
            "grace_expires_at": ISO8601DateFormatter().string(from: info.graceExpiresAt),
            "features": cacheFeaturesPayload(info.features),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Serialise the full feature set into the same wire shape `parseLicenseInfo`
    /// reads back, so an offline cache hit reproduces every flag (not just the
    /// four legacy ones). Keys mirror the server `/v1/sdk/validate` response.
    private static func cacheFeaturesPayload(_ f: VerisFeatureFlags) -> [String: Any] {
        var m: [String: Any] = [
            "voice_instructions": f.voiceInstructions,
            "human_face_validation": f.humanValidation,
            "facial_landmark_analysis": f.facialLandmarkAnalysis,
            "passive_liveness": f.passiveLiveness,
            "active_liveness": f.activeLiveness,
            "active_liveness_challenges": f.activeLivenessChallenges,
            "active_liveness_configurable": f.activeLivenessConfigurable,
            "video_capture": f.videoCapture,
            "advanced_config": f.advancedConfig,
            "capture_branding": f.captureBranding ? "required" : "removed",
            "scan_enabled": f.scanEnabled,
            "compare": f.compare,
            "compare_quota_remaining": f.compareQuotaRemaining,
            "compare_quota_monthly": f.compareQuotaMonthly,
        ]
        if let cap = f.captureMonthlyLimit { m["capture_monthly_limit"] = cap }
        if let cap = f.scanMonthlyLimit    { m["scan_monthly_limit"]    = cap }
        return m
    }
}

// MARK: - Feature Flag Manager

final class FeatureFlagManager {
    private(set) var currentFlags: VerisFeatureFlags?
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 300 // 5 minutes

    func updateFlags(_ flags: VerisFeatureFlags) {
        currentFlags = flags
        fetchedAt = Date()
    }

    var isStale: Bool {
        guard let fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > ttl
    }

    func clear() {
        currentFlags = nil
        fetchedAt = nil
    }
}

// SDKVersion is a legacy alias kept so LicenseValidator's call site compiles.
// The canonical constant is VerisSDKVersion in VerisResultSigner.swift.
private enum SDKVersion {
    static let current = VerisSDKVersion.current
}
