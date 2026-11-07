import Foundation

/// What a person did in a title.
public enum PersonRole: String, CaseIterable, Codable, Sendable {
    case actor, director, writer, producer, composer, cinematographer, other

    public var title: String {
        switch self {
        case .actor: return "Attore"
        case .director: return "Regista"
        case .writer: return "Sceneggiatore"
        case .producer: return "Produttore"
        case .composer: return "Compositore"
        case .cinematographer: return "Fotografia"
        case .other: return "Altro"
        }
    }

    /// The role a TMDB crew entry stands for (nil for jobs that are not worth a filter: casting, catering, …).
    static func role(job: String?, department: String?) -> PersonRole? {
        let job = (job ?? "").lowercased()
        switch job {
        case "director": return .director
        case "writer", "screenplay", "story", "novel", "creator", "author": return .writer
        case "producer", "executive producer": return .producer
        case "original music composer", "composer", "music": return .composer
        case "director of photography", "cinematography": return .cinematographer
        default: return nil
        }
    }
}

/// A title in a person's career, with the roles they had in it.
public struct PersonFilmographyEntry: Equatable, Identifiable, Sendable {
    public var tmdbID: Int
    public var isMovie: Bool
    public var title: String
    public var character: String?
    public var roles: [PersonRole]
    public var posterURL: String?
    public var year: Int?
    public var genres: [String]
    public var rating: Double?
    public var popularity: Double

    public var id: String { return "\(isMovie ? "movie" : "tv"):\(tmdbID)" }
    public var metaType: String { return isMovie ? "movie" : "series" }
}

public struct PersonProfile: Equatable, Sendable {
    public var name: String
    public var photoURL: String?
    public var biography: String
    public var birthday: String?
    public var deathday: String?
    public var placeOfBirth: String?
    /// "Acting", "Directing", … as TMDB names the main department, translated.
    public var profession: String?
    public var filmography: [PersonFilmographyEntry]

    public var roles: [PersonRole] {
        let present = Set(filmography.flatMap { $0.roles })
        return PersonRole.allCases.filter { present.contains($0) }
    }

    /// "12 aprile 1965 (60 anni)" — nil without a date of birth.
    public func lifeLine(calendar: Calendar = .current, now: Date = Date(), locale: Locale = Locale(identifier: "it_IT")) -> String? {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        guard let birthday = birthday, let born = parser.date(from: birthday) else { return nil }
        let shown = DateFormatter()
        shown.locale = locale
        shown.dateStyle = .long
        shown.timeStyle = .none
        shown.timeZone = TimeZone(identifier: "UTC")
        if let deathday = deathday, let died = parser.date(from: deathday) {
            let years = calendar.dateComponents([.year], from: born, to: died).year ?? 0
            return "\(shown.string(from: born)) – \(shown.string(from: died)) (\(years) anni)"
        }
        let years = calendar.dateComponents([.year], from: born, to: now).year ?? 0
        return "\(shown.string(from: born)) (\(years) anni)"
    }

    static func professionName(_ department: String?) -> String? {
        switch department {
        case "Acting": return "Attore/attrice"
        case "Directing": return "Regista"
        case "Writing": return "Sceneggiatore/trice"
        case "Production": return "Produttore/trice"
        case "Sound": return "Compositore/trice"
        case "Camera": return "Direttore/trice della fotografia"
        case .some(let other) where !other.isEmpty: return other
        default: return nil
        }
    }

