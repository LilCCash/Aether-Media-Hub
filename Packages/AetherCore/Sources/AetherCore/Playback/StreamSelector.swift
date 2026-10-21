import Foundation

/// A stream with its analysis, ready to be ranked / displayed.
public struct RankedStream: Identifiable, Sendable {
    public var stream: AddonStream
    public var info: StreamInfo
    public var score: Int

    public var id: String { return stream.id }
}

public struct StreamPreferences: Sendable, Equatable {
    public var qualityCap: VideoQualityCap
    /// Language code, or nil for no preference.
    public var preferredLanguage: String?
    public var preferLanguage: Bool
    /// Addon ids in user order: earlier addons are mildly preferred on ties.
    public var addonOrder: [String]
    public var streamingServer: URL?
    /// Engines present in this build: decides whether MKV & co. count as playable.
    public var capabilities: PlaybackCapabilities

    public init(qualityCap: VideoQualityCap = .auto, preferredLanguage: String? = nil, preferLanguage: Bool = true,
                addonOrder: [String] = [], streamingServer: URL? = nil, capabilities: PlaybackCapabilities = .avPlayerOnly) {
        self.qualityCap = qualityCap
        self.preferredLanguage = preferredLanguage
        self.preferLanguage = preferLanguage
        self.addonOrder = addonOrder
        self.streamingServer = streamingServer
        self.capabilities = capabilities
    }
}

public enum StreamSelector {
    /// Orders streams: playable first, then language, quality (within the cap), codec friendliness, addon order.
    /// Unplayable streams are kept (at the bottom) so the user can see *why* they cannot be played.
    public static func rank(_ streams: [AddonStream], preferences: StreamPreferences) -> [RankedStream] {
        var ranked: [RankedStream] = []
        for (position, stream) in streams.enumerated() {
            let info = StreamAnalyzer.analyze(stream, streamingServer: preferences.streamingServer, capabilities: preferences.capabilities)
            var score = 0
            switch info.support {
            case .supported: score += 10_000
            case .unknown: score += 5_000
            case .unsupported: score += 0
            }
            if info.support.isPlayable {
                let height = info.quality.height
                if height > 0 {
                    if height <= preferences.qualityCap.maxHeight {
                        score += height / 10 + 100
                    } else {
                        // Above the cap: still playable but ranks below everything within the cap.
                        score -= 2_000 - min(1_900, height / 2)
                    }
                }
                if let language = preferences.preferredLanguage, preferences.preferLanguage {
                    if info.languages.contains(language) { score += 800 }
                    else if info.languages.contains("multi") { score += 500 }
                }
                if info.codec == .h264 { score += 30 }
                if info.codec == .hevc { score += 20 }
                if info.codec == .av1 { score -= 40 }
                if info.codec == .xvid || info.codec == .mpeg2 { score -= 60 }
                if info.kind == .hls { score += 15 }
                if !info.warnings.isEmpty { score -= 25 }
                if info.needsHeaders { score -= 10 }
            }
            if let addonID = stream.addonID, let order = preferences.addonOrder.firstIndex(of: addonID) {
                score += max(0, 8 - order)
            }
            // Stable tiebreak: original position.
            score = score * 1000 - position
            ranked.append(RankedStream(stream: stream, info: info, score: score))
        }
        return ranked.sorted { $0.score > $1.score }
    }

    /// Picks what to play automatically.
    /// 1. A stream sharing the previous episode's `bingeGroup` (continuity of release / quality / addon).
    /// 2. Otherwise the best-ranked playable stream.
    public static func autoSelect(_ ranked: [RankedStream], previousBingeGroup: String? = nil) -> RankedStream? {
        let playable = ranked.filter { $0.info.support.isPlayable }
        if let group = previousBingeGroup, !group.isEmpty,
           let match = playable.first(where: { $0.stream.behaviorHints.bingeGroup == group }) {
            return match
        }
        return playable.first
    }

    /// Language code from the user setting; `system` resolves to the first preferred locale language.
    public static func resolveLanguage(_ setting: String, systemLanguage: String?) -> String? {
        switch setting {
        case "off": return nil
        case "system": return systemLanguage
        default: return setting
        }
    }
}
