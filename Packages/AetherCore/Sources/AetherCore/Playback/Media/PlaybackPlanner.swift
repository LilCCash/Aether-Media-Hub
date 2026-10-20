import Foundation

public enum PlaybackEngineKind: String, Codable, Equatable, Sendable {
    case avPlayer, mpv

    public var displayName: String {
        switch self {
        case .avPlayer: return "AVPlayer (Apple)"
        case .mpv: return "MPV (libmpv)"
        }
    }
}

/// What the display chain is expected to be given: only ever derived from signalled facts and documented engine behaviour,
/// and always presented as an expectation (nothing here has been measured on a screen).
public enum ExpectedOutput: Equatable, Sendable {
    case unknown
    case sdr
    case hdr10
    case hlg
    case dolbyVision(profile: String)
    /// HDR source shown on an SDR path (the engine tone-maps it).
    case toneMappedToSDR(source: String)
    /// Dolby Vision source shown as HDR10 or SDR because the engine cannot drive a Dolby Vision display.
    case dolbyVisionAsHDR10(profile: String)

    public var label: String {
        switch self {
        case .unknown: return "Non determinabile prima della riproduzione"
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .dolbyVision(let profile): return profile == "?" ? "Dolby Vision" : "Dolby Vision (profilo \(profile))"
        case .toneMappedToSDR(let source): return "SDR (\(source) convertito con tone mapping)"
        case .dolbyVisionAsHDR10(let profile): return "HDR10 ricavato dal Dolby Vision \(profile) (non Dolby Vision nativo)"
        }
    }
}

public struct PlaybackNote: Equatable, Sendable {
    public enum Severity: String, Sendable { case info, warning, blocking }
    public var severity: Severity
    public var text: String

    public init(_ severity: Severity, _ text: String) {
        self.severity = severity
        self.text = text
    }
}

public struct PlaybackPlan: Equatable, Sendable {
    /// nil when the source cannot be played by any engine that is available.
    public var engine: PlaybackEngineKind?
    public var output: ExpectedOutput
    public var notes: [PlaybackNote]

    public var canPlay: Bool { engine != nil }
    public var blockingMessage: String? { notes.first(where: { $0.severity == .blocking })?.text }
}

/// What the device can do, read at run time by the app (`AVPlayer.availableHDRModes`, VideoToolbox, `UIScreen`).
public struct DeviceVideoCapabilities: Equatable, Sendable {
    public var supportsHDR10: Bool
    public var supportsHLG: Bool
    public var supportsDolbyVision: Bool
    public var hardwareHEVC: Bool
    public var hardwareAV1: Bool
    public var hardwareVP9: Bool
    /// `UIScreen.potentialEDRHeadroom`: 1.0 means no HDR headroom at all.
    public var edrHeadroom: Double

    public init(supportsHDR10: Bool = false, supportsHLG: Bool = false, supportsDolbyVision: Bool = false,
                hardwareHEVC: Bool = true, hardwareAV1: Bool = false, hardwareVP9: Bool = false, edrHeadroom: Double = 1) {
        self.supportsHDR10 = supportsHDR10
        self.supportsHLG = supportsHLG
        self.supportsDolbyVision = supportsDolbyVision
        self.hardwareHEVC = hardwareHEVC
        self.hardwareAV1 = hardwareAV1
        self.hardwareVP9 = hardwareVP9
        self.edrHeadroom = edrHeadroom
    }

    /// Nothing known: assume an SDR-only device so that no HDR promise is ever made without evidence.
    public static let conservative = DeviceVideoCapabilities()

    public var hasHDRDisplay: Bool { supportsHDR10 || supportsHLG || supportsDolbyVision || edrHeadroom > 1.0 }
}

/// Chooses the engine and describes the expected result. Pure: the inputs are facts, the output is a decision plus notes.
public enum PlaybackPlanner {
    /// Containers AVFoundation opens natively (the same set the stream analyser uses).
    public static func isNativeToAVFoundation(container: String?) -> Bool {
        guard let container = container?.lowercased(), !container.isEmpty else { return true }
        return StreamAnalyzer.supportedContainers.contains(container)
    }

    /// Dolby Vision profiles an Apple player can render as Dolby Vision from MP4/MOV/HLS: 5, 8.1, 8.2 (SDR base), 8.4.
    /// Profile 7 (dual layer, UHD Blu-ray) is not decodable by Apple's decoders.
    public static func avFoundationSupportsDolbyVision(_ dv: DolbyVisionInfo) -> Bool {
        if dv.profile == 5 { return true }
        if dv.profile == 8 { return [1, 2, 4].contains(dv.baseLayerCompatibility) }
        return false
    }

