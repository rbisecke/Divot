// swift-tools-version:5.9
import PackageDescription

// SwingCore — the shared, platform-agnostic swing-analysis engine used by both the
// macOS CLI (validation oracle) and the future iOS app. Pure Apple frameworks.
//
// Validation: `swift run swingcore-check` (headless, works with Command Line Tools).
// XCTest suite (`SwingCoreTests`) is for use inside Xcode.
let package = Package(
    name: "SwingCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SwingCore", targets: ["SwingCore"]),
        .executable(name: "swingcore-check", targets: ["SwingCoreCheck"])
    ],
    targets: [
        .target(name: "SwingCore", resources: [.copy("Resources/reference")]),
        .executableTarget(name: "SwingCoreCheck", dependencies: ["SwingCore"]),
        .testTarget(name: "SwingCoreTests", dependencies: ["SwingCore"])
    ]
)
