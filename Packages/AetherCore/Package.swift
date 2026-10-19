// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AetherCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AetherCore", targets: ["AetherCore"])
    ],
    targets: [
        .target(
            name: "AetherCore",
            path: "Sources/AetherCore"
        ),
        .testTarget(
            name: "AetherCoreTests",
            dependencies: ["AetherCore"],
            path: "Tests/AetherCoreTests",
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
