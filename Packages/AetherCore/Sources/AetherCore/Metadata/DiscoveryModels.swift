import Foundation

/// Every picture TMDB has for a title, as full addresses (the biggest size). Empty lists when TMDB is not set up.
public struct TitleArtwork: Sendable, Equatable {
    public var posters: [String] = []
    public var backdrops: [String] = []
    public var logos: [String] = []
    public init(posters: [String] = [], backdrops: [String] = [], logos: [String] = []) {
        self.posters = posters; self.backdrops = backdrops; self.logos = logos
    }
    public var isEmpty: Bool { return posters.isEmpty && backdrops.isEmpty && logos.isEmpty }
}

/// A title from TMDB shown outside a catalog: the release calendar and the full-screen discovery.
public struct DiscoveryCard: Sendable, Identifiable, Hashable {
    public var tmdbID: Int
    /// "movie" or "series", as the catalogs call them.
    public var type: String
    public var title: String
    public var overview: String
    public var posterURL: String?
    public var backdropURL: String?
    public var date: Date?
    public var rating: Double?
    public var genreIDs: [Int]
    public var id: String { return "\(type):\(tmdbID)" }

    public init(tmdbID: Int, type: String, title: String, overview: String = "", posterURL: String? = nil, backdropURL: String? = nil,
                date: Date? = nil, rating: Double? = nil, genreIDs: [Int] = []) {
        self.tmdbID = tmdbID; self.type = type; self.title = title; self.overview = overview; self.posterURL = posterURL
        self.backdropURL = backdropURL; self.date = date; self.rating = rating; self.genreIDs = genreIDs
    }

    public var year: String? {
        guard let date = date else { return nil }
        return String(Calendar(identifier: .gregorian).component(.year, from: date))
    }
}

public enum DiscoveryDates {
    public static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func parse(_ text: String?) -> Date? {
        guard let text = text, text.count >= 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }
}