    public static func plan(container: String?,
                            facts: MediaFormatInfo?,
                            device: DeviceVideoCapabilities,
                            mpvAvailable: Bool,
                            choice: PlayerEngineChoice,
                            forceSDR: Bool = false) -> PlaybackPlan {
        var notes: [PlaybackNote] = []
        let video = facts?.primaryVideo
        let nativeContainer = isNativeToAVFoundation(container: container)
        let avFoundationRefuses = facts?.source == .avFoundation
            && (facts?.platformPlayability == .notPlayable || video?.isDecodable == false)

        var engine: PlaybackEngineKind?
        switch choice {
        case .avPlayer:
            engine = .avPlayer
            if !nativeContainer {
                let name = (container ?? "").uppercased()
                notes.append(PlaybackNote(.blocking, "AVPlayer non apre i file \(name). Scegli «Automatico» o «MPV» in Impostazioni → Riproduzione."))
                engine = nil
            } else if avFoundationRefuses {
                notes.append(PlaybackNote(.blocking, "AVPlayer non riesce a decodificare questo video su questo dispositivo. Scegli «Automatico» o «MPV» in Impostazioni → Riproduzione."))
                engine = nil
            }
        case .mpv:
            if mpvAvailable {
                engine = .mpv
            } else {
                notes.append(PlaybackNote(.blocking, "Il motore MPV non è incluso in questa build."))
            }
        case .automatic:
            if !nativeContainer {
                if mpvAvailable {
                    engine = .mpv
                    notes.append(PlaybackNote(.info, "Contenitore \((container ?? "").uppercased()) non supportato da AVPlayer: uso MPV."))
                } else {
                    notes.append(PlaybackNote(.blocking, "Il contenitore \((container ?? "").uppercased()) non è supportato da AVPlayer e il motore MPV non è incluso in questa build."))
                }
            } else if avFoundationRefuses {
                if mpvAvailable {
                    engine = .mpv
                    if video?.codecTag?.lowercased() == "hev1" {
                        notes.append(PlaybackNote(.info, "Il video HEVC è marcato «hev1», che AVPlayer non riproduce: uso MPV."))
                    } else {
                        notes.append(PlaybackNote(.info, "AVPlayer non può decodificare questo video su questo dispositivo: uso MPV."))
                    }
                } else {
                    notes.append(PlaybackNote(.blocking, "AVPlayer non può decodificare questo video su questo dispositivo e il motore MPV non è incluso in questa build."))
                }
            } else if let dv = video?.dolbyVision, dv.profile != 0, !avFoundationSupportsDolbyVision(dv) {
                if mpvAvailable {
                    engine = .mpv
                    notes.append(PlaybackNote(.info, "Dolby Vision profilo \(dv.profileLabel) non è supportato da AVPlayer: uso MPV."))
                } else {
                    engine = .avPlayer
                    notes.append(PlaybackNote(.warning, "Dolby Vision profilo \(dv.profileLabel) non è supportato da AVPlayer: l'immagine potrebbe non comparire."))
                }
            } else {
                engine = .avPlayer
            }
        }

        let output = expectedOutput(engine: engine, video: video, device: device, forceSDR: forceSDR, notes: &notes)
        return PlaybackPlan(engine: engine, output: output, notes: notes)
    }

    static func expectedOutput(engine: PlaybackEngineKind?, video: VideoTrackFacts?, device: DeviceVideoCapabilities,
                               forceSDR: Bool, notes: inout [PlaybackNote]) -> ExpectedOutput {
        guard let engine = engine, let video = video else { return .unknown }

        if let dv = video.dolbyVision {
            switch engine {
            case .avPlayer:
                if dv.profile != 0 && !avFoundationSupportsDolbyVision(dv) {
                    notes.append(PlaybackNote(.warning, "Dolby Vision profilo \(dv.profileLabel): AVPlayer non lo decodifica, l'immagine potrebbe non comparire."))
                    return .unknown
                }
                if forceSDR || !device.hasHDRDisplay {
                    notes.append(PlaybackNote(.info, "Questo schermo non mostra l'HDR: il Dolby Vision \(dv.profileLabel) sarà convertito in SDR."))
                    return .toneMappedToSDR(source: "Dolby Vision \(dv.profileLabel)")
                }
                if device.supportsDolbyVision {
                    return .dolbyVision(profile: dv.profileLabel)
                }
                // A Dolby Vision file on a device without Dolby Vision: the base layer is shown when it is HDR10/HLG.
                switch dv.baseLayerRange {
                case .hdr10: return device.supportsHDR10 ? .dolbyVisionAsHDR10(profile: dv.profileLabel) : .toneMappedToSDR(source: "HDR10")
                case .hlg: return device.supportsHLG ? .hlg : .toneMappedToSDR(source: "HLG")
                default: return .unknown
                }
            case .mpv:
                notes.append(PlaybackNote(.info, "MPV non pilota lo schermo in Dolby Vision: il segnale (profilo \(dv.profileLabel)) viene mappato su HDR10 o SDR."))
                if forceSDR || !device.hasHDRDisplay { return .toneMappedToSDR(source: "Dolby Vision \(dv.profileLabel)") }
                return .dolbyVisionAsHDR10(profile: dv.profileLabel)
            }
        }

        switch video.range {
        case .hdr10:
            if forceSDR || !device.hasHDRDisplay { return .toneMappedToSDR(source: "HDR10") }
            return .hdr10
        case .hlg:
            if forceSDR || !device.hasHDRDisplay { return .toneMappedToSDR(source: "HLG") }
            return .hlg
        case .sdr:
            return .sdr
        case .unknown:
            return .unknown
        }
    }
}
