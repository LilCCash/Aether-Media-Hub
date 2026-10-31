import Foundation

/// Generi comuni a film e serie, con il codice TMDB di ciascun tipo (nil = non esiste per quel tipo).
public enum IntentGenre: String, Codable, CaseIterable, Sendable {
    case action, adventure, animation, comedy, crime, documentary, drama, family, fantasy, history, horror, music
    case mystery, romance, scifi, thriller, war, western

    public var movieID: Int? {
        switch self {
        case .action: return 28
        case .adventure: return 12
        case .animation: return 16
        case .comedy: return 35
        case .crime: return 80
        case .documentary: return 99
        case .drama: return 18
        case .family: return 10751
        case .fantasy: return 14
        case .history: return 36
        case .horror: return 27
        case .music: return 10402
        case .mystery: return 9648
        case .romance: return 10749
        case .scifi: return 878
        case .thriller: return 53
        case .war: return 10752
        case .western: return 37
        }
    }

    public var tvID: Int? {
        switch self {
        case .action, .adventure: return 10759
        case .animation: return 16
        case .comedy: return 35
        case .crime: return 80
        case .documentary: return 99
        case .drama: return 18
        case .family: return 10751
        case .fantasy, .scifi: return 10765
        case .mystery: return 9648
        case .war: return 10768
        case .western: return 37
        case .romance: return 10749
        case .history, .horror, .music, .thriller: return nil
        }
    }

    public var italianName: String {
        switch self {
        case .action: return "azione"
        case .adventure: return "avventura"
        case .animation: return "animazione"
        case .comedy: return "commedia"
        case .crime: return "crimine"
        case .documentary: return "documentario"
        case .drama: return "drammatico"
        case .family: return "famiglia"
        case .fantasy: return "fantasy"
        case .history: return "storico"
        case .horror: return "horror"
        case .music: return "musicale"
        case .mystery: return "mistero"
        case .romance: return "romantico"
        case .scifi: return "fantascienza"
        case .thriller: return "thriller"
        case .war: return "guerra"
        case .western: return "western"
        }
    }
}

public enum IntentKind: String, Codable, Sendable { case movie, series }

public enum IntentSort: String, Codable, Sendable {
    case popularity, rating, newest, oldest

    public var italianName: String {
        switch self {
        case .popularity: return "più popolari"
        case .rating: return "meglio votati"
        case .newest: return "più recenti"
        case .oldest: return "più vecchi"
        }
    }
}

/// Ciò che l'utente vuole, tradotto in filtri: lo producono il parser locale e i modelli AI, lo esegue TMDB.
public struct SearchIntent: Equatable, Sendable {
    public var kind: IntentKind?
    public var genres: [IntentGenre] = []
    /// Parole chiave TMDB (in inglese: «heist», «slasher», «parody»).
    public var keywords: [String] = []
    public var yearFrom: Int?
    public var yearTo: Int?
    public var sort: IntentSort = .popularity
    public var minRating: Double?
    public var countries: [String] = []
    public var maxRuntime: Int?
    /// Il titolo cercato, se la frase ne contiene uno preciso.
    public var title: String?
    /// «Film simili a Toy Story»: il titolo di partenza.
    public var similarTo: String?
    public var source: Source = .parser

    public enum Source: String, Sendable { case keyword, parser, apple, ai }

    public init() {}

    /// Vero se il testo ha prodotto almeno un filtro utile.
    public var hasFilters: Bool {
        return !genres.isEmpty || !keywords.isEmpty || yearFrom != nil || yearTo != nil || minRating != nil
            || !countries.isEmpty || maxRuntime != nil || kind != nil || similarTo != nil
    }

    /// La frase letta dall'app, in italiano, per mostrarla all'utente.
    public var summary: String {
        var parts: [String] = []
        if let similar = similarTo {
            let label = kind == .series ? "serie" : (kind == .movie ? "film" : "titoli")
            return "\(label) simili a «\(similar)»"
        }
        if let kind = kind { parts.append(kind == .movie ? "film" : "serie") }
        if !genres.isEmpty { parts.append(genres.map { $0.italianName }.joined(separator: " + ")) }
        if !keywords.isEmpty { parts.append("«" + keywords.joined(separator: ", ") + "»") }
        if let from = yearFrom, let to = yearTo {
            parts.append(from == to ? "\(from)" : "\(from)–\(to)")
        } else if let from = yearFrom {
            parts.append("dal \(from)")
        } else if let to = yearTo {
            parts.append("fino al \(to)")
        }
        if !countries.isEmpty { parts.append(countries.joined(separator: ", ")) }
        if let runtime = maxRuntime { parts.append("fino a \(runtime) min") }
        if let rating = minRating { parts.append("voto ≥ \(String(format: "%.1f", rating))") }
        parts.append(sort.italianName)
        return parts.joined(separator: " · ")
    }
}
