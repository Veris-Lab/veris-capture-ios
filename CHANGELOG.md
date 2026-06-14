# Changelog

All notable changes are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

## [1.3.0] - 2026-06-13

### Fixed
- `VerisFeatureFlags` now models the full server feature set — `compare`,
  `compareQuotaRemaining`, `compareQuotaMonthly`, `scanEnabled`, `advancedConfig`,
  `facialLandmarkAnalysis`, `captureBranding`, `activeLivenessChallenges`, and
  capture/scan monthly limits. Previously only 8 flags were parsed, so the
  Flutter and React Native bridges had no compare/quota data to forward to the
  host app.
- `LicenseValidator` parses every feature field from `/v1/sdk/validate` using
  plan-tier defaults, and the offline cache now round-trips the complete flag
  set (was persisting only four legacy flags).

## [1.0.0] - 2026-03-26

### Added
- Initial release
- Face capture with 12-point quality gate
- Human face validation
- Passive liveness (LBP) - Regular and Pro plans
- Active dot-follow liveness challenges - Regular (1 round) and Pro (2-4 rounds)
- ECDSA-signed result payload
- Voice instructions (TTS, rate-limited, offline)
- Sandbox mode with badge indicator
- Swift Package Manager and CocoaPods support
- iOS 15.0+ support, Swift 5.9+
