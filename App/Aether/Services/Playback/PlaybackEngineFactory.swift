import Foundation
import AetherCore

/// Builds playback engines and reports which ones this build contains.
@MainActor
enum PlaybackEngineFactory {
    /// True when libmpv (MPVKit) is linked into this build.
    static var mpvAvailable: Bool {
        #if canImport(Libmpv)
        return true
        #else
        return false
        #endif
    }

    static var capabilities: PlaybackCapabilities { PlaybackCapabilities(mpvAvailable: mpvAvailable) }

    /// Automated tests on machines without a GPU run mpv with its `null` video output (`-AETHER_UITEST_MPV_HEADLESS`).
    /// It exists only behind the UI-test launch flag and is never reachable from the app's settings.
    private static var headlessVideo: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-AETHER_UITEST") && arguments.contains("-AETHER_UITEST_MPV_HEADLESS")
    }

    /// nil when MPV is not part of this build. Plain Swift values only, so test targets need not import libmpv.
    struct MPVReport: Equatable {
        var initStatus: Int32
        var mpvVersion: String?
        var ffmpegVersion: String?
        var decoders: String
        var demuxers: String
    }

    static func mpvSelfTest() -> MPVReport? {
        #if canImport(Libmpv)
        guard let result = MPVSelfTest.run() else { return nil }
        return MPVReport(initStatus: result.initStatus, mpvVersion: result.mpvVersion, ffmpegVersion: result.ffmpegVersion,
                         decoders: result.decoders, demuxers: result.demuxers)
        #else
        return nil
        #endif
    }

    static func make(_ kind: PlaybackEngineKind, settings: PlaybackSettings, device: DeviceVideoCapabilities) -> PlaybackEngine {
        switch kind {
        case .avPlayer:
            return AVPlayerEngine(bufferSeconds: settings.video.bufferSeconds)
        case .mpv:
            #if canImport(Libmpv)
            return MPVEngine(settings: settings, device: device, headlessVideo: headlessVideo)
            #else
            return AVPlayerEngine(bufferSeconds: settings.video.bufferSeconds)
            #endif
        }
    }
}
