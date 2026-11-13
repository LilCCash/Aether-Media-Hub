import Foundation
import AetherCore

/// A receiver the user can send playback to. AirPlay is not listed here: iOS owns its device list (system picker).
struct CastDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let target: CastTarget
    /// Model / address, shown under the name.
    let detail: String?
    /// The device's IPv4 address, when the backend knows it. A relay session is then served to that device only.
    var address: String? = nil
}

/// What is handed to a remote receiver. The receiver downloads `url` itself.
struct CastMedia: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var url: URL
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var contentType: String
    var isLive: Bool
    var startPosition: Double
    /// Subtitles served by the phone next to the video (Google Cast side-loads them; switching is then instant).
    var textTracks: [CastTextTrack] = []
    /// The subtitle to show from the start (nil: off).
    var activeTextTrackID: Int? = nil
    /// For DLNA: the one SubRip file the television shows (it has no subtitle menu of its own that we can drive).
    var dlnaSubtitleURL: URL? = nil

    // The address may carry the viewer's account key: it must not end up in a log line or a dump by accident.
    var description: String { return "CastMedia" }
    var debugDescription: String { return "CastMedia" }
    var customMirror: Mirror { return Mirror(self, children: [], displayStyle: .struct) }
}

/// A subtitle file the receiver downloads from the phone.
struct CastTextTrack: Equatable {
    var id: Int
    var name: String
    var language: String?
    var url: URL
    var contentType: String
}

/// Where the receiver gets the video from.
enum CastSource {
    /// The source's own address, as it is.
    case direct(URL)
    /// The real address stays on the phone; the receiver gets the relay's.
    case relay(RelayUpstream)
    /// The source's own address with the viewer's account key in it, sent because the viewer chose to in Settings.
    case directWithKey(URL)
    /// The real address stays on the phone, which converts the Matroska file into HLS (copying this audio track) for the receiver.
    case relayRemux(RelayUpstream, RemuxAudioChoice)
}

/// Everything needed to start a remote session, before the address the receiver will use is known.
struct CastRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var contentType: String
    var isLive: Bool
    var startPosition: Double
    var source: CastSource
    /// Preferred embedded subtitle language for phone-side HLS remuxing.
    var subtitleLanguage: String? = nil
    var subtitleTitle: String? = nil
    /// The extension of the file served by the relay (`mkv`, `mp4`…): receivers look at it.
    var fileExtension = "mp4"
    /// Subtitles of addons, OpenSubtitles or downloads, already read on the phone, to send next to the video.
    var sidecars: [CastSidecarSubtitle] = []
    /// The sidecar shown from the start (nil: none of them).
    var activeSidecarID: Int? = nil
    /// The viewer's subtitle delay, applied to the files sent.
    var subtitleOffset: Double = 0

    var delivery: CastDelivery {
        switch source {
        case .direct: return .direct
        case .relay, .relayRemux: return .relay
        case .directWithKey: return .directWithKey
        }
    }

    func media(url: URL) -> CastMedia {
        return CastMedia(url: url, title: title, subtitle: subtitle, artworkURL: artworkURL, contentType: contentType, isLive: isLive,
                         startPosition: startPosition)
    }

    var description: String { return "CastRequest" }
    var debugDescription: String { return "CastRequest" }
    var customMirror: Mirror { return Mirror(self, children: [], displayStyle: .struct) }
}

enum CastPlayState: Equatable {
    case connecting
    case loading
    case buffering
    case playing
    case paused
    case ended
    case failed(String)
}

/// State reported by a backend while a remote session is active.
struct CastRemoteStatus: Equatable {
    var state: CastPlayState
    var position: Double
    var duration: Double?
    /// The audio and subtitle tracks the receiver reports (Google Cast), nil when it says nothing about them (DLNA).
    var tracks: CastTrackList? = nil
}

enum CastAvailability: Equatable {
    case available
    case unavailable(String)
}

enum CastError: LocalizedError {
    case unavailable(String)
    case deviceUnreachable(String)
    case rejected(String)
    case timedOut
    /// The video needs the relay and it cannot be used (the message says why).
    case relayUnavailable(String)
    /// The caller asked to send the key link while the setting that allows it is off.
    case directLinkNotAllowed
    /// The file cannot be converted for the receiver (its codecs cannot be copied, or this build has no converter).
    case conversionRefused(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .deviceUnreachable(let message), .rejected(let message), .relayUnavailable(let message),
             .conversionRefused(let message): return message
        case .timedOut: return "Il televisore non ha avviato la riproduzione entro il tempo previsto."
        case .directLinkNotAllowed: return "L'invio del link diretto al televisore non è attivo: lo trovi in Impostazioni ▸ Avanzate."
        }
    }
}

/// One casting protocol (Google Cast, DLNA…). All calls happen on the main actor.
@MainActor
protocol CastBackend: AnyObject {
    var target: CastTarget { get }
    var availability: CastAvailability { get }
    var devices: [CastDevice] { get }
    var isDiscovering: Bool { get }
    var onDevicesChanged: (() -> Void)? { get set }
    var onStatus: ((CastRemoteStatus) -> Void)? { get set }
    /// The remote side ended the session (user pressed stop on the TV, device vanished).
    var onSessionEnded: ((String?) -> Void)? { get set }

    func startDiscovery()
    func stopDiscovery()
    func load(_ media: CastMedia, on device: CastDevice) async throws
    func play() async
    func pause() async
    func seek(to seconds: Double) async
    func endSession() async
    /// Whether the receiver can switch audio and subtitles while it plays (Google Cast), without loading the video again.
    var supportsLiveTrackSwitching: Bool { get }
    /// Turns on exactly these tracks (one audio, at most one subtitle).
    func setActiveTracks(_ ids: [Int]) async
}

extension CastBackend {
    var supportsLiveTrackSwitching: Bool { return false }
    func setActiveTracks(_ ids: [Int]) async {}
}
