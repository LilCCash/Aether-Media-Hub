import Foundation

/// A film or series a person appeared in, with the character they played.
public struct PersonCredit: Equatable, Sendable, Identifiable {
    public var tmdbID: Int
    public var isMovie: Bool
    public var title: String
    /// The character, as TMDB names it.
    public var character: String?
    public var posterURL: String?
    public var year: String?

    public var id: String { return "\(isMovie ? "movie" : "tv"):\(tmdbID)" }

    /// The catalog type of the title ("movie" or "series").
    public var metaType: String { return isMovie ? "movie" : "series" }

    /// Talk shows, news and reality programmes list people "as themselves": they are left out, like entries without a poster or a role.
    static let excludedGenres: Set<Int> = [10767, 10763, 10764]

    static func make(from credits: TMDBPersonCredits, limit: Int = 80) -> [PersonCredit] {
        let usable = credits.cast.filter { entry in
            guard entry.id != nil, let title = entry.title, !title.isEmpty, entry.posterPath != nil else { return false }
            guard let role = entry.character?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty else { return false }
            return Set(entry.genreIDs).isDisjoint(with: excludedGenres)
        }
        let ordered = usable.sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
        var seen = Set<String>()
        var result: [PersonCredit] = []
        for entry in ordered {
            guard let id = entry.id, let title = entry.title else { continue }
            let isMovie = entry.mediaType != "tv"
            let credit = PersonCredit(tmdbID: id, isMovie: isMovie, title: title,
                                      character: entry.character?.trimmingCharacters(in: .whitespacesAndNewlines),
                                      posterURL: PersonCredit.posterURL(entry.posterPath),
                                      year: entry.releaseDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil })
            guard seen.insert(credit.id).inserted else { continue }
            result.append(credit)
            if result.count >= limit { break }
        }
        return result
    }

    static func posterURL(_ path: String?) -> String? {
        guard let path = path, path.hasPrefix("/"), !path.contains("..") else { return nil }
        return "https://image.tmdb.org/t/p/w342" + path
    }
}
