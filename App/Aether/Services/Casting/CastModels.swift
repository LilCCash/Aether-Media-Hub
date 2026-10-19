import Foundation
import AetherCore

/// A receiver the user can send playback to. AirPlay is not listed here: iOS owns its device list (system picker).
struct CastDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let target: CastTarget
    /// Model / address, shown under the name.
    let detail: String?
}

/// What is handed to a remote receiver. The receiver downloads `url` itself.
struct CastMedia {
    var url: URL
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var contentType: String
    var isLive: Bool
    var startPosition: Double
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

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .deviceUnreachable(let message), .rejected(let message): return message
        case .timedOut: return "Il televisore non ha avviato la riproduzione entro il tempo previsto."
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
