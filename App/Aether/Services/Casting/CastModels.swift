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

    // The address may carry the viewer's account key: it must not end up in a log line or a dump by accident.
    var description: String { return "CastMedia" }
    var debugDescription: String { return "CastMedia" }
    var customMirror: Mirror { return Mirror(self, children: [], displayStyle: .struct) }
}

/// Where the receiver gets the video from.
enum CastSource {
    /// The source's own address, as it is.
    case direct(URL)
    /// The real address stays on the phone; the receiver gets the relay's.
    case relay(RelayUpstream)
    /// The source's own address with the viewer's account key in it, sent because the viewer chose to in Settings.
    case directWithKey(URL)
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
    /// The extension of the file served by the relay (`mkv`, `mp4`…): receivers look at it.
    var fileExtension = "mp4"

    var delivery: CastDelivery {
        switch source {
        case .direct: return .direct
        case .relay: return .relay
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

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .deviceUnreachable(let message), .rejected(let message), .relayUnavailable(let message): return message
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
}
