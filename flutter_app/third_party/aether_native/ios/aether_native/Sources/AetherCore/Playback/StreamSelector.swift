import Foundation

/// A stream with its analysis, ready to be ranked / displayed.
public struct RankedStream: Identifiable, Sendable {
    public var stream: AddonStream
    public var info: StreamInfo
    public var score: Int

    public var id: String { return stream.id }
}

/// How the list of sources is ordered.
public enum StreamOrdering: String, Codable, CaseIterable, Sendable {
    /// The addon list decides: every source of the first addon comes before every source of the second, and so on. Inside one
    /// addon the sources keep Aether's own ranking (language, quality, codec…).
    case byAddon
    /// One ranking for all sources, whatever addon they come from. The order of the addons only breaks ties.
    case best
}

public struct StreamPreferences: Sendable, Equatable {
    public var qualityCap: VideoQualityCap
    /// Language code, or nil for no preference.
    public var preferredLanguage: String?
    public var preferLanguage: Bool
    /// Addon ids in user order. With `.byAddon` ordering this is the main sort key; with `.best` earlier addons only win ties.
    public var addonOrder: [String]
    public var ordering: StreamOrdering
    public var streamingServer: URL?
    /// Engines present in this build: decides whether MKV & co. count as playable.
    public var capabilities: PlaybackCapabilities

    public init(qualityCap: VideoQualityCap = .auto, preferredLanguage: String? = nil, preferLanguage: Bool = true,
                addonOrder: [String] = [], ordering: StreamOrdering = .best, streamingServer: URL? = nil,
                capabilities: PlaybackCapabilities = .avPlayerOnly) {
        self.qualityCap = qualityCap
        self.preferredLanguage = preferredLanguage
        self.preferLanguage = preferLanguage
        self.addonOrder = addonOrder
        self.ordering = ordering
        self.streamingServer = streamingServer
        self.capabilities = capabilities
    }
}

public enum StreamSelector {
    /// Orders streams. With `.best`: playable first, then language, quality (within the cap), codec friendliness, addon order.
    /// With `.byAddon`: the addon's place in the user's list first, then the same ranking inside each addon.
    /// Unplayable streams are kept (at the bottom) so the user can see *why* they cannot be played.
    public static func rank(_ streams: [AddonStream], preferences: StreamPreferences) -> [RankedStream] {
        var ranked: [(item: RankedStream, addonPlace: Int)] = []
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
            // A source from an addon that is not in the list (or from none) goes after all the listed ones.
            let place = stream.addonID.flatMap { preferences.addonOrder.firstIndex(of: $0) } ?? Int.max
            ranked.append((RankedStream(stream: stream, info: info, score: score), place))
        }
        switch preferences.ordering {
        case .best:
            return ranked.map { $0.item }.sorted { $0.score > $1.score }
        case .byAddon:
            // Sources that cannot be played stay below all the others, whatever their addon.
            return ranked.sorted { lhs, rhs in
                let leftPlayable = lhs.item.info.support.isPlayable
                if leftPlayable != rhs.item.info.support.isPlayable { return leftPlayable }
                if lhs.addonPlace != rhs.addonPlace { return lhs.addonPlace < rhs.addonPlace }
                return lhs.item.score > rhs.item.score
            }.map { $0.item }
        }
    }

    /// Picks what to play automatically.
    /// 1. A stream sharing the previous episode's `bingeGroup` (continuity of release / quality / addon).
    /// 2. Otherwise the best-ranked playable stream.
    ///
    /// With `.byAddon` the choice stays inside the first addon that has something playable, as the list does: the continuity match
    /// is looked for among that addon's sources only, so a lower addon never wins over the one the user put on top.
    public static func autoSelect(_ ranked: [RankedStream], previousBingeGroup: String? = nil,
                                  ordering: StreamOrdering = .best) -> RankedStream? {
        var playable = ranked.filter { $0.info.support.isPlayable }
        if ordering == .byAddon, let first = playable.first {
            playable = playable.filter { $0.stream.addonID == first.stream.addonID }
        }
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
