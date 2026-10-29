import Foundation

/// Identifiers of the same title in the other catalogues. Cinemeta-style metas carry them as `imdb_id`, `moviedb_id`
/// (the TMDB id) and `tvdb_id`; a Stremio id that starts with `tt` is an IMDb id by definition.
public struct ExternalIDs: Codable, Hashable, Sendable {
    public var imdb: String?
    public var tmdb: Int?
    public var tvdb: Int?

    public init(imdb: String? = nil, tmdb: Int? = nil, tvdb: Int? = nil) {
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    public var isEmpty: Bool { return imdb == nil && tmdb == nil && tvdb == nil }

    /// "tt0944947:1:2" -> "tt0944947"; nil for ids that are not IMDb ids ("kitsu:1", "tmdb:603", "yt_id:…").
    public static func imdbID(fromMetaID id: String) -> String? {
        let head = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? id
        guard head.hasPrefix("tt"), head.count > 2, head.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return head
    }

    /// What the Stremio id itself says: "tt0944947:1:2" is an IMDb id, "tmdb:603" a TMDB id and "tvdb:121361:1:2" a TheTVDB id
    /// (ids used by catalog addons that are not built on IMDb). Anything else says nothing.
    public static func fromMetaID(_ id: String) -> ExternalIDs {
        if let imdb = imdbID(fromMetaID: id) { return ExternalIDs(imdb: imdb) }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let number = Int(parts[1]), number > 0 else { return ExternalIDs() }
        switch parts[0].lowercased() {
        case "tmdb": return ExternalIDs(tmdb: number)
        case "tvdb": return ExternalIDs(tvdb: number)
        default: return ExternalIDs()
        }
    }

    /// Keeps what is already known and fills the gaps from `other`.
    public func filling(from other: ExternalIDs) -> ExternalIDs {
        return ExternalIDs(imdb: imdb ?? other.imdb, tmdb: tmdb ?? other.tmdb, tvdb: tvdb ?? other.tvdb)
    }
}
