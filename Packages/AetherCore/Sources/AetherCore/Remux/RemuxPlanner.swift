import Foundation

// MKV → fragmented MP4 ("remux"): the video and audio are copied, not re-encoded, into pieces a system player understands. These
// types describe what is in the file and decide what can be copied; the FFmpeg work itself is done by an engine the app provides.

/// One track of the source file, as the demuxer reports it.
public struct RemuxStreamInfo: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case video, audio, subtitle, other
    }

    public var index: Int
    public var kind: Kind
    /// FFmpeg's codec name: `h264`, `hevc`, `aac`, `ac3`, `eac3`, `dts`, `truehd`, `subrip`…
    public var codec: String
    public var profile: String?
    public var bitDepth: Int?
    public var width: Int?
    public var height: Int?
    public var channels: Int?
    /// ISO 639 code as the file states it.
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    /// The Dolby Vision profile found in the stream's configuration, if any.
    public var dolbyVisionProfile: Int?

    public init(index: Int, kind: Kind, codec: String, profile: String? = nil, bitDepth: Int? = nil, width: Int? = nil, height: Int? = nil,
                channels: Int? = nil, language: String? = nil, title: String? = nil, isDefault: Bool = false, dolbyVisionProfile: Int? = nil) {
        self.index = index
        self.kind = kind
        self.codec = codec
        self.profile = profile
        self.bitDepth = bitDepth
        self.width = width
        self.height = height
        self.channels = channels
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.dolbyVisionProfile = dolbyVisionProfile
    }
}

/// Which audio track of the file goes into the converted video. A player is given one at a time: a file muxed with several audio
/// tracks in one variant plays the first on most receivers, and the others cannot be chosen from the receiver.
public enum RemuxAudioChoice: Equatable, Sendable {
    /// The first track in one of these languages (tried in order), else the file's default track, else the first one that can be copied.
    case automatic(languages: [String])
    /// This track of the file (its index in the container); if it cannot be copied, the automatic choice is used.
    case track(index: Int)

    public static let standard = RemuxAudioChoice.automatic(languages: [])
}

/// What will be copied and what will be left out.
public struct RemuxPlan: Equatable, Sendable {
    public var video: RemuxStreamInfo
    /// The audio track copied as it is: none for a file without sound, otherwise exactly one.
    public var audio: [RemuxStreamInfo]
    /// Every audio track that could be copied, in the file's order (the chosen one included): what the viewer can switch to.
    public var audioChoices: [RemuxStreamInfo] = []
    /// Audio tracks left out because the system player cannot read their codec.
    public var droppedAudio: [RemuxStreamInfo]
    /// Embedded subtitle tracks (left out: the app draws its own).
    public var subtitleCount: Int

    /// Short remarks for the viewer, in Italian.
    public var notes: [String] {
        var result: [String] = []
        if !droppedAudio.isEmpty {
            let names = droppedAudio.map { track -> String in
                let name = RemuxNames.display(codec: track.codec)
                return track.language.map { "\(name) (\($0))" } ?? name
            }
            result.append("Tracce audio non incluse perché il lettore di sistema non le legge: \(names.joined(separator: ", ")).")
        }
        if audioChoices.count > 1 {
            result.append("Il file ha \(audioChoices.count) tracce audio: ne passa una alla volta, la cambi dal pannello Audio.")
        }
        if subtitleCount > 0 {
            result.append("I sottotitoli incorporati non passano in questo modo: usa quelli di Aether.")
        }
        return result
    }
}

public enum RemuxRefusal: Error, Equatable, Sendable {
    case noVideo
    case videoCodec(String)
    case videoBitDepth(codec: String, bits: Int)
    case dolbyVisionProfile5
    case noUsableAudio([String])

