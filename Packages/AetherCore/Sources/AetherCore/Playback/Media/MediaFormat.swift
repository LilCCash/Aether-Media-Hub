import Foundation

// Facts about a media file as reported by a decoder / demuxer, never as guessed from a file name.
// Everything here is pure data plus parsers for the binary records a container carries, so it is unit-testable.

/// Dolby Vision decoder configuration (ISO-BMFF `dvcC` / `dvvC` box payload, "DOVIDecoderConfigurationRecord").
public struct DolbyVisionInfo: Equatable, Hashable, Codable, Sendable {
    public var profile: Int
    public var level: Int
    public var hasRPU: Bool
    public var hasEnhancementLayer: Bool
    public var hasBaseLayer: Bool
    /// `dv_bl_signal_compatibility_id`: 0 none (profile 5), 1 HDR10, 2 SDR, 4 HLG, 6 Blu-ray HDR10 (profile 7).
    public var baseLayerCompatibility: Int

    public init(profile: Int, level: Int, hasRPU: Bool = true, hasEnhancementLayer: Bool = false,
                hasBaseLayer: Bool = true, baseLayerCompatibility: Int = 0) {
        self.profile = profile
        self.level = level
        self.hasRPU = hasRPU
        self.hasEnhancementLayer = hasEnhancementLayer
        self.hasBaseLayer = hasBaseLayer
        self.baseLayerCompatibility = baseLayerCompatibility
    }

    /// Parses the first 5 bytes of the record (version, profile, level, flags, compatibility id).
    /// Returns nil for records that are too short or have an unknown major version.
    public static func parse(configurationRecord data: Data) -> DolbyVisionInfo? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, bytes[0] == 1 else { return nil }
        let profile = Int(bytes[2] >> 1)
        let level = (Int(bytes[2] & 0x01) << 5) | Int(bytes[3] >> 3)
        let rpu = (bytes[3] >> 2) & 0x01 == 1
        let enhancement = (bytes[3] >> 1) & 0x01 == 1
        let base = bytes[3] & 0x01 == 1
        let compatibility = Int(bytes[4] >> 4)
        guard profile > 0 else { return nil }
        return DolbyVisionInfo(profile: profile, level: level, hasRPU: rpu, hasEnhancementLayer: enhancement,
                               hasBaseLayer: base, baseLayerCompatibility: compatibility)
    }

    /// Profile 0 stands for "the sample entry is tagged Dolby Vision but its configuration record could not be read".
    /// "5", "7", "8.1", "8.2", "8.4": the way the profiles are written in Dolby's documentation.
    public var profileLabel: String {
        if profile == 0 { return "?" }
        if profile == 8, [1, 2, 4].contains(baseLayerCompatibility) { return "8.\(baseLayerCompatibility)" }
        return "\(profile)"
    }

    /// What a player that ignores the Dolby metadata would show (the "base layer").
    public var baseLayerRange: DynamicRange {
        switch baseLayerCompatibility {
        case 1, 6: return .hdr10
        case 2: return .sdr
        case 4: return .hlg
        default: return .unknown
        }
    }
}

/// HEVC decoder configuration (`hvcC` box payload): only the fields that matter for compatibility checks.
public struct HEVCConfig: Equatable, Sendable {
    public var profileIDC: Int
    public var bitDepth: Int
    public var levelIDC: Int

    public static func parse(configurationRecord data: Data) -> HEVCConfig? {
        let bytes = [UInt8](data)
        guard bytes.count >= 19, bytes[0] == 1 else { return nil }
        return HEVCConfig(profileIDC: Int(bytes[1] & 0x1F), bitDepth: Int(bytes[17] & 0x07) + 8, levelIDC: Int(bytes[12]))
    }
}

/// The dynamic range a stream is *signalled* to have. `unknown` is a legitimate answer: not signalled, not measured.
public enum DynamicRange: String, Codable, Equatable, Sendable {
    case sdr, hdr10, hlg, unknown

    public var label: String {
        switch self {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .unknown: return "Non rilevato"
        }
    }

    /// Classifies colour signalling. Accepts the CoreMedia constant values (`SMPTE_ST_2084_PQ`, `ITU_R_2100_HLG`,
    /// `ITU_R_2020`, …) and the names mpv reports (`pq`, `hlg`, `bt.2020`, …).
    public static func classify(primaries: String?, transfer: String?) -> DynamicRange {
        let transferKey = (transfer ?? "").lowercased()
        let primariesKey = (primaries ?? "").lowercased()
        if transferKey.isEmpty && primariesKey.isEmpty { return .unknown }
        if transferKey.contains("2084") || transferKey == "pq" || transferKey.contains("st2084") { return .hdr10 }
        if transferKey.contains("hlg") || transferKey.contains("2100") || transferKey.contains("arib") { return .hlg }
        if transferKey.isEmpty { return .unknown }
        return .sdr
    }
}

