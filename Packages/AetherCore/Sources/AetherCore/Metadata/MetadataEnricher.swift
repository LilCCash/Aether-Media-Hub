import Foundation

/// Fills the gaps of an addon's meta with what the user's own TMDB / TheTVDB keys can tell about the same title.
///
/// Best effort by design: every failure (no key, wrong key, offline, rate limit, unknown title) simply means "no extra
/// data" and the addon's meta is shown as it is. Nothing the addon provided is overwritten (see `MetaItem.merging`).
public actor MetadataEnricher {
    /// Seasons asked from TMDB / TheTVDB for one title. Series with more seasons are enriched for the first ones only.
    static let maxSeasons = 12
    static let maxCast = 12
    static let imageHost = "image.tmdb.org"

    private let tmdb: TMDBClient?
    private let tvdb: TVDBClient?
    private let cache: ResponseCache?
    private let ttl: Int
    private let now: @Sendable () -> Date

    private var imageConfiguration: TMDBImageConfiguration?
    private var inFlight: [String: Task<MetadataEnrichment?, Never>] = [:]
    private var pausedUntil: [MetadataService: Date] = [:]

    public init(tmdb: TMDBClient?, tvdb: TVDBClient?, cache: ResponseCache? = nil, ttl: TimeInterval = 24 * 3600,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.tmdb = tmdb
        self.tvdb = tvdb
        self.cache = cache
        self.ttl = max(0, Int(ttl))
        self.now = now
    }

    /// True when at least one service has a key stored.
    public var isConfigured: Bool {
        return tmdb?.isConfigured == true || tvdb?.isConfigured == true
    }

    /// Forgets the "stop asking for a while" state; call it when the user saves, replaces or removes a key.
    public func reset() {
        pausedUntil.removeAll()
        imageConfiguration = nil
    }

    public func checkTMDB() async -> MetadataCheckResult {
        guard let tmdb = tmdb else { return .failed(.notConfigured) }
        let result = await tmdb.check()
        if result.isOK { pausedUntil[.tmdb] = nil }
        return result
    }

    public func checkTVDB() async -> MetadataCheckResult {
        guard let tvdb = tvdb else { return .failed(.notConfigured) }
        let result = await tvdb.check()
        if result.isOK { pausedUntil[.tvdb] = nil }
        return result
    }

    // MARK: Enrichment

    /// - Parameter language: a TMDB language tag such as "it-IT" or "it".
    /// - Returns: nil when there is nothing to add (no key, unsupported type, unknown title, failure).
    public func enrich(_ meta: MetaItem, language: String) async -> MetadataEnrichment? {
        guard let kind = MetadataEnricher.kind(forType: meta.type) else { return nil }
        let ids = ExternalIDs.fromMetaID(meta.id).filling(from: meta.externalIDs)
        if ids.isEmpty { return nil }

        let useTMDB = tmdb?.isConfigured == true && !isPaused(.tmdb)
        let useTVDB = kind == .tv && tvdb?.isConfigured == true && !isPaused(.tvdb)
        guard useTMDB || useTVDB else { return nil }

        let needs = kind == .tv ? MetadataEnricher.episodesNeedingData(in: meta) : []
        let key = MetadataEnricher.cacheKey(kind: kind, ids: ids, language: language, needs: needs, tmdb: useTMDB, tvdb: useTVDB)

        if let cache = cache, let hit = await cache.lookup(key), hit.isFresh,
           let stored = try? JSONDecoder().decode(MetadataEnrichment.self, from: hit.data) {
            return stored.isEmpty ? nil : stored
        }
        if let running = inFlight[key] { return await running.value }

        let task = Task<MetadataEnrichment?, Never> { [self] in
            await self.load(kind: kind, ids: ids, language: language, needs: needs, useTMDB: useTMDB, useTVDB: useTVDB, cacheKey: key)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func load(kind: TMDBClient.Kind, ids: ExternalIDs, language: String, needs: [EpisodeKey],
                      useTMDB: Bool, useTVDB: Bool, cacheKey: String) async -> MetadataEnrichment? {
        var result = MetadataEnrichment(ids: ids)
        var complete = true          // false after a failure that says nothing about the title: do not cache it

        if useTMDB, let tmdb = tmdb {
            do {
                let outcome = try await loadTMDB(tmdb, kind: kind, ids: ids, language: language, needs: needs)
                result = result.filling(from: outcome.enrichment)
                if !outcome.complete { complete = false }
            } catch let error as MetadataError {
                note(error, service: .tmdb)
                if error != .notFound { complete = false }
            } catch {
                complete = false
            }
        }

        if useTVDB, let tvdb = tvdb, kind == .tv {
            let missing = needs.filter { !result.hasEpisodeData(for: $0) }
            if !missing.isEmpty {
                do {
                    let episodes = try await loadTVDB(tvdb, ids: result.ids, language: language, missing: missing)
                    if !episodes.isEmpty {
                        result = result.filling(from: MetadataEnrichment(ids: result.ids, episodes: episodes, sources: [.tvdb]))
                    }
                } catch let error as MetadataError {
                    note(error, service: .tvdb)
                    if error != .notFound { complete = false }
                } catch {
                    complete = false
                }
            }
        }

        if complete, let cache = cache, let data = try? JSONEncoder().encode(result.isEmpty ? MetadataEnrichment() : result) {
            await cache.store(key: cacheKey, data: data, kind: .meta, hints: CacheHints(maxAge: ttl, staleError: 0))
        }
        return result.isEmpty ? nil : result
    }

    // MARK: TMDB

    private func loadTMDB(_ client: TMDBClient, kind: TMDBClient.Kind, ids: ExternalIDs, language: String,
                          needs: [EpisodeKey]) async throws -> (enrichment: MetadataEnrichment, complete: Bool) {
        let configuration = await imageConfiguration(client)

        var tmdbID = ids.tmdb
        if tmdbID == nil, let imdb = ids.imdb {
            let found = try await client.find(externalID: imdb, source: "imdb_id")
            tmdbID = (kind == .movie ? found.movieResults : found.tvResults).compactMap { $0.id }.first
        }
        if tmdbID == nil, kind == .tv, let tvdb = ids.tvdb {
            let found = try await client.find(externalID: String(tvdb), source: "tvdb_id")
            tmdbID = found.tvResults.compactMap { $0.id }.first
        }
        guard let id = tmdbID else { throw MetadataError.notFound }

        let details = try await client.details(kind: kind, id: id, language: language)
        var enrichment = MetadataEnrichment(sources: [.tmdb])
        enrichment.ids = ExternalIDs(imdb: details.externalIDs?.imdbID, tmdb: id, tvdb: details.externalIDs?.tvdbID).filling(from: ids)
        enrichment.overview = details.overview
        enrichment.tagline = details.tagline
        enrichment.poster = MetadataEnricher.imageURL(configuration, sizes: configuration.posterSizes, minimum: 500, path: details.posterPath)
        enrichment.backdrop = MetadataEnricher.imageURL(configuration, sizes: configuration.backdropSizes, minimum: 1280, path: details.backdropPath)
        enrichment.genres = details.genres.compactMap { $0.name }.filter { !$0.isEmpty }
        enrichment.year = MetadataEnricher.year(from: details.releaseDate)
        enrichment.runtimeMinutes = kind == .movie ? details.runtime.flatMap { $0 > 0 ? $0 : nil }
                                                   : details.episodeRunTime.first(where: { $0 > 0 })
        if let logo = MetadataEnricher.bestLogo(details.images?.logos ?? [], language: language) {
            enrichment.logo = MetadataEnricher.imageURL(configuration, sizes: configuration.logoSizes, minimum: 500, path: logo.filePath)
        }
        if let credits = details.credits {
            let ordered = credits.cast.sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
            enrichment.cast = Array(ordered.compactMap { $0.name }.filter { !$0.isEmpty }.prefix(MetadataEnricher.maxCast))
            if kind == .movie {
                var seen = Set<String>()
                enrichment.directors = credits.crew.filter { $0.job == "Director" }.compactMap { $0.name }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
            }
        }

        var complete = true
        if kind == .tv, !needs.isEmpty {
            let seasons = Array(Set(needs.map { $0.season })).sorted().prefix(MetadataEnricher.maxSeasons)
            for number in seasons {
                do {
                    let season = try await client.season(tvID: id, number: number, language: language)
                    for episode in season.episodes {
                        guard let numberInSeason = episode.number else { continue }
                        enrichment.episodes.append(EpisodeEnrichment(
                            season: episode.season ?? number, episode: numberInSeason, title: episode.name,
                            overview: episode.overview,
                            stillURL: MetadataEnricher.imageURL(configuration, sizes: configuration.stillSizes, minimum: 300, path: episode.stillPath)))
                    }
                } catch let error as MetadataError {
                    if error == .notFound { continue }
                    note(error, service: .tmdb)
                    complete = false
                    break
                } catch {
                    complete = false
                    break
                }
            }
        }
        return (enrichment, complete)
    }

    private func imageConfiguration(_ client: TMDBClient) async -> TMDBImageConfiguration {
        if let known = imageConfiguration { return known }
        if let fetched = try? await client.configuration() {
            var usable = fetched
            // The image host comes from TMDB's own answer, but only TMDB's image host (https) is accepted, plus the local
            // fixture hosts that the host-trust rule allows; anything else falls back to the documented default.
            if let base = fetched.secureBaseURL, let url = URL(string: base),
               !MetadataHTTP.isTrusted(url, productionHost: MetadataEnricher.imageHost) {
                usable.secureBaseURL = TMDBImageConfiguration().secureBaseURL
            } else if let base = fetched.secureBaseURL, URL(string: base) == nil {
                usable.secureBaseURL = TMDBImageConfiguration().secureBaseURL
            }
            if usable.posterSizes.isEmpty { usable.posterSizes = TMDBImageConfiguration().posterSizes }
            if usable.backdropSizes.isEmpty { usable.backdropSizes = TMDBImageConfiguration().backdropSizes }
            if usable.logoSizes.isEmpty { usable.logoSizes = TMDBImageConfiguration().logoSizes }
            if usable.stillSizes.isEmpty { usable.stillSizes = TMDBImageConfiguration().stillSizes }
            imageConfiguration = usable
            return usable
        }
        return TMDBImageConfiguration()
    }

    // MARK: TheTVDB

    private func loadTVDB(_ client: TVDBClient, ids: ExternalIDs, language: String, missing: [EpisodeKey]) async throws -> [EpisodeEnrichment] {
        var seriesID = ids.tvdb
        if seriesID == nil, let imdb = ids.imdb { seriesID = try await client.seriesID(forIMDbID: imdb) }
        guard let id = seriesID else { throw MetadataError.notFound }
        let wanted = Set(missing.map { $0.token })
        let episodes = try await client.episodes(seriesID: id, language: MetadataEnricher.tvdbLanguage(from: language))
        return episodes.compactMap { episode -> EpisodeEnrichment? in
            guard let season = episode.season, let number = episode.number, wanted.contains(EpisodeKey(season: season, episode: number).token) else { return nil }
            guard episode.name != nil || episode.overview != nil || episode.image != nil else { return nil }
            return EpisodeEnrichment(season: season, episode: number, title: episode.name, overview: episode.overview,
                                     stillURL: MetadataEnricher.secureImageURL(episode.image))
        }
    }

    // MARK: Failure memory

    private func isPaused(_ service: MetadataService) -> Bool {
        guard let until = pausedUntil[service] else { return false }
        if until > now() { return true }
        pausedUntil[service] = nil
        return false
    }

    /// After a failure that will repeat (wrong key, rate limit, service down) stop asking for a short while instead of
    /// firing the same failing request for every title the user opens.
    private func note(_ error: MetadataError, service: MetadataService) {
        let seconds: TimeInterval
        switch error {
        case .invalidCredentials, .untrustedHost, .notConfigured: seconds = 300
        case .rateLimited(let retryAfter): seconds = max(retryAfter ?? 60, 10)
        case .unavailable: seconds = 20
        case .notFound, .malformed: return
        }
        pausedUntil[service] = now().addingTimeInterval(seconds)
    }

    // MARK: Pure helpers (tested directly)

    struct EpisodeKey: Hashable {
        var season: Int
        var episode: Int
        var token: String { return "\(season):\(episode)" }
    }

    static func kind(forType type: String) -> TMDBClient.Kind? {
        switch type.lowercased() {
        case "movie": return .movie
        case "series": return .tv
        default: return nil
        }
    }

    /// Episodes of the meta that lack a real title, an overview or a picture, in season/episode order.
    static func episodesNeedingData(in meta: MetaItem) -> [EpisodeKey] {
        func blank(_ value: String?) -> Bool { return (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var keys = Set<EpisodeKey>()
        for video in meta.videos {
            guard let season = video.season, let episode = video.episode, season >= 0, episode > 0 else { continue }
            if blank(video.title) || MetaItem.isPlaceholderTitle(video.title, episode: episode) || blank(video.overview) || blank(video.thumbnail) {
                keys.insert(EpisodeKey(season: season, episode: episode))
            }
        }
        return keys.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    static func cacheKey(kind: TMDBClient.Kind, ids: ExternalIDs, language: String, needs: [EpisodeKey], tmdb: Bool, tvdb: Bool) -> String {
        let identity = ids.imdb ?? ids.tmdb.map { "tmdb\($0)" } ?? ids.tvdb.map { "tvdb\($0)" } ?? "unknown"
        let services = (tmdb ? "t" : "") + (tvdb ? "v" : "")
        let seasons = Array(Set(needs.map { $0.season })).sorted().prefix(maxSeasons).map(String.init).joined(separator: ",")
        let missing = needs.isEmpty ? "-" : String(Hashing.sha256Hex(needs.map { $0.token }.joined(separator: ";")).prefix(12))
        return "metadata:v1:\(kind.rawValue):\(identity):\(language.lowercased()):\(services):s\(seasons):\(missing)"
    }

    static func imageURL(_ configuration: TMDBImageConfiguration, sizes: [String], minimum: Int, path: String?) -> String? {
        guard let path = path, path.hasPrefix("/"), path.count > 1, !path.contains("..") else { return nil }
        let base = configuration.secureBaseURL ?? TMDBImageConfiguration().secureBaseURL ?? "https://image.tmdb.org/t/p/"
        let size = TMDBImageConfiguration.pick(sizes, atLeast: minimum)
        return (base.hasSuffix("/") ? base : base + "/") + size + path
    }

    /// TheTVDB image addresses are absolute; only https ones are used.
    static func secureImageURL(_ raw: String?) -> String? {
        guard let raw = raw, let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return raw
    }

    static func year(from date: String?) -> String? {
        guard let date = date, date.count >= 4 else { return nil }
        let head = String(date.prefix(4))
        return head.allSatisfy({ $0.isASCII && $0.isNumber }) && head != "0000" ? head : nil
    }

    /// Prefers a logo in the user's language, then English, then a language-less one; ties go to the better rated.
    /// Vector (.svg) logos are skipped: the app's image pipeline decodes raster images only.
    static func bestLogo(_ logos: [TMDBLogo], language: String) -> TMDBLogo? {
        let preferred = [String(language.prefix(2)).lowercased(), "en"]
        func rank(_ logo: TMDBLogo) -> Int {
            guard let code = logo.language?.lowercased(), !code.isEmpty else { return preferred.count }
            return preferred.firstIndex(of: code) ?? preferred.count + 1
        }
        let usable = logos.filter { logo in
            guard let path = logo.filePath, path.hasPrefix("/") else { return false }
            return !path.lowercased().hasSuffix(".svg")
        }
        return usable.min { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left < right }
            return (lhs.voteAverage ?? 0) > (rhs.voteAverage ?? 0)
        }
    }

    /// The TMDB language tag for the user's language setting ("system" follows the device): "it-IT", "en-GB", "pt-BR";
    /// scripts are dropped ("zh-Hans-CN" gives "zh-CN") and a bare language stays bare.
    public static func tmdbLanguage(preferred: String, systemLanguages: [String] = Locale.preferredLanguages) -> String {
        var raw = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.lowercased() == "system" || raw.lowercased() == "off" { raw = systemLanguages.first ?? "en" }
        let parts = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased(), language.count == 2 || language.count == 3,
              language.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "en-US" }
        if parts.count > 1, let region = parts.last, region.count == 2, region.allSatisfy({ $0.isASCII && $0.isLetter }) {
            return "\(language)-\(region.uppercased())"
        }
        return language
    }

    /// ISO 639-2 code TheTVDB wants for translations; English when the language is not in the table.
    static func tvdbLanguage(from language: String) -> String {
        let table = ["it": "ita", "en": "eng", "es": "spa", "fr": "fra", "de": "deu", "pt": "por", "nl": "nld", "pl": "pol",
                     "ru": "rus", "ja": "jpn", "ko": "kor", "zh": "zho", "tr": "tur", "sv": "swe", "da": "dan", "nb": "nor",
                     "no": "nor", "fi": "fin", "cs": "ces", "hu": "hun", "el": "ell", "he": "heb", "ar": "ara", "ro": "ron"]
        return table[String(language.prefix(2)).lowercased()] ?? "eng"
    }
}

extension MetadataEnrichment {
    fileprivate func hasEpisodeData(for key: MetadataEnricher.EpisodeKey) -> Bool {
        guard let episode = episodes.first(where: { $0.season == key.season && $0.episode == key.episode }) else { return false }
        func has(_ value: String?) -> Bool { return !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return has(episode.title) && has(episode.overview) && has(episode.stillURL)
    }

    /// Keeps what is already here and takes from `other` only what is missing. Sources are united.
    func filling(from other: MetadataEnrichment) -> MetadataEnrichment {
        var result = self
        func blank(_ value: String?) -> Bool { return (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(result.poster) { result.poster = other.poster }
        if blank(result.backdrop) { result.backdrop = other.backdrop }
        if blank(result.logo) { result.logo = other.logo }
        if blank(result.overview) { result.overview = other.overview }
        if blank(result.tagline) { result.tagline = other.tagline }
        if result.genres.isEmpty { result.genres = other.genres }
        if result.cast.isEmpty { result.cast = other.cast }
        if result.directors.isEmpty { result.directors = other.directors }
        if result.runtimeMinutes == nil { result.runtimeMinutes = other.runtimeMinutes }
        if blank(result.year) { result.year = other.year }
        result.ids = result.ids.filling(from: other.ids)

        var merged: [String: EpisodeEnrichment] = [:]
        var order: [String] = []
        for episode in result.episodes + other.episodes {
            let token = "\(episode.season):\(episode.episode)"
            if var existing = merged[token] {
                if blank(existing.title) { existing.title = episode.title }
                if blank(existing.overview) { existing.overview = episode.overview }
                if blank(existing.stillURL) { existing.stillURL = episode.stillURL }
                merged[token] = existing
            } else {
                merged[token] = episode
                order.append(token)
            }
        }
        result.episodes = order.compactMap { merged[$0] }
        for source in other.sources where !result.sources.contains(source) { result.sources.append(source) }
        return result
    }

    /// Credit lines to show next to a meta that this enrichment was merged into: none when it added nothing visible.
    public func creditLines(whenMergedInto meta: MetaItem) -> [String] {
        var merged = meta.merging(enrichment: self)
        var original = meta
        merged.externalIDs = ExternalIDs()
        original.externalIDs = ExternalIDs()
        return merged == original ? [] : attributions
    }
}