    /// Italian, for the viewer. Says what is wrong and what to do about it.
    public var message: String {
        switch self {
        case .noVideo:
            return "Il file non contiene una traccia video."
        case .videoCodec(let codec):
            return "Il video usa il codec \(RemuxNames.display(codec: codec)), che il lettore di sistema e i televisori non leggono. Con il motore Automatico (MPV) si vede sul telefono."
        case .videoBitDepth(let codec, let bits):
            return "Il video è \(RemuxNames.display(codec: codec)) a \(bits) bit: iOS non lo decodifica con l'hardware. Usa il motore Automatico (MPV)."
        case .dolbyVisionProfile5:
            return "Il video è Dolby Vision profilo 5: senza il lettore Dolby mostra colori sbagliati. Usa il motore Automatico (MPV)."
        case .noUsableAudio(let codecs):
            let names = codecs.map { RemuxNames.display(codec: $0) }.joined(separator: ", ")
            return "L'audio è \(names) e non può essere passato così com'è. Usa il motore Automatico (MPV), oppure scegli una sorgente con audio AAC, AC-3 o E-AC-3."
        }
    }
}

enum RemuxNames {
    static func display(codec: String) -> String {
        switch codec.lowercased() {
        case "h264": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "vp9": return "VP9"
        case "vp8": return "VP8"
        case "av1": return "AV1"
        case "mpeg2video": return "MPEG-2"
        case "mpeg4": return "MPEG-4 (Xvid/DivX)"
        case "msmpeg4v3": return "DivX 3"
        case "vc1": return "VC-1"
        case "wmv3", "wmv2", "wmv1": return "WMV"
        case "theora": return "Theora"
        case "aac": return "AAC"
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "dts": return "DTS"
        case "truehd": return "Dolby TrueHD"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case let other where other.hasPrefix("pcm"): return "PCM"
        default: return codec.uppercased()
        }
    }
}

/// Decides what can be copied into an MP4 that AVPlayer, AirPlay and Google Cast can play.
public enum RemuxPlanner {
    /// Audio codecs the system player reads inside fragmented MP4.
    public static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3"]
    public static let maxAudioTracks = 6

    public static func plan(_ streams: [RemuxStreamInfo], audio choice: RemuxAudioChoice = .standard) -> Result<RemuxPlan, RemuxRefusal> {
        let videos = streams.filter { $0.kind == .video }
        guard let video = videos.first(where: { $0.isDefault }) ?? videos.first else { return .failure(.noVideo) }

        let codec = video.codec.lowercased()
        switch codec {
        case "h264":
            if let bits = video.bitDepth, bits > 8 { return .failure(.videoBitDepth(codec: codec, bits: bits)) }
        case "hevc", "h265":
            if let bits = video.bitDepth, bits > 10 { return .failure(.videoBitDepth(codec: codec, bits: bits)) }
        default:
            return .failure(.videoCodec(codec))
        }
        if video.dolbyVisionProfile == 5 { return .failure(.dolbyVisionProfile5) }

        let audioTracks = streams.filter { $0.kind == .audio }
        var copyable: [RemuxStreamInfo] = []
        var dropped: [RemuxStreamInfo] = []
        for track in audioTracks {
            let usable = copyableAudio.contains(track.codec.lowercased()) && (track.channels ?? 2) <= 8
            if usable && copyable.count < maxAudioTracks { copyable.append(track) } else { dropped.append(track) }
        }
        if copyable.isEmpty && !audioTracks.isEmpty {
            return .failure(.noUsableAudio(Array(Set(audioTracks.map { $0.codec.lowercased() })).sorted()))
        }
        let chosen = pick(copyable, choice)
        return .success(RemuxPlan(video: video, audio: chosen.map { [$0] } ?? [], audioChoices: copyable, droppedAudio: dropped,
                                  subtitleCount: streams.filter { $0.kind == .subtitle }.count))
    }

    /// The track that goes into the converted video.
    static func pick(_ tracks: [RemuxStreamInfo], _ choice: RemuxAudioChoice) -> RemuxStreamInfo? {
        if case .track(let index) = choice, let exact = tracks.first(where: { $0.index == index }) { return exact }
        var languages: [String] = []
        if case .automatic(let wanted) = choice { languages = wanted }
        for language in languages {
            if let match = tracks.first(where: { track in track.language.map { LanguageCodes.matches($0, language) } ?? false }) { return match }
        }
        return tracks.first(where: { $0.isDefault }) ?? tracks.first
    }
}
