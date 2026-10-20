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

    /// Keeps what is already known and fills the gaps from `other`.
    public func filling(from other: ExternalIDs) -> ExternalIDs {
        return ExternalIDs(imdb: imdb ?? other.imdb, tmdb: tmdb ?? other.tmdb, tvdb: tvdb ?? other.tvdb)
    }
}
