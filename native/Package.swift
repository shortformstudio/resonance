// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Resonance",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Resonance",
            path: "Sources/Resonance",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
