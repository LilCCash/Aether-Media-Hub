import Foundation

/// How the viewer wants sources ranked, beyond the basics (playable, language, quality cap). Each criterion has a weight from 0
/// (ignored) to 3 (counts a lot). HDR and audio come from the release *name*: they are labels, not measurements.
public struct SourceScoring: Codable, Equatable, Sendable {
    public enum SizePreference: String, Codable, CaseIterable, Sendable {
        case none, smaller, larger
        public var title: String {
            switch self {
            case .none: return "Indifferente"
            case .smaller: return "File più piccoli"
            case .larger: return "File più grandi (qualità)"
            }
        }
    }
    public enum CodecPreference: String, Codable, CaseIterable, Sendable {
        case any, hevc, h264
        public var title: String {
            switch self {
            case .any: return "Qualsiasi"
            case .hevc: return "HEVC (file più leggeri)"
            case .h264: return "H.264 (massima compatibilità)"
            }
        }
    }

    public var video: Int = 0
    public var hdr: Int = 0
    public var audio: Int = 0
    public var size: SizePreference = .none
    public var sizeWeight: Int = 1
    public var codec: CodecPreference = .any
    public var codecWeight: Int = 1

    public init() {}

    private enum CodingKeys: String, CodingKey { case video, hdr, audio, size, sizeWeight, codec, codecWeight }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func weight(_ key: CodingKeys) -> Int { return min(3, max(0, (try? c.decode(Int.self, forKey: key)) ?? 0)) }
        video = weight(.video)
        hdr = weight(.hdr)
        audio = weight(.audio)
        sizeWeight = max(1, weight(.sizeWeight))
        codecWeight = max(1, weight(.codecWeight))
        size = (try? c.decode(SizePreference.self, forKey: .size)) ?? .none
        codec = (try? c.decode(CodecPreference.self, forKey: .codec)) ?? .any
    }

    public var isNeutral: Bool { return video == 0 && hdr == 0 && audio == 0 && size == .none && codec == .any }

    /// The points a source earns (or loses) for these criteria. Zero when the criteria are neutral, so that the default ranking is untouched.
    public func bonus(for info: StreamInfo) -> Int {
        guard info.support.isPlayable else { return 0 }
        var points = 0
        if video > 0 { points += video * info.quality.height / 20 }
        if hdr > 0 {
            let best = info.hdr.map { format -> Int in
                switch format {
                case .dolbyVision: return 300
                case .hdr10Plus: return 250
                case .hdr10: return 200
                case .hlg: return 100
                }
            }.max() ?? 0
            points += hdr * best / 2
        }
        if audio > 0 {
            let best = info.audio.map { codec -> Int in
                switch codec {
                case .atmos, .truehd: return 200
                case .dts: return 150
                case .eac3: return 100
                case .ac3: return 60
                case .flac: return 120
                default: return 20
                }
            }.max() ?? 0
            points += audio * best / 2
        }
        if size != .none, let bytes = info.sizeBytes, bytes > 0 {
            let gb = min(40, Double(bytes) / 1_073_741_824)
            points += Int(gb * 10 * Double(sizeWeight)) * (size == .larger ? 1 : -1)
        }
        switch codec {
        case .any: break
        case .hevc: if info.codec == .hevc { points += 150 * codecWeight }
        case .h264: if info.codec == .h264 { points += 150 * codecWeight }
        }
        return points
    }
}
