import Foundation

/// Extra episode details fetched on demand from TMDB. IMDb identifiers are included when TMDB knows them;
/// the score is explicitly TMDB's vote average, not an IMDb rating.
public struct EpisodeRichDetails: Equatable, Sendable {
    public var title: String?
    public var overview: String?
    public var tmdbRating: Double?
    public var imdbID: String?
    public var season: Int
    public var episode: Int

    public init(title: String?, overview: String?, tmdbRating: Double?, imdbID: String?, season: Int, episode: Int) {
        self.title = title
        self.overview = overview
        self.tmdbRating = tmdbRating
        self.imdbID = imdbID
        self.season = season
        self.episode = episode
    }
}
