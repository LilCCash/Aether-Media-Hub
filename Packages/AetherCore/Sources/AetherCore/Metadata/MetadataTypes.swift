import Foundation

public enum MetadataService: String, Codable, Hashable, Sendable {
    case tmdb, tvdb

    public var title: String { self == .tmdb ? "TMDB" : "TheTVDB" }

    /// Credit line that has to accompany data from the service.
    public var attribution: String {
        switch self {
        case .tmdb: return "This product uses the TMDB API but is not endorsed or certified by TMDB."
        case .tvdb: return "Metadati forniti da TheTVDB (thetvdb.com)."
        }
    }
}

public enum MetadataError: Error, Equatable, Sendable {
    case notConfigured
    case invalidCredentials
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable(String)
    case malformed
    case untrustedHost

    /// Italian text for the Settings screen. Never contains a key, a URL or a server message.
    public var message: String {
        switch self {
        case .notConfigured: return "Nessuna chiave configurata."
        case .invalidCredentials: return "Il servizio ha rifiutato la chiave: controlla di averla copiata per intero."
        case .notFound: return "Titolo non trovato nel servizio."
        case .rateLimited(let seconds):
            if let seconds = seconds, seconds > 0 { return "Troppe richieste: riprova tra \(Int(seconds.rounded(.up))) secondi." }
            return "Troppe richieste: riprova tra poco."
        case .unavailable: return "Il servizio non risponde. Riprova più tardi."
        case .malformed: return "Il servizio ha restituito una risposta che Aether non sa leggere."
        case .untrustedHost: return "Indirizzo del servizio non consentito."
        }
    }
}

public enum MetadataCheckResult: Equatable, Sendable {
    case ok
    case failed(MetadataError)

    public var isOK: Bool { return self == .ok }
}

public struct EpisodeEnrichment: Codable, Hashable, Sendable {
    public var season: Int
    public var episode: Int
    public var title: String?
    public var overview: String?
    public var stillURL: String?

    public init(season: Int, episode: Int, title: String? = nil, overview: String? = nil, stillURL: String? = nil) {
        self.season = season
        self.episode = episode
        self.title = title
        self.overview = overview
        self.stillURL = stillURL
    }
}

/// What the services know about a title, reduced to the fields that can ADD information to an addon's meta.
public struct MetadataEnrichment: Codable, Equatable, Sendable {
    public var ids: ExternalIDs
    public var poster: String?
    public var backdrop: String?
    public var logo: String?
    public var overview: String?
    public var tagline: String?
    public var genres: [String]
    public var cast: [String]
    public var directors: [String]
    public var runtimeMinutes: Int?
    public var year: String?
    public var episodes: [EpisodeEnrichment]
    public var sources: [MetadataService]

    public init(ids: ExternalIDs = ExternalIDs(), poster: String? = nil, backdrop: String? = nil, logo: String? = nil,
                overview: String? = nil, tagline: String? = nil, genres: [String] = [], cast: [String] = [],
                directors: [String] = [], runtimeMinutes: Int? = nil, year: String? = nil,
                episodes: [EpisodeEnrichment] = [], sources: [MetadataService] = []) {
        self.ids = ids
        self.poster = poster
        self.backdrop = backdrop
        self.logo = logo
        self.overview = overview
        self.tagline = tagline
        self.genres = genres
        self.cast = cast
        self.directors = directors
        self.runtimeMinutes = runtimeMinutes
        self.year = year
        self.episodes = episodes
        self.sources = sources
    }

    public var attributions: [String] { return sources.map { $0.attribution } }

    public var isEmpty: Bool {
        return poster == nil && backdrop == nil && logo == nil && overview == nil && tagline == nil && genres.isEmpty
            && cast.isEmpty && directors.isEmpty && runtimeMinutes == nil && year == nil && episodes.isEmpty
    }
}

extension MetaItem {
    /// Fills ONLY what the addon left empty. Nothing the addon provided is overwritten and ids never change.
    public func merging(enrichment: MetadataEnrichment) -> MetaItem {
        var result = self
        func blank(_ value: String?) -> Bool { return (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(result.poster), let value = enrichment.poster { result.poster = value }
        if blank(result.background), let value = enrichment.backdrop { result.background = value }
        if blank(result.logo), let value = enrichment.logo { result.logo = value }
        if blank(result.description), let value = enrichment.overview ?? enrichment.tagline { result.description = value }
        if result.genres.isEmpty { result.genres = enrichment.genres }
        if result.cast.isEmpty { result.cast = enrichment.cast }
        if result.directors.isEmpty { result.directors = enrichment.directors }
        if blank(result.runtime), let minutes = enrichment.runtimeMinutes, minutes > 0 { result.runtime = "\(minutes) min" }
        if blank(result.releaseInfo), let year = enrichment.year { result.releaseInfo = year }
        result.externalIDs = result.externalIDs.filling(from: enrichment.ids)

        if !enrichment.episodes.isEmpty, !result.videos.isEmpty {
            var lookup: [String: EpisodeEnrichment] = [:]
            for episode in enrichment.episodes { lookup["\(episode.season):\(episode.episode)"] = episode }
            result.videos = result.videos.map { video -> Video in
                guard let season = video.season, let number = video.episode, let extra = lookup["\(season):\(number)"] else { return video }
                var updated = video
                if blank(updated.title) || MetaItem.isPlaceholderTitle(updated.title, episode: number), let title = extra.title, !blank(title) {
                    updated.title = title
                }
                if blank(updated.overview), let overview = extra.overview { updated.overview = overview }
                if blank(updated.thumbnail), let still = extra.stillURL { updated.thumbnail = still }
                return updated
            }
        }
        return result
    }

    /// "Episode 4", "Episodio 4", "Ep. 4", "4": names an addon uses when it has no real title.
    static func isPlaceholderTitle(_ title: String, episode: Int) -> Bool {
        let cleaned = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == "\(episode)" { return true }
        for prefix in ["episode", "episodio", "ep.", "ep", "épisode", "folge"] where cleaned.hasPrefix(prefix) {
            let rest = cleaned.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if rest == "\(episode)" { return true }
        }
        return false
    }
}
