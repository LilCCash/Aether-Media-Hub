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
    private var inFlightRich: [String: Task<TitleRichDetails?, Never>] = [:]
    private var imdbMemo: [String: String] = [:]
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

    /// The title's own transparent logo from TMDB (the viewer's language first, then English), for when fanart.tv has none or there is no
    /// fanart.tv key. Nil when TMDB is not set up or knows no logo.
    public func logoURL(for meta: MetaItem, language: String) async -> URL? {
        guard let kind = MetadataEnricher.kind(forType: meta.type), let client = tmdb, client.isConfigured, !isPaused(.tmdb) else { return nil }
        let ids = ExternalIDs.fromMetaID(meta.id).filling(from: meta.externalIDs)
        if ids.isEmpty { return nil }
        do {
            let id = try await resolveTMDBID(client, kind: kind, ids: ids)
            let list = try await client.imageList(kind: kind, id: id, language: language)
            guard let best = MetadataEnricher.bestLogo(list.logos, language: language) else { return nil }
            let configuration = await imageConfiguration(client)
            return MetadataEnricher.imageURL(configuration, sizes: configuration.logoSizes, minimum: 500, path: best.filePath).flatMap { URL(string: $0) }
        } catch {
            return nil
        }
    }

    /// The TheTVDB code of a series, asked of TMDB (fanart.tv knows series by it; the catalogs seldom give it).
    public func tvdbID(for meta: MetaItem) async -> Int? {
        guard let kind = MetadataEnricher.kind(forType: meta.type), kind == .tv, let client = tmdb, client.isConfigured, !isPaused(.tmdb) else { return nil }
        let ids = ExternalIDs.fromMetaID(meta.id).filling(from: meta.externalIDs)
        if ids.isEmpty { return nil }
        if let known = ids.tvdb { return known }
        do {
            let id = try await resolveTMDBID(client, kind: kind, ids: ids)
            return try await client.externalIDs(kind: kind, id: id).tvdbID
        } catch {
            return nil
        }
    }

    /// The posters TMDB has for a title, as image addresses (empty when TMDB is not set up or does not know the title).
    public func posterAlternatives(for meta: MetaItem, language: String) async -> [String] {
        guard let kind = MetadataEnricher.kind(forType: meta.type), let client = tmdb, client.isConfigured, !isPaused(.tmdb) else { return [] }
        let ids = ExternalIDs.fromMetaID(meta.id).filling(from: meta.externalIDs)
        if ids.isEmpty { return [] }
        do {
            let id = try await resolveTMDBID(client, kind: kind, ids: ids)
            let paths = try await client.posterPaths(kind: kind, id: id, language: language)
            let configuration = await imageConfiguration(client)
            var seen = Set<String>()
            var result: [String] = []
            for path in paths {
                if let url = MetadataEnricher.imageURL(configuration, sizes: configuration.posterSizes, minimum: 500, path: path), seen.insert(url).inserted {
                    result.append(url)
                }
            }
            return result
        } catch {
            return []
        }
    }

    /// All the posters, backdrops and logos TMDB has for a title (empty when TMDB is not set up or does not know it).
    public func artwork(for meta: MetaItem, language: String) async -> TitleArtwork {
        guard let kind = MetadataEnricher.kind(forType: meta.type), let client = tmdb, client.isConfigured, !isPaused(.tmdb) else { return TitleArtwork() }
        let ids = ExternalIDs.fromMetaID(meta.id).filling(from: meta.externalIDs)
        if ids.isEmpty { return TitleArtwork() }
        do {
            let id = try await resolveTMDBID(client, kind: kind, ids: ids)
            let list = try await client.imageList(kind: kind, id: id, language: language)
            let configuration = await imageConfiguration(client)
            let base = configuration.secureBaseURL ?? "https://image.tmdb.org/t/p/"
            func urls(_ paths: [String]) -> [String] {
                var seen = Set<String>()
                return paths.filter { $0.hasPrefix("/") && $0.count > 1 && !$0.contains("..") }
                    .map { (base.hasSuffix("/") ? base : base + "/") + "original" + $0 }.filter { seen.insert($0).inserted }
            }
            return TitleArtwork(posters: urls(list.posters), backdrops: urls(list.backdrops),
                                logos: urls(list.logos.compactMap { $0.filePath }.filter { !$0.lowercased().hasSuffix(".svg") }))
        } catch {
            return TitleArtwork()
        }
    }

    /// Films and series that come out in the next `days` days (the release calendar), most talked about first.
    public func upcoming(language: String, region: String, days: Int = 120) async -> [DiscoveryCard] {
        guard let client = tmdb, client.isConfigured, !isPaused(.tmdb) else { return [] }
        let from = DiscoveryDates.format(Date())
        let to = DiscoveryDates.format(Date().addingTimeInterval(Double(days) * 86_400))
        let configuration = await imageConfiguration(client)
        var cards: [DiscoveryCard] = []
        for kind in [TMDBClient.Kind.movie, .tv] {
            guard let items = try? await client.upcoming(kind: kind, language: language, region: region, from: from, to: to) else { continue }
            cards += items.compactMap { MetadataEnricher.card($0, kind: kind, configuration: configuration) }
        }
        return cards.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    /// Well rated titles with a wide picture, for the full-screen discovery; `page` 1...5 gives a different set.
    public func acclaimed(type: String, language: String, page: Int) async -> [DiscoveryCard] {
        guard let kind = MetadataEnricher.kind(forType: type), let client = tmdb, client.isConfigured, !isPaused(.tmdb) else { return [] }
        let configuration = await imageConfiguration(client)
        guard let items = try? await client.acclaimed(kind: kind, language: language, page: page) else { return [] }
        return items.compactMap { MetadataEnricher.card($0, kind: kind, configuration: configuration) }.filter { $0.backdropURL != nil }
    }

    static func card(_ item: TMDBDiscoverItem, kind: TMDBClient.Kind, configuration: TMDBImageConfiguration) -> DiscoveryCard? {
        guard let id = item.id, let title = item.title, !title.isEmpty else { return nil }
        return DiscoveryCard(tmdbID: id, type: kind == .movie ? "movie" : "series", title: title, overview: item.overview ?? "",
                             posterURL: imageURL(configuration, sizes: configuration.posterSizes, minimum: 500, path: item.posterPath),
                             backdropURL: imageURL(configuration, sizes: configuration.backdropSizes, minimum: 1280, path: item.backdropPath),
                             date: DiscoveryDates.parse(item.date), rating: item.voteAverage, genreIDs: item.genreIDs)
    }

    // MARK: TMDB

    private func loadTMDB(_ client: TMDBClient, kind: TMDBClient.Kind, ids: ExternalIDs, language: String,
                          needs: [EpisodeKey]) async throws -> (enrichment: MetadataEnrichment, complete: Bool) {
        let configuration = await imageConfiguration(client)

        let id = try await resolveTMDBID(client, kind: kind, ids: ids)

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

    /// The TMDB id of a title: the one already known, else found through its IMDb id (or, for a series, its TheTVDB id).
    private func resolveTMDBID(_ client: TMDBClient, kind: TMDBClient.Kind, ids: ExternalIDs) async throws -> Int {
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
        return id
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
            if usable.profileSizes.isEmpty { usable.profileSizes = TMDBImageConfiguration().profileSizes }
            imageConfiguration = usable
            return usable
        }
        return TMDBImageConfiguration()
    }

    // MARK: Title page

    /// True when a TMDB key is stored (the title page offers to add one when it is not).
    public var tmdbConfigured: Bool { return tmdb?.isConfigured == true }

    /// The cast with photos, producers, trailers, facts and similar titles of `meta`, from TMDB.
    /// - Returns: nil when there is nothing to show (no key, unsupported type, unknown title, failure). Never throws.
    public func richDetails(for meta: MetaItem, language: String) async -> TitleRichDetails? {
        guard let kind = MetadataEnricher.kind(forType: meta.type), let tmdb = tmdb, tmdb.isConfigured, !isPaused(.tmdb) else { return nil }
        let ids = ExternalIDs.fromMetaID(meta.id).filling(from: meta.externalIDs)
        if ids.isEmpty { return nil }
        let identity = ids.tmdb.map { "tmdb\($0)" } ?? ids.imdb ?? ids.tvdb.map { "tvdb\($0)" } ?? "unknown"
        let key = "metadata:rich:v1:\(kind.rawValue):\(identity):\(language.lowercased())"

        if let cache = cache, let hit = await cache.lookup(key), hit.isFresh,
           let stored = try? JSONDecoder().decode(TitleRichDetails.self, from: hit.data) {
            return stored.isEmpty ? nil : stored
        }
        if let running = inFlightRich[key] { return await running.value }

        let task = Task<TitleRichDetails?, Never> { [self] in
            await self.loadRich(tmdb, kind: kind, ids: ids, language: language, cacheKey: key)
        }
        inFlightRich[key] = task
        let result = await task.value
        inFlightRich[key] = nil
        return result
    }

    private func loadRich(_ client: TMDBClient, kind: TMDBClient.Kind, ids: ExternalIDs, language: String, cacheKey: String) async -> TitleRichDetails? {
        do {
            let configuration = await imageConfiguration(client)
            let id = try await resolveTMDBID(client, kind: kind, ids: ids)
            let details = try await client.richDetails(kind: kind, id: id, language: language)
            var rich = TitleRichDetails.make(from: details, tmdbID: id, isMovie: kind == .movie, configuration: configuration, language: language)
            if kind == .movie, let reference = details.collection, let collectionID = reference.id, let name = reference.name, !name.isEmpty {
                rich.collection = TitleRichDetails.CollectionRef(id: collectionID, name: name)
            }
            if let cache = cache, let data = try? JSONEncoder().encode(rich) {
                await cache.store(key: cacheKey, data: data, kind: .meta, hints: CacheHints(maxAge: ttl, staleError: 0))
            }
            return rich.isEmpty ? nil : rich
        } catch let error as MetadataError {
            note(error, service: .tmdb)
            return nil
        } catch {
            return nil
        }
    }

    /// The films of a saga, oldest first, as `Similar` entries (so the title page can show them like the similar titles).
    /// Empty when there is no key or TMDB does not answer.
    public func collectionParts(id: Int, language: String) async -> [TitleRichDetails.Similar] {
        guard let tmdb = tmdb, tmdb.isConfigured, !isPaused(.tmdb) else { return [] }
        do {
            let collection = try await tmdb.collection(id: id, language: language)
            let parts = collection.parts.compactMap { part -> (date: String, item: TitleRichDetails.Similar)? in
                guard let partID = part.id, let title = part.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
                let item = TitleRichDetails.Similar(tmdbID: partID, title: title, posterURL: PersonCredit.posterURL(part.posterPath),
                                                    year: MetadataEnricher.year(from: part.releaseDate),
                                                    rating: part.voteAverage.flatMap { $0 > 0 ? $0 : nil })
                return (date: part.releaseDate ?? "9999", item: item)
            }
            return parts.sorted { $0.date < $1.date }.map { $0.item }
        } catch let error as MetadataError {
            note(error, service: .tmdb)
            return []
        } catch {
            return []
        }
    }

    /// What a person appeared in (the best known first, with the character played), from TMDB.
    /// Empty when there is no key, the service does not answer or the person is unknown. Never throws.
    public func filmography(personID: Int, language: String, hideTalkShows: Bool = true) async -> [PersonCredit] {
        guard let tmdb = tmdb, tmdb.isConfigured, !isPaused(.tmdb) else { return [] }
        do {
            let credits = try await tmdb.personCredits(id: personID, language: language)
            return PersonCredit.make(from: credits, hideTalkShows: hideTalkShows)
        } catch let error as MetadataError {
            note(error, service: .tmdb)
            return []
        } catch {
            return []
        }
    }

    /// Who worked with the person in their best known titles (TMDB credits of up to six of them).
    public func collaborators(of profile: PersonProfile, personID: Int, language: String) async -> [PersonCollaborator] {
        guard let tmdb = tmdb, tmdb.isConfigured, !isPaused(.tmdb) else { return [] }
        let top = profile.filmography.filter { $0.roles.contains(.actor) }.prefix(6)
        var collected: [(title: String, credits: TMDBCredits)] = []
        await withTaskGroup(of: (String, TMDBCredits)?.self) { group in
            for entry in top {
                group.addTask {
                    guard let credits = try? await tmdb.creditsOf(kind: entry.isMovie ? .movie : .tv, id: entry.tmdbID, language: language) else { return nil }
                    return (entry.title, credits)
                }
            }
            for await item in group { if let item = item { collected.append((title: item.0, credits: item.1)) } }
        }
        return PersonProfile.collaborators(of: personID, titles: collected)
    }

    /// The Wikidata item of a person, if TMDB knows it.
    public func wikidataID(personID: Int) async -> String? {
        guard let tmdb = tmdb, tmdb.isConfigured, !isPaused(.tmdb) else { return nil }
        return (try? await tmdb.personWikidataID(id: personID)) ?? nil
    }

    /// People whose name matches (actors, directors…), the best known first. Empty without a key or on any error.
    public func searchPeople(_ text: String, language: String) async -> [PersonSearchResult] {
        guard text.count >= 3, let tmdb = tmdb, tmdb.isConfigured, !isPaused(.tmdb) else { return [] }
        do {
            return PersonSearchResult.make(from: try await tmdb.searchPeople(text: text, language: language))
        } catch let error as MetadataError {
            note(error, service: .tmdb)
            return []
        } catch {
            return []
        }
    }

    /// The person's page: photo, biography, birth, and the whole career (acting, directing, writing, producing, music, photography). Nil when TMDB cannot say.
    public func personProfile(personID: Int, name: String, language: String, hideTalkShows: Bool = true) async -> PersonProfile? {
        guard let tmdb = tmdb, tmdb.isConfigured, !isPaused(.tmdb) else { return nil }
        do {
            async let details = tmdb.personDetails(id: personID, language: language)
            async let credits = tmdb.personCredits(id: personID, language: language)
            var found = try await details
            // The biography is empty in some languages: ask for the English one.
            if (found.biography ?? "").isEmpty, language != "en-US", let english = try? await tmdb.personDetails(id: personID, language: "en-US") {
                found.biography = english.biography
            }
            return PersonProfile.make(details: found, credits: try await credits, fallbackName: name, hideTalkShows: hideTalkShows)
        } catch let error as MetadataError {
            note(error, service: .tmdb)
            return nil
        } catch {
            return nil
        }
    }

    /// The IMDb id of a TMDB title (what a catalog address is made of), so that a similar title can be opened like any other.
    /// Nil when TMDB does not know one or the service does not answer.
    public func imdbID(forTMDBID id: Int, metaType: String) async -> String? {
        guard let kind = MetadataEnricher.kind(forType: metaType), let tmdb = tmdb, tmdb.isConfigured, !isPaused(.tmdb) else { return nil }
        let memo = "\(kind.rawValue):\(id)"
        if let known = imdbMemo[memo] { return known }
        do {
            let ids = try await tmdb.externalIDs(kind: kind, id: id)
            if let imdb = ids.imdbID { imdbMemo[memo] = imdb }
            return ids.imdbID
        } catch let error as MetadataError {
            note(error, service: .tmdb)
            return nil
        } catch {
            return nil
        }
    }

    /// Fetches the full plot and ratings for one episode on demand, using the user's TMDB key.
    /// TMDB also supplies the IMDb title ID when available, but does not expose IMDb's own score in this endpoint.
    public func episodeDetails(for meta: MetaItem, video: Video, language: String) async -> EpisodeRichDetails? {
        guard let season = video.season, let episode = video.episode,
              let tmdb = tmdb, tmdb.isConfigured, !isPaused(.tmdb),
              let kind = MetadataEnricher.kind(forType: meta.type), kind == .tv else { return nil }
        let ids = ExternalIDs.fromMetaID(meta.id).filling(from: meta.externalIDs)
        do {
            let tvID = try await resolveTMDBID(tmdb, kind: .tv, ids: ids)
            let response = try await tmdb.season(tvID: tvID, number: season, language: language)
            guard let item = response.episodes.first(where: { $0.number == episode }) else { return nil }
            let externalIDs = try? await tmdb.episodeExternalIDs(tvID: tvID, season: season, episode: episode)
            return EpisodeRichDetails(title: item.name, overview: item.overview, tmdbRating: item.voteAverage,
                                      imdbID: externalIDs?.imdbID, season: season, episode: episode)
        } catch let error as MetadataError {
            note(error, service: .tmdb)
            return nil
        } catch {
            return nil
        }
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

    /// Whether TMDB covers this kind of meta (films and series).
    public static func isCovered(type: String) -> Bool {
        return kind(forType: type) != nil
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
