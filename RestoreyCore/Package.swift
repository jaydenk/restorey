// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RestoreyCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RestoreyCore", targets: ["RestoreyCore"]),
    ],
    targets: [
        .target(
            name: "RestoreyCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RestoreyCoreTests",
            dependencies: ["RestoreyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
