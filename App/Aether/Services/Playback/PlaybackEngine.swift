import UIKit
import AetherCore

/// Audio / subtitle track exposed by an engine.
struct EngineTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let language: String?
    var isSelected: Bool
}

/// Immutable state snapshot published by an engine; the UI never reads the engine directly while rendering.
struct EngineSnapshot: Equatable {
    var isPlaying = false
    var isBuffering = false
    var isReady = false
    var position: Double = 0
    var duration: Double = 0
    var bufferedPosition: Double = 0
    var rate: Float = 1
    var videoSize: CGSize = .zero
    var isExternalPlaybackActive = false
    var isPictureInPictureActive = false
    var isLive = false
}

/// Contract between the player UI and a concrete playback engine. Two implementations ship: `AVPlayerEngine`
/// (system player: HLS, MP4/MOV, true Dolby Vision) and `MPVEngine` (libmpv through MPVKit: MKV, AVI, TS, …).
/// See docs/06-PLAYBACK.md for how the engine is chosen and what each one can honestly promise.
@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    var identifier: String { get }
    var displayName: String { get }
    var snapshot: EngineSnapshot { get }
    var videoView: UIView { get }
    /// Facts the engine measured about the file (nil until it knows). Never derived from the file name.
    var mediaInfo: MediaFormatInfo? { get }
    var onMediaInfo: ((MediaFormatInfo) -> Void)? { get set }

    var onSnapshot: ((EngineSnapshot) -> Void)? { get set }
    var onEnded: (() -> Void)? { get set }
    var onFailure: ((PlaybackFailure) -> Void)? { get set }
    var onTracksChanged: (() -> Void)? { get set }

    func load(url: URL, headers: [String: String], startAt: Double?, autoplay: Bool)
    /// Precise playhead (the snapshot only updates twice a second; subtitles need finer timing).
    func currentTime() -> Double
    func play()
    func pause()
    func seek(to seconds: Double, precise: Bool)
    func seek(by delta: Double)
    func setRate(_ rate: Float)
    func setFillScreen(_ fill: Bool)
    /// Delay of the subtitles the engine draws itself (embedded tracks). The app applies its own delay to external ones.
    func setEmbeddedSubtitleDelay(_ seconds: Double)

    func audioTracks() -> [EngineTrack]
    func embeddedSubtitleTracks() -> [EngineTrack]
    func selectAudio(id: String?)
    func selectEmbeddedSubtitle(id: String?)

    var supportsPictureInPicture: Bool { get }
    func startPictureInPicture()
    func stopPictureInPicture()
    func setAutoPictureInPicture(_ enabled: Bool)

    /// Detach video output while the app is in the background so audio keeps playing.
    func setVideoDetached(_ detached: Bool)
    func teardown()
}

extension PlaybackEngine {
    var identifier: String { kind.rawValue }
    var displayName: String { kind.displayName }
    func setEmbeddedSubtitleDelay(_ seconds: Double) {}
}
