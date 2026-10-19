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

/// Contract between the player UI and a concrete playback engine. `AVPlayerEngine` is the only implementation
/// shipped; an MPV/VLC engine would conform to this protocol without changes to the UI
/// (it is intentionally not bundled: see docs/01-RESEARCH-MATRIX.md §3 for licence and size analysis).
@MainActor
protocol PlaybackEngine: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var snapshot: EngineSnapshot { get }
    var videoView: UIView { get }

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
