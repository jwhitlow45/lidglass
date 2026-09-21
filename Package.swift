// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LidGlass",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LidGlassCore",
            path: "Sources/LidGlassCore"
        ),
        .executableTarget(
            name: "LidGlass",
            dependencies: ["LidGlassCore"],
            path: "Sources/LidGlass",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The command line tools ship neither XCTest nor the Swift Testing macro plugin,
        // so the checks are a plain executable: `swift run LidGlassChecks`.
        .executableTarget(
            name: "LidGlassChecks",
            dependencies: ["LidGlassCore"],
            path: "Sources/LidGlassChecks"
        ),
    ]
)
