// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RestoreyCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RestoreyCore", targets: ["RestoreyCore"]),
        // The agent's testable logic. Only the agent links it.
        .library(name: "AgentCore", targets: ["AgentCore"]),
    ],
    targets: [
        .target(
            name: "RestoreyCore",
            // EFF's large word list for generated repository passwords (README: third-party material).
            resources: [.copy("Resources/eff_large_wordlist.txt")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AgentCore",
            dependencies: ["RestoreyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Helpers both test targets share (a test target can't import another). Not a product: the app never links it.
        .target(
            name: "TestSupport",
            path: "Tests/TestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RestoreyCoreTests",
            dependencies: ["RestoreyCore", "TestSupport"],
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore", "RestoreyCore", "TestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
