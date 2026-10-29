import Foundation

/// What the viewer should be told about AirPlay while a video plays. The AirPlay button is the system's route picker: with the MPV
/// engine it moves only the sound to the chosen device, because only AVPlayer can send the picture.
public enum AirPlayAdvice: Equatable, Sendable {
    case none
    /// MPV is playing: the device gets the sound and the picture stays on the phone.
    case audioOnlyBecauseMPV(route: String)
    /// AVPlayer could send the picture, but the source's link carries the account key and the relay is not available.
    case audioOnlyBecauseKeyProtected(route: String)
    /// The picture goes to the device through the phone's relay.
    case videoViaRelay(route: String)

    public static func evaluate(engine: PlaybackEngineKind,
                                routeName: String?,
                                externalPlaybackActive: Bool,
                                screenMirrored: Bool,
                                externalPlaybackBlockedForKey: Bool,
                                relayServing: Bool) -> AirPlayAdvice {
        guard let raw = routeName else { return .none }
        let route = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "AirPlay" : raw
        if screenMirrored { return .none }
        switch engine {
        case .mpv:
            return .audioOnlyBecauseMPV(route: route)
        case .avPlayer:
            if externalPlaybackBlockedForKey { return .audioOnlyBecauseKeyProtected(route: route) }
            if relayServing && externalPlaybackActive { return .videoViaRelay(route: route) }
            return .none
        }
    }
}
