[![CI](https://github.com/Veris-Lab/veris-capture-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/Veris-Lab/veris-capture-ios/actions/workflows/ci.yml)
[![CocoaPods](https://img.shields.io/cocoapods/v/VerisCapture.svg)](https://cocoapods.org/pods/VerisCapture)
[![SPM compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://github.com/Veris-Lab/veris-capture-ios)
[![License](https://img.shields.io/badge/license-Commercial-lightgrey.svg)](https://verisinfra.com/legal/sdk-license)
[![iOS 15+](https://img.shields.io/badge/iOS-15%2B-blue.svg)]()

# VerisCapture - iOS SDK

On-device face capture with quality gate and liveness detection for iOS.

No face image ever leaves the device. Every result is cryptographically signed (ECDSA) and verified server-side.

**Docs:** [verisinfra.com/docs](https://verisinfra.com/docs)

---

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15+
- A Veris subscription - get a free sandbox key at https://verisinfra.com

---

## Installation

### Swift Package Manager

In Xcode: File > Add Package Dependencies

```
https://github.com/Veris-Lab/veris-capture-ios
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Veris-Lab/veris-capture-ios.git", from: "1.0.0")
]
```

### CocoaPods

```ruby
pod 'VerisCapture', '~> 1.0'
```

Then:

```bash
pod install
```

---

## Setup

Add camera usage description to `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Required for identity verification</string>
```

---

## Quick start

```swift
import VerisCaptureSDK

// Initialise once - at app startup
VerisCapture.initialize(licenseKey: "veris_sandbox_reg_xxxx")

// Fetch a nonce from your backend before each session
let nonce = try await yourBackend.fetchNonce()

// Start capture
VerisCapture.startCapture(from: self, nonce: nonce) { result in
    switch result {
    case .success(let r):
        // Send signed payload to your backend
        Task { try await yourBackend.verifyResult(r.signedPayload) }

    case .failure(let e):
        print("Capture failed: \(e.message)")

    case .subscriptionInactive:
        showRenewalPrompt()

    case .cancelled:
        break
    }
}
```

The SDK never throws an unhandled exception. It always returns one of these four states.

---

## Liveness detection by plan

| Feature | Starter | Regular | Pro |
|---|---|---|---|
| Face capture + quality checks | Yes | Yes | Yes |
| Passive liveness (LBP) | - | Yes | Yes |
| Active liveness - 1 dot-follow round | - | Yes | Yes |
| Active liveness - 2-4 dot-follow rounds | - | - | Yes |
| Video capture | - | - | Yes |
| Advanced config (strictness, timeout) | - | - | Yes |

Liveness runs automatically based on your plan flags - no extra configuration needed.

---

## Pro active liveness configuration

```swift
let config = VerisSessionConfig(
    proRandomChallengeCount: 3,  // 2-4 rounds, Pro only
    enforceChallenge: true       // force active liveness even if passive passed
)

VerisCapture.startCapture(from: self, nonce: nonce, config: config) { result in
    // ...
}
```

---

## Nonce flow (replay attack protection)

Generate a fresh nonce on your backend before each session. The SDK embeds it in the signed payload. Your backend verifies it was never used before.

```swift
// Fetch nonce from your backend
func fetchNonce() async throws -> String {
    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: URL(string: "https://your-api.com/generate-nonce")!))
    return try JSONDecoder().decode([String: String].self, from: data)["nonce"]!
}
```

```swift
// After capture, verify the signed payload server-side
func verifyResult(_ signedPayload: String) async throws {
    var request = URLRequest(url: URL(string: "https://your-api.com/verify-result")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["signed_payload": signedPayload])
    let (_, response) = try await URLSession.shared.data(for: request)
    // handle response
}
```

Your backend calls `POST https://api.verisinfra.com/v1/sdk/verify-result` with the signed payload.

---

## Sandbox mode

Use a sandbox key during development. Free, no payment required:

```swift
VerisCapture.initialize(licenseKey: "veris_sandbox_reg_xxxx")
```

The SDK shows a small "SANDBOX" badge in the top-right of the camera preview. It disappears automatically on production keys.

Sandbox limits: 50 sessions per day. Results are marked `"environment": "sandbox"`.

---

## Signed result payload

On success, the SDK returns a JSON payload signed with ECDSA:

```json
{
  "session_id": "uuid-v4",
  "nonce": "uuid-from-host-app",
  "timestamp": "2026-03-01T12:00:00Z",
  "environment": "production",
  "plan": "regular",
  "sdk_version": "1.0.0",
  "platform": "ios",
  "image_hash": "sha256-of-captured-face",
  "quality_score": 0.87,
  "liveness_score": 0.82,
  "liveness_status": "passed",
  "challenges_completed": ["dot_follow"],
  "signature": "ECDSA-signature"
}
```

Send this to your backend and forward to `POST https://api.verisinfra.com/v1/sdk/verify-result` for server-side verification.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

Commercial - see [verisinfra.com/legal/sdk-license](https://verisinfra.com/legal/sdk-license)
