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

        let body: [String: Any] = [
            "license_key": config.licenseKey,
            "package_name": bundleId,
            "platform": "ios",
            "sdk_version": SDKVersion.current,
            "session_nonce": config.initNonce,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]

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

        return VerisLicenseInfo(
            clientId: json["client_id"] as? String ?? "",
            plan: plan,
            features: VerisFeatureFlags(
                faceCapture: true,
                qualityChecks: true,
                voiceInstructions: true,
                humanValidation:   features["human_face_validation"] as? Bool ?? (plan != "starter"),
                passiveLiveness:   features["passive_liveness"] as? Bool ?? false,
                activeLiveness:    features["active_liveness"] as? Bool ?? false,
                videoCapture:      features["video_capture"] as? Bool ?? false
            ),
            expiresAt: expiresAt,
            graceExpiresAt: graceExpiresAt,
            inGracePeriod: inGracePeriod,
            gracePeriodHours: graceHours
        )
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
            "features": [
                "human_face_validation": info.features.humanValidation,
                "passive_liveness": info.features.passiveLiveness,
                "active_liveness": info.features.activeLiveness,
                "video_capture": info.features.videoCapture,
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            UserDefaults.standard.set(data, forKey: key)
        }
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

// MARK: - SDK Version

enum SDKVersion {
    static let current = "1.0.0"
}
