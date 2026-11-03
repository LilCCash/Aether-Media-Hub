import Foundation

public enum TraktError: Error, Equatable, Sendable {
    case notConnected
    case unauthorized
    case rateLimited
    /// 420: i limiti dell'account gratuito (lista o watchlist piena).
    case accountLimit
    /// 426: funzione riservata a Trakt VIP.
    case vipRequired
    case notFound
    case server(Int)
    case network
    /// Il collegamento non è partito: il motivo, in italiano.
    case transport(String)
    case malformed
    /// Collegamento: l'utente non ha ancora inserito il codice.
    case pending
    case denied
    case expired

    public var message: String {
        switch self {
        case .notConnected: return "Trakt non è collegato."
        case .unauthorized: return "Il collegamento con Trakt è scaduto: ricollegalo."
        case .rateLimited: return "Trakt chiede di rallentare: riprova tra poco."
        case .accountLimit: return "Hai raggiunto il limite del tuo account Trakt gratuito (lista o watchlist piena)."
        case .vipRequired: return "Questa funzione richiede Trakt VIP."
        case .notFound: return "Trakt non ha trovato quello che cercavo."
        case .server(let status): return "Trakt ha risposto con un errore \(status)."
        case .network: return "Impossibile raggiungere Trakt: controlla la connessione."
        case .transport(let reason): return "Impossibile raggiungere Trakt (\(reason))."
        case .malformed: return "Trakt ha risposto in un modo che non so leggere."
        case .pending: return "In attesa che tu inserisca il codice."
        case .denied: return "Hai rifiutato il collegamento su Trakt."
        case .expired: return "Il codice è scaduto: riprova."
        }
    }
}

/// I dati di accesso. Il token vale 7 giorni; quello di rinnovo si può usare una volta sola.
public struct TraktSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var createdAt: Date
    public var expiresIn: Double

    public init(accessToken: String, refreshToken: String, createdAt: Date, expiresIn: Double) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.createdAt = createdAt
        self.expiresIn = expiresIn
    }

    public var expiresAt: Date { return createdAt.addingTimeInterval(expiresIn) }
    /// Da rinnovare quando manca meno di un giorno.
    public func needsRefresh(now: Date = Date()) -> Bool { return now.addingTimeInterval(86_400) >= expiresAt }
}

public struct TraktDeviceCode: Equatable, Sendable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: String
    public var expiresIn: Int
    public var interval: Int
}

public struct TraktUser: Equatable, Sendable {
    public var username: String
    public var vip: Bool
    public var watchlistLimit: Int?
    public var listLimit: Int?
}

/// Un film o una serie come lo descrive Trakt.
public struct TraktTitle: Equatable, Sendable {
    public enum Kind: String, Sendable { case movie, show }
    public var kind: Kind
    public var title: String
    public var year: Int?
    public var imdb: String?
    public var tmdb: Int?
    public var tvdb: Int?
    /// Dettaglio utile per la riga («12 spettatori», «voto 85%»…).
    public var note: String?
    /// 0-100 per i titoli iniziati (riprendi).
    public var progress: Double?
    /// Per gli episodi (calendario, riprendi).
    public var season: Int?
    public var episode: Int?
    public var episodeTitle: String?
    /// Moment in which the episode airs (ISO 8601, as Trakt writes it), for the calendar.
    public var firstAired: String?
}

public struct TraktListInfo: Identifiable, Equatable, Sendable {
    public var id: Int
    public var slug: String
    public var name: String
    public var itemCount: Int
}

/// I cataloghi che Trakt offre.
public enum TraktCatalogKind: String, CaseIterable, Codable, Sendable {
    case continueWatching, calendar, recommendedMovies, recommendedShows, watchlist
    case trendingMovies, trendingShows, popularMovies, popularShows, anticipatedMovies, anticipatedShows, boxOffice

    public var title: String {
        switch self {
        case .continueWatching: return "Da riprendere (Trakt)"
        case .calendar: return "In uscita nei prossimi giorni"
        case .recommendedMovies: return "Film consigliati per te"
        case .recommendedShows: return "Serie consigliate per te"
        case .watchlist: return "La tua watchlist"
        case .trendingMovies: return "Film in tendenza"
        case .trendingShows: return "Serie in tendenza"
        case .popularMovies: return "Film popolari"
        case .popularShows: return "Serie popolari"
        case .anticipatedMovies: return "Film più attesi"
        case .anticipatedShows: return "Serie più attese"
        case .boxOffice: return "Box office della settimana"
        }
    }

    /// Serve aver collegato l'account.
    public var needsLogin: Bool {
        switch self {
        case .continueWatching, .calendar, .recommendedMovies, .recommendedShows, .watchlist: return true
        default: return false
        }
    }
}

/// Un elemento di un catalogo, pronto da mostrare.
public struct TraktShelfItem: Identifiable, Equatable, Sendable {
    public var meta: MetaItem
    public var note: String?
    public var id: String { return meta.id }
}
