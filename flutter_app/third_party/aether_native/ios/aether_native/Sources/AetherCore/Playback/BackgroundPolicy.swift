import Foundation

/// What the player does with picture and sound when the app leaves the screen.
///
/// iOS reports three phases and they must not be treated alike: **inactive** is what the app goes through when the
/// notification shade or Control Center is pulled down, for an incoming call, in the app switcher and, importantly, on the way
/// to the Home screen *before* it is in the background. Automatic Picture in Picture is started by the system at that moment
/// from the video layer on screen, so tearing the picture down on "inactive" (as 1.0 did) makes PiP impossible. Only
/// **background** is a decision point.
public enum PlayerBackgroundPolicy {
    public enum Phase: Equatable, Sendable {
        case active, inactive, background
    }

    public struct State: Equatable, Sendable {
        public var phase: Phase
        public var isPlaying: Bool
        public var isPictureInPictureActive: Bool
        public var isExternalPlaybackActive: Bool
        /// The system says the picture can be moved into a floating window right now.
        public var isPictureInPicturePossible: Bool
        public var autoPictureInPicture: Bool
        public var allowBackgroundAudio: Bool
        /// The grace period of `waitForPictureInPicture` ran out without PiP starting.
        public var pictureInPictureGraceExpired: Bool

        public init(phase: Phase,
                    isPlaying: Bool,
                    isPictureInPictureActive: Bool = false,
                    isExternalPlaybackActive: Bool = false,
                    isPictureInPicturePossible: Bool = false,
                    autoPictureInPicture: Bool = false,
                    allowBackgroundAudio: Bool = true,
                    pictureInPictureGraceExpired: Bool = false) {
            self.phase = phase
            self.isPlaying = isPlaying
            self.isPictureInPictureActive = isPictureInPictureActive
            self.isExternalPlaybackActive = isExternalPlaybackActive
            self.isPictureInPicturePossible = isPictureInPicturePossible
            self.autoPictureInPicture = autoPictureInPicture
            self.allowBackgroundAudio = allowBackgroundAudio
            self.pictureInPictureGraceExpired = pictureInPictureGraceExpired
        }
    }

    public enum VideoAction: Equatable, Sendable {
        /// Show the picture again (the app is back).
        case attach
        /// Leave the picture exactly as it is.
        case keep
        /// Drop the picture, keep the sound.
        case detach
    }

    public struct Decision: Equatable, Sendable {
        public var recordProgress: Bool
        public var video: VideoAction
        public var pause: Bool
        /// Picture in Picture may still start by itself: decide again after `pictureInPictureGrace`.
        public var waitForPictureInPicture: Bool
    }

    /// How long the system is given to move the video into the floating window before the app falls back.
    public static let pictureInPictureGrace: TimeInterval = 0.8

    public static func decide(_ state: State) -> Decision {
        switch state.phase {
        case .active:
            return Decision(recordProgress: false, video: .attach, pause: false, waitForPictureInPicture: false)
        case .inactive:
            return Decision(recordProgress: true, video: .keep, pause: false, waitForPictureInPicture: false)
        case .background:
            if state.isPictureInPictureActive || state.isExternalPlaybackActive {
                return Decision(recordProgress: true, video: .keep, pause: false, waitForPictureInPicture: false)
            }
            if state.autoPictureInPicture, state.isPlaying, state.isPictureInPicturePossible, !state.pictureInPictureGraceExpired {
                return Decision(recordProgress: true, video: .keep, pause: false, waitForPictureInPicture: true)
            }
            if state.allowBackgroundAudio {
                return Decision(recordProgress: true, video: .detach, pause: false, waitForPictureInPicture: false)
            }
            return Decision(recordProgress: true, video: .keep, pause: true, waitForPictureInPicture: false)
        }
    }
}

/// Whether the Picture in Picture button can do anything, and the honest reason when it cannot.
public enum PictureInPictureAvailability: Equatable, Sendable {
    case available
    /// AVPlayer could do it but the system is not ready (the file has not been opened, or has no picture).
    case notReadyYet
    /// This engine cannot show a floating window (MPV draws with Metal, outside the system player).
    case engineUnsupported(engine: String)
    /// The device or the way the app is launched does not allow it.
    case deviceUnsupported

    /// - Parameter fileIsReady: the file has been opened by the player. Once it has, "not possible" is no longer "not yet": the
    ///   system refuses (a file without a picture, or a host such as a container that does not allow it) and waiting will not help.
    public static func evaluate(engine: PlaybackEngineKind,
                                deviceSupportsPictureInPicture: Bool,
                                controllerExists: Bool,
                                isPossible: Bool,
                                fileIsReady: Bool = false) -> PictureInPictureAvailability {
        switch engine {
        case .mpv:
            return .engineUnsupported(engine: engine.displayName)
        case .avPlayer:
            guard deviceSupportsPictureInPicture, controllerExists else { return .deviceUnsupported }
            if isPossible { return .available }
            return fileIsReady ? .deviceUnsupported : .notReadyYet
        }
    }

    public var canStart: Bool {
        if case .available = self { return true }
        return false
    }

    /// Shown to the viewer when they press the button and nothing can happen.
    public var explanation: String? {
        switch self {
        case .available:
            return nil
        case .notReadyYet:
            return "Il Picture in Picture non è ancora pronto: aspetta che il video parta e riprova."
        case .engineUnsupported:
            return "Con il motore MPV (MKV, AVI e altri formati) il Picture in Picture non è disponibile. Con AVPlayer (MP4, MOV) può funzionare, se il sistema lo consente."
        case .deviceUnsupported:
            return "Il sistema non permette il Picture in Picture per questo video o in questo ambiente. In LiveContainer può non funzionare: prova con l'app installata."
        }
    }
}