public struct VideoTrackFacts: Equatable, Sendable {
    /// Four-character code of the sample entry (`avc1`, `hvc1`, `hev1`, `dvh1`, `av01`, …) or a decoder name.
    public var codecTag: String?
    public var codecName: String?
    public var width: Int
    public var height: Int
    public var frameRate: Double?
    public var bitDepth: Int?
    public var primaries: String?
    public var transfer: String?
    public var matrix: String?
    public var range: DynamicRange
    public var dolbyVision: DolbyVisionInfo?
    /// AVFoundation's own HDR flag (`containsHDRVideo`); nil when the source of facts is not AVFoundation.
    public var flaggedHDRByPlatform: Bool?
    /// AVFoundation's decodability verdict for the track on THIS device (`AVAssetTrack.isDecodable`).
    public var isDecodable: Bool?
    /// Peak luminance reported by the decoder in nits, when available.
    public var peakNits: Double?

    public init(codecTag: String? = nil, codecName: String? = nil, width: Int = 0, height: Int = 0, frameRate: Double? = nil,
                bitDepth: Int? = nil, primaries: String? = nil, transfer: String? = nil, matrix: String? = nil,
                range: DynamicRange = .unknown, dolbyVision: DolbyVisionInfo? = nil, flaggedHDRByPlatform: Bool? = nil,
                isDecodable: Bool? = nil, peakNits: Double? = nil) {
        self.codecTag = codecTag
        self.codecName = codecName
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
        self.dolbyVision = dolbyVision
        self.flaggedHDRByPlatform = flaggedHDRByPlatform
        self.isDecodable = isDecodable
        self.peakNits = peakNits
    }

    /// Short badge text built only from facts: "Dolby Vision 8.1", "HDR10", "HLG", "SDR" or nil when nothing is known.
    public var verifiedHDRLabel: String? {
        if let dv = dolbyVision { return "Dolby Vision \(dv.profileLabel)" }
        switch range {
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .sdr: return "SDR"
        case .unknown:
            return flaggedHDRByPlatform == true ? "HDR" : nil
        }
    }

    public var isHEVCFamily: Bool {
        guard let tag = codecTag?.lowercased() else { return (codecName ?? "").lowercased().contains("hevc") }
        return ["hvc1", "hev1", "dvh1", "dvhe"].contains(tag)
    }

    public var isHDROrDolbyVision: Bool {
        if dolbyVision != nil { return true }
        if range == .hdr10 || range == .hlg { return true }
        return flaggedHDRByPlatform == true
    }
}

public struct AudioTrackFacts: Equatable, Sendable {
    public var codecTag: String?
    public var codecName: String?
    public var channels: Int?
    public var language: String?
    public var title: String?

    public init(codecTag: String? = nil, codecName: String? = nil, channels: Int? = nil, language: String? = nil, title: String? = nil) {
        self.codecTag = codecTag
        self.codecName = codecName
        self.channels = channels
        self.language = language
        self.title = title
    }
}

/// Verdict of the platform decoder about a file, before playing it.
public enum PlatformPlayability: String, Codable, Equatable, Sendable {
    case playable, notPlayable, unknown
}

public struct MediaFormatInfo: Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case avFoundation, mpv }

    public var source: Source
    public var container: String?
    public var duration: Double?
    public var video: [VideoTrackFacts]
    public var audio: [AudioTrackFacts]
    public var subtitleTrackCount: Int
    public var platformPlayability: PlatformPlayability
    /// Name of the decoder path in use when the engine reports it (for example "videotoolbox"), nil when unknown.
    public var hardwareDecoder: String?
    /// True when the engine confirms that a video output is configured and showing pictures.
    public var videoOutputActive: Bool?

    public init(source: Source, container: String? = nil, duration: Double? = nil, video: [VideoTrackFacts] = [],
                audio: [AudioTrackFacts] = [], subtitleTrackCount: Int = 0,
                platformPlayability: PlatformPlayability = .unknown, hardwareDecoder: String? = nil,
                videoOutputActive: Bool? = nil) {
        self.source = source
        self.container = container
        self.duration = duration
        self.video = video
        self.audio = audio
        self.subtitleTrackCount = subtitleTrackCount
        self.platformPlayability = platformPlayability
        self.hardwareDecoder = hardwareDecoder
        self.videoOutputActive = videoOutputActive
    }

    public var primaryVideo: VideoTrackFacts? { video.first }
}
