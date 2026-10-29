// swift-tools-version: 5.9
// The remux (Matroska → HLS) of the iOS app, as a Flutter plugin. AetherCore is a copy of Packages/AetherCore (the relay server, the
// remux planner and the HLS playlists). FFmpeg is the one inside media_kit's libmpv (version 6.0, linked by the app itself): CFFmpeg only
// holds that version's headers, so every structure is read at its real offsets. (Headers of another FFmpeg version read garbage.)

import PackageDescription

let package = Package(
    name: "aether_native",
    platforms: [.iOS("16.0")],
    products: [
        .library(name: "aether-native", targets: ["aether_native"])
    ],
    targets: [
        .target(name: "CFFmpeg", path: "Sources/CFFmpeg", publicHeadersPath: "include"),
        .target(name: "AetherCore", path: "Sources/AetherCore"),
        .target(
            name: "aether_native",
            dependencies: ["AetherCore", "CFFmpeg"],
            path: "Sources/aether_native"
        )
    ],
    swiftLanguageVersions: [.v5]
)
