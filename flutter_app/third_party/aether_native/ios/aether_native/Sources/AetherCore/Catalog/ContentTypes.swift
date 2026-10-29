import Foundation

/// Presentation data for one content type id (Italian title, SF Symbol, position in the canonical order).
///
/// `id` is always the string exactly as the caller passed it: addons are queried with their own spelling
/// (`catalog/<type>/<id>.json`), so a type id is never rewritten, only looked up case-insensitively.
public struct ContentTypeInfo: Hashable, Identifiable, Sendable {
    public var id: String
    /// Short Italian name shown on chips and headers.
    public var title: String
    /// SF Symbol name, valid on iOS 17+.
    public var symbolName: String
    /// Position in `ContentTypes.canonicalOrder`; unknown types share the rank after the last known one.
    public var rank: Int
    /// False for types this app has no dedicated name for. Unknown types are still listed, never hidden.
    public var isKnown: Bool

    public init(id: String, title: String, symbolName: String, rank: Int, isKnown: Bool) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.rank = rank
        self.isKnown = isKnown
    }
}

/// Friendly names, icons and ordering for the content types addons declare.
///
/// Stremio lets addons invent types, so everything here degrades gracefully: an unknown id gets a capitalised
/// title, a generic icon and a place after the known types.
public enum ContentTypes {
    private struct Entry {
        var ids: [String]
        var title: String
        var symbol: String
    }

    /// Symbol used for types without a dedicated one.
    public static let genericSymbolName = "square.grid.2x2"

    private static let entries: [Entry] = [
        Entry(ids: [ContentType.movie], title: "Film", symbol: "film"),
        Entry(ids: [ContentType.series], title: "Serie TV", symbol: "tv"),
        Entry(ids: [ContentType.anime], title: "Anime", symbol: "sparkles"),
        Entry(ids: [ContentType.tv], title: "TV in diretta", symbol: "antenna.radiowaves.left.and.right"),
        Entry(ids: [ContentType.channel], title: "Canali", symbol: "play.rectangle"),
        Entry(ids: ["sports", "sport"], title: "Sport", symbol: "sportscourt"),
        Entry(ids: ["events", "event"], title: "Eventi", symbol: "calendar"),
        Entry(ids: ["music"], title: "Musica", symbol: "music.note"),
        Entry(ids: ["radio"], title: "Radio", symbol: "radio"),
        Entry(ids: ["podcast"], title: "Podcast", symbol: "mic"),
        Entry(ids: [ContentType.other], title: "Altro", symbol: ContentTypes.genericSymbolName)
    ]

    /// Canonical order of the well known types, one id per position (`sport`/`event` are accepted aliases).
    /// Derived from the table above, so the two can never disagree.
    public static let canonicalOrder: [String] = ContentTypes.entries.map { (entry: Entry) -> String in
        return entry.ids[0]
    }

    private static let indexByID: [String: Int] = {
        var map: [String: Int] = [:]
        for (index, entry) in ContentTypes.entries.enumerated() {
            for id in entry.ids {
                map[id] = index
            }
        }
        return map
    }()

    /// Trimmed, lower-cased form used for lookups and as a sort key.
    public static func lookupKey(_ raw: String) -> String {
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Stable identity of a type, independent of spelling: trimmed, lower-cased, and aliases folded onto the
    /// canonical id ("Sport" and "sports" both give "sports"; a blank id gives "other").
    /// Use it for anything that is persisted or compared across addons; keep the original spelling for requests.
    public static func canonicalID(_ raw: String) -> String {
        let key = lookupKey(raw)
        if key.isEmpty { return ContentType.other }
        if let index = indexByID[key] { return entries[index].ids[0] }
        return key
    }

    /// Everything the UI needs to present `id`. Never fails: unknown ids get a capitalised title.
    public static func info(for id: String) -> ContentTypeInfo {
        let key = lookupKey(id)
        // A blank id cannot be queried meaningfully; show it with the catch-all "Altro".
        let effectiveKey = key.isEmpty ? ContentType.other : key
        if let index = indexByID[effectiveKey] {
            let entry = entries[index]
            return ContentTypeInfo(id: id, title: entry.title, symbolName: entry.symbol, rank: index, isKnown: true)
        }
        return ContentTypeInfo(id: id, title: capitalised(id), symbolName: genericSymbolName,
                               rank: entries.count, isKnown: false)
    }

    public static func title(for id: String) -> String {
        return info(for: id).title
    }

    public static func symbolName(for id: String) -> String {
        return info(for: id).symbolName
    }

    public static func rank(of id: String) -> Int {
        return info(for: id).rank
    }

    public static func isKnown(_ id: String) -> Bool {
        return info(for: id).isKnown
    }

    /// Orders type ids: known types in canonical order, then unknown types alphabetically (case-insensitive).
    /// The comparison is total, so the result does not depend on the input order.
    public static func sorted(_ ids: [String]) -> [String] {
        return ids.sorted { (lhs: String, rhs: String) -> Bool in
            let lhsRank = ContentTypes.rank(of: lhs)
            let rhsRank = ContentTypes.rank(of: rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsKey = ContentTypes.lookupKey(lhs)
            let rhsKey = ContentTypes.lookupKey(rhs)
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs < rhs
        }
    }

    /// First letter upper-cased, the rest untouched (same rule as `RequestPlanner.friendlyTypeName`).
    private static func capitalised(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        return String(first).uppercased() + String(trimmed.dropFirst())
    }
}
