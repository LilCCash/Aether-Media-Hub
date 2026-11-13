import Foundation

/// The quick filters of the source list (quality, HDR, audio language), applied on top of the addon filter and the search.
/// Every filter only narrows the list; with none chosen the list is untouched.
public struct StreamQuickFilter: Equatable, Sendable {
    public var quality: StreamQuality?
    public var hdrOnly: Bool
    public var language: String?

    public init(quality: StreamQuality? = nil, hdrOnly: Bool = false, language: String? = nil) {
        self.quality = quality
        self.hdrOnly = hdrOnly
        self.language = language
    }

    public var isActive: Bool { quality != nil || hdrOnly || language != nil }

    public func matches(_ info: StreamInfo) -> Bool {
        if let quality = quality, info.quality != quality { return false }
        if hdrOnly && info.hdr.isEmpty { return false }
        if let language = language, !info.languages.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
            return false
        }
        return true
    }

    public func apply(_ list: [RankedStream]) -> [RankedStream] {
        guard isActive else { return list }
        return list.filter { matches($0.info) }
    }

    /// The qualities present in `list`, best first (unknown left out: it cannot be chosen meaningfully).
    public static func qualities(in list: [RankedStream]) -> [StreamQuality] {
        return Array(Set(list.map(\.info.quality)).subtracting([.unknown])).sorted(by: >)
    }

    /// The audio languages present in `list`, the most frequent first (ties alphabetical), at most `limit`.
    public static func languages(in list: [RankedStream], limit: Int = 6) -> [String] {
        var counts: [String: (label: String, count: Int)] = [:]
        for item in list {
            for language in Set(item.info.languages.map { $0.uppercased() }) where !language.isEmpty {
                counts[language, default: (language, 0)].count += 1
            }
        }
        return counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
            .prefix(max(0, limit))
            .map(\.label)
    }

    public static func hasHDR(in list: [RankedStream]) -> Bool { list.contains { !$0.info.hdr.isEmpty } }
}
