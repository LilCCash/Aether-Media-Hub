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
    /// The system says the picture can be moved into a floating window now (AVPlayer only).
    var isPictureInPicturePossible = false
    /// Why the last attempt to open the floating window failed, in the system's own words (nil when there was none).
    var pictureInPictureFailure: String?
    var isLive = false
}

/// An engine that can start a live channel faster when it knows the stream is live (smaller probe, no waiting for a buffer).
@MainActor
protocol LiveStreamHinting: AnyObject {
    func setLiveStream(_ live: Bool)
}

/// Contract between the player UI and a concrete playback engine. Two implementations ship: `AVPlayerEngine`
/// (system player: HLS, MP4/MOV, true Dolby Vision) and `MPVEngine` (libmpv through MPVKit: MKV, AVI, TS, …).
/// See docs/06-PLAYBACK.md for how the engine is chosen and what each one can honestly promise.
@MainActor
/// What the engine measures while it plays, for the «In tempo reale» part of the information sheet. Every value is nil when
/// the engine does not know it; nothing is guessed.
struct PlaybackLiveStats: Equatable {
    /// Bits per second of the picture and of the sound, as decoded.
    var videoBitrate: Double?
    var audioBitrate: Double?
    /// What the network delivers (AVPlayer).
    var networkBitrate: Double?
    /// Pictures per second actually shown.
    var displayedFrameRate: Double?
    var droppedFrames: Int?
    /// «Hardware (videotoolbox)», «Software», «Sistema (AVFoundation)».
    var decoder: String?
    /// Seconds of video already in memory ahead of the playhead.
    var bufferedSeconds: Double?
}

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
    /// Whether the floating-window button can work right now, and if not why (shown to the viewer as is).
    var pictureInPictureAvailability: PictureInPictureAvailability { get }
    func startPictureInPicture()
    func stopPictureInPicture()
    func setAutoPictureInPicture(_ enabled: Bool)

    /// Whether the system may hand the picture to an AirPlay receiver (AVPlayer only; the other engines cannot).
    func setExternalPlaybackAllowed(_ allowed: Bool)

    /// Detach video output while the app is in the background so audio keeps playing.
    func setVideoDetached(_ detached: Bool)
    func teardown()
    /// Measured now, for the information sheet (called about once a second while it is open).
    func liveStats() -> PlaybackLiveStats?
}

extension PlaybackEngine {
    var identifier: String { kind.rawValue }
    var displayName: String { kind.displayName }
    func setEmbeddedSubtitleDelay(_ seconds: Double) {}
    func setExternalPlaybackAllowed(_ allowed: Bool) {}
    func liveStats() -> PlaybackLiveStats? { return nil }
}
