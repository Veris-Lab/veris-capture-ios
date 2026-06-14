import Foundation
import CryptoKit

/// VerisResultSigner — produces a compact JWS (ES256) signed verification result payload.
///
/// iOS equivalent of the Android `VerisResultSigner`. The token format is identical so the
/// backend's single verifier handles both platforms.
internal enum VerisResultSigner {

    struct SignedResult {
        let token: String
        let qualityScore: Float
        let livenessScore: Float
        let nonce: String
        let capturedAt: String
    }

    static func sign(
        jpegData: Data,
        qualityScore: Float,
        livenessScore: Float,
        nonce: String,
        environment: String = "production",
        plan: String = "starter",
        packageName: String = "",
        challengesCompleted: [String] = [],
        licenseKeyId: String = "",
        reasonCode: String = "NONE",
        status: String = "SUCCESS",
        validationState: String = "verified",
        injectionRisk: Float = 0,
        injectionDetail: String = ""
    ) -> SignedResult {
        let capturedAt = ISO8601DateFormatter().string(from: Date())
        let faceHash   = jpegData.isEmpty ? "empty" : sha256Hex(jpegData)
        let keyId      = DeviceKeyStore.publicKeyId()

        let header: [String: Any] = [
            "alg": "ES256",
            "typ": "JWT",
            "kid": keyId,
        ]

        var payload: [String: Any] = [
            "ver":              "2.0",
            "status":           status,
            "session_id":       UUID().uuidString,
            "nonce":            nonce,
            "timestamp":        capturedAt,
            "environment":      environment,
            "plan":             plan,
            "sdk_version":      VerisSDKVersion.current,
            "build_number":     VerisSDKVersion.build,
            "platform":         "ios",
            "package_name":     packageName,
            "license_key_id":   licenseKeyId,
            "quality_score":    qualityScore,
            "liveness_score":   livenessScore,
            "face_hash":        faceHash,
            "reason_code":      reasonCode,
            "signing_mode":     "ES256",
            "public_key_id":    keyId,
            "hardware_backed":  DeviceKeyStore.isHardwareBacked,
            "validation_state": validationState,
            "injection_risk":   injectionRisk,
        ]
        if !injectionDetail.isEmpty {
            payload["injection_detail"] = injectionDetail
        }
        if !challengesCompleted.isEmpty {
            payload["challenges_completed"] = challengesCompleted
        }

        let encodedHeader  = base64url(jsonObject: header)
        let encodedPayload = base64url(jsonObject: payload)
        let signingInput   = "\(encodedHeader).\(encodedPayload)"

        var token = "\(signingInput)."
        if let sigData = DeviceKeyStore.sign(data: Data(signingInput.utf8)) {
            token += base64url(data: sigData)
        }

        return SignedResult(
            token: token,
            qualityScore: qualityScore,
            livenessScore: livenessScore,
            nonce: nonce,
            capturedAt: capturedAt
        )
    }

    static func signFailure(nonce: String, reasonCode: String, licenseKeyId: String = "") -> SignedResult {
        return sign(
            jpegData: Data(),
            qualityScore: 0,
            livenessScore: 0,
            nonce: nonce,
            licenseKeyId: licenseKeyId,
            reasonCode: reasonCode,
            status: "FAILURE"
        )
    }

    // MARK: - Helpers

    private static func base64url(jsonObject: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]) else {
            return ""
        }
        return base64url(data: data)
    }

    private static func base64url(data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - SDK version constants

internal enum VerisSDKVersion {
    static let current = "1.3.0"
    static let build   = 3
}
