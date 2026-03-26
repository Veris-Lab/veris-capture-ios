// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VerisCaptureSDK",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "VerisCaptureSDK",
            targets: ["VerisCaptureSDK"]
        ),
    ],
    targets: [
        .target(
            name: "VerisCaptureSDK",
            path: "Sources/VerisSDK",
            resources: []
        ),
    ],
    swiftLanguageVersions: [.v5]
)
