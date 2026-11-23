// swift-tools-version: 6.0
import PackageDescription

// Logic shared by the iPhone app and its keyboard extension. It builds for macOS too so that
// `swift test --package-path ios/LautliKit` runs in the existing macOS CI job without a simulator.
let package = Package(
    name: "LautliKit",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "LautliKit", targets: ["LautliKit"])],
    targets: [
        .target(name: "LautliKit"),
        .testTarget(name: "LautliKitTests", dependencies: ["LautliKit"]),
    ]
)
