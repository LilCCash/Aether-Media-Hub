// swift-tools-version: 5.9
// The remux (Matroska → HLS) of the iOS app, as a Flutter plugin. AetherCore is a copy of Packages/AetherCore (the relay server, the
// remux planner and the HLS playlists); FFmpeg comes from MPVKit (the LGPL product).

import PackageDescription

let package = Package(
    name: "aether_native",
    platforms: [.iOS("16.0")],
    products: [
        .library(name: "aether-native", targets: ["aether_native"])
    ],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit", exact: "1.0.0")
    ],
    targets: [
        .target(name: "AetherCore", path: "Sources/AetherCore"),
        .target(
            name: "aether_native",
            dependencies: [
                "AetherCore",
                .product(name: "MPVKit", package: "MPVKit")
            ],
            path: "Sources/aether_native"
        )
    ],
    swiftLanguageVersions: [.v5]
)