    static func make(details: TMDBPersonDetails, credits: TMDBPersonCredits, fallbackName: String, hideTalkShows: Bool = true) -> PersonProfile {
        let excluded = hideTalkShows ? PersonCredit.excludedGenres.union([TalkShowFilter.tmdbGenre]) : PersonCredit.excludedGenres
        var table: [String: PersonFilmographyEntry] = [:]
        func add(_ entry: TMDBPersonCreditEntry, role: PersonRole) {
            guard let id = entry.id, let title = entry.title, !title.isEmpty, Set(entry.genreIDs).isDisjoint(with: excluded) else { return }
            let isMovie = entry.mediaType != "tv"
            let key = "\(isMovie ? "movie" : "tv"):\(id)"
            let year = entry.releaseDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }
            var current = table[key] ?? PersonFilmographyEntry(tmdbID: id, isMovie: isMovie, title: title, character: nil, roles: [],
                                                               posterURL: PersonCredit.posterURL(entry.posterPath), year: year,
                                                               genres: entry.genreIDs.compactMap { TMDBGenreNames.italian[$0] }, rating: entry.voteAverage.flatMap { $0 > 0 ? $0 : nil },
                                                               popularity: entry.popularity ?? 0)
            if !current.roles.contains(role) { current.roles.append(role) }
            if role == .actor, let character = entry.character?.trimmingCharacters(in: .whitespacesAndNewlines), !character.isEmpty { current.character = character }
            table[key] = current
        }
        for entry in credits.cast {
            // Actors with no role or poster are the "as himself" appearances (news, awards nights).
            guard entry.posterPath != nil, let role = entry.character?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty else { continue }
            add(entry, role: .actor)
        }
        for entry in credits.crew where entry.posterPath != nil {
            if let role = PersonRole.role(job: entry.job, department: entry.department) { add(entry, role: role) }
        }
        let sorted = table.values.sorted { $0.popularity != $1.popularity ? $0.popularity > $1.popularity : $0.title < $1.title }
        return PersonProfile(name: details.name ?? fallbackName, photoURL: details.profilePath.flatMap { $0.hasPrefix("/") && !$0.contains("..") ? "https://image.tmdb.org/t/p/w500" + $0 : nil },
                             biography: (details.biography ?? "").trimmingCharacters(in: .whitespacesAndNewlines), birthday: details.birthday.flatMap { $0.isEmpty ? nil : $0 },
                             deathday: details.deathday.flatMap { $0.isEmpty ? nil : $0 }, placeOfBirth: details.placeOfBirth.flatMap { $0.isEmpty ? nil : $0 },
                             profession: professionName(details.knownFor), filmography: Array(sorted.prefix(400)))
    }
}

/// How the filmography is cut.
public struct PersonFilter: Equatable, Sendable {
    public var role: PersonRole?
    public var genre: String?
    public var onlyMovies: Bool?
    public var fromYear: Int?
    public var toYear: Int?
    public init(role: PersonRole? = nil, genre: String? = nil, onlyMovies: Bool? = nil, fromYear: Int? = nil, toYear: Int? = nil) {
        self.role = role
        self.genre = genre
        self.onlyMovies = onlyMovies
        self.fromYear = fromYear
        self.toYear = toYear
    }

    public func apply(_ entries: [PersonFilmographyEntry]) -> [PersonFilmographyEntry] {
        return entries.filter { entry in
            if let role = role, !entry.roles.contains(role) { return false }
            if let genre = genre, !entry.genres.contains(genre) { return false }
            if let onlyMovies = onlyMovies, entry.isMovie != onlyMovies { return false }
            if let from = fromYear, (entry.year ?? 0) < from { return false }
            if let to = toYear, (entry.year ?? 9999) > to { return false }
            return true
        }
    }

    public static func genres(in entries: [PersonFilmographyEntry]) -> [String] {
        return Array(Set(entries.flatMap { $0.genres })).sorted()
    }
}

/// TMDB's genre ids (movies and series) in Italian.
enum TMDBGenreNames {
    static let italian: [Int: String] = [28: "Azione", 12: "Avventura", 16: "Animazione", 35: "Commedia", 80: "Crime", 99: "Documentario", 18: "Dramma", 10751: "Famiglia",
        14: "Fantasy", 36: "Storia", 27: "Horror", 10402: "Musica", 9648: "Mistero", 10749: "Romantico", 878: "Fantascienza", 53: "Thriller", 10752: "Guerra", 37: "Western",
        10759: "Azione e avventura", 10765: "Fantascienza e fantasy", 10768: "Guerra e politica", 10762: "Bambini"]
}
