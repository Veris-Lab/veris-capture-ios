import Foundation
import Security
import CryptoKit

/// DeviceKeyStore — per-install ECDSA P-256 signing key backed by the Secure Enclave (when
/// available) or the standard iOS keychain (fallback).
///
/// Direct iOS equivalent of the Android `DeviceKeyStore`. The private key is non-exportable;
/// the matching public key is sent to the Veris backend during `/v1/sdk/validate` as
/// `device_public_key`. The backend verifies result JWS tokens against that per-device key,
/// so extracting the IPA yields nothing that can forge a valid signed result.
internal enum DeviceKeyStore {

    private static let tag = "com.veris.sdk.device_signing_key_v1"

    /// True when the key lives in the Secure Enclave.
    private(set) static var isHardwareBacked: Bool = false

    // MARK: - Key lifecycle

    /// Ensure the signing keypair exists, generating it on first call.
    @discardableResult
    static func ensureKeyPair() -> Bool {
        if existingPrivateKey() != nil { return true }
        return generateKey(secureEnclave: isSecureEnclaveAvailable()) || generateKey(secureEnclave: false)
    }

    private static func isSecureEnclaveAvailable() -> Bool {
        guard #available(iOS 13.0, *) else { return false }
        return SecureEnclave.isAvailable
    }

    private static func generateKey(secureEnclave: Bool) -> Bool {
        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            secureEnclave ? .privateKeyUsage : [],
            &error
        )
        guard error == nil, let access else { return false }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String:    true,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
                kSecAttrAccessControl as String:  access,
            ] as [String: Any],
        ]
        if secureEnclave {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }

        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil, error == nil else {
            return false
        }
        isHardwareBacked = secureEnclave
        return true
    }

    // MARK: - Key access

    static func privateKey() -> SecKey? {
        ensureKeyPair()
        return existingPrivateKey()
    }

    private static func existingPrivateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassKey,
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyClass as String:       kSecAttrKeyClassPrivate,
            kSecReturnRef as String:          true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as! SecKey)
    }

    static func publicKey() -> SecKey? {
        guard let priv = privateKey() else { return nil }
        return SecKeyCopyPublicKey(priv)
    }

    /// X.509 SubjectPublicKeyInfo DER, then PEM-wrapped. Sent to backend as `device_public_key`.
    static func publicKeyPem() -> String? {
        guard let pubKey = publicKey(),
              let data = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else { return nil }
        // Raw 65-byte uncompressed point → wrap in SubjectPublicKeyInfo DER header for P-256
        let spkiHeader: [UInt8] = [
            0x30, 0x59,
            0x30, 0x13,
            0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00,
        ]
        let der = Data(spkiHeader) + data
        let b64 = der.base64EncodedString()
        let wrapped = b64.chunks(ofCount: 64).joined(separator: "\n")
        return "-----BEGIN PUBLIC KEY-----\n\(wrapped)\n-----END PUBLIC KEY-----"
    }

    /// Short fingerprint embedded in the JWS header as `kid`.
    static func publicKeyId() -> String {
        guard let pubKey = publicKey(),
              let raw = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else {
            return "veris-device-unknown"
        }
        let hash = SHA256.hash(data: raw)
        let hex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "veris-device-\(hex)"
    }

    // MARK: - Signing

    /// Sign `data` with SHA256withECDSA. Returns the raw fixed-size JOSE signature (r||s, 64 bytes).
    static func sign(data: Data) -> Data? {
        guard let privKey = privateKey() else { return nil }
        var error: Unmanaged<CFError>?
        guard let derSig = SecKeyCreateSignature(
            privKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) as Data? else { return nil }
        return derToJose(derSig, outputSize: 64)
    }

    // MARK: - DER → JOSE conversion

    private static func derToJose(_ der: [UInt8], outputSize: Int) -> Data? {
        var pos = 1  // skip SEQUENCE tag 0x30
        let seqLenByte = Int(der[pos]); pos += 1
        if seqLenByte == 0x81 { pos += 1 }
        else if seqLenByte == 0x82 { pos += 2 }

        guard pos < der.count else { return nil }
        pos += 1  // skip INTEGER tag 0x02
        let rLen = Int(der[pos]); pos += 1
        let r = Array(der[pos ..< pos + rLen]); pos += rLen

        guard pos < der.count else { return nil }
        pos += 1  // skip INTEGER tag 0x02
        let sLen = Int(der[pos]); pos += 1
        let s = Array(der[pos ..< pos + sLen])

        let half = outputSize / 2
        var raw = [UInt8](repeating: 0, count: outputSize)
        let rTrimmed = r.drop(while: { $0 == 0 })
        let sTrimmed = s.drop(while: { $0 == 0 })
        let rStart = half - rTrimmed.count
        let sStart = outputSize - sTrimmed.count
        raw.replaceSubrange(rStart ..< rStart + rTrimmed.count, with: rTrimmed)
        raw.replaceSubrange(sStart ..< sStart + sTrimmed.count, with: sTrimmed)
        return Data(raw)
    }

    private static func derToJose(_ der: Data, outputSize: Int) -> Data? {
        return derToJose(Array(der), outputSize: outputSize)
    }
}

// MARK: - Helpers

private extension String {
    func chunks(ofCount n: Int) -> [String] {
        stride(from: 0, to: count, by: n).map {
            let start = index(startIndex, offsetBy: $0)
            let end   = index(start, offsetBy: Swift.min(n, count - $0))
            return String(self[start ..< end])
        }
    }
}
