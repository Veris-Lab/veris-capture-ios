# VerisCapture — iOS SDK

On-device face capture with quality gate and liveness detection for iOS. No face image ever leaves the device.

## Installation

### CocoaPods
```ruby
pod 'VerisCapture', '~> 1.0'
```

### Swift Package Manager
```
https://github.com/verisinfra/veris-capture-ios
```

## Usage

```swift
import VerisCaptureSDK

VerisCapture.initialize(licenseKey: "veris_sandbox_reg_xxxx")

VerisCapture.startCapture(from: self, nonce: nonce) { result in
    switch result {
    case .success(let r):
        verifyWithBackend(r.signedPayload)
    case .failure(let e):
        print(e.message)
    }
}
```

## Plans & Features

| Feature | Starter | Regular | Pro |
|---|---|---|---|
| Face capture + quality checks | ✓ | ✓ | ✓ |
| Passive liveness (LBP) | — | ✓ | ✓ |
| Active liveness (dot-follow) | — | 1 round | 2–4 rounds |
| Video capture | — | — | ✓ |
| Signed result payload | ✓ | ✓ | ✓ |

## Requirements

- iOS 15+
- Swift 5.9+
- Valid Veris subscription — [verisinfra.com](https://verisinfra.com)

## Documentation

[docs.verisinfra.com/capture/ios](https://docs.verisinfra.com/capture/ios)

## License

Commercial — see [verisinfra.com/legal/sdk-license](https://verisinfra.com/legal/sdk-license)
