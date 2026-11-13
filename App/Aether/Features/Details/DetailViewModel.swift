import SwiftUI
import AetherCore

@MainActor
final class DetailViewModel: ObservableObject {
    @Published private(set) var meta: MetaItem
    @Published private(set) var providerName: String?
    @Published private(set) var isLoading = true
    @Published private(set) var failures: [AddonError] = []
    @Published private(set) var hadDetailProvider = true
    @Published private(set) var watchedIDs = Set<String>()
    @Published private(set) var progress: [String: PlaybackProgress] = [:]
    @Published private(set) var canPlay = true
    /// Credit lines for the services whose data was added to this meta (empty when nothing was added).
    @Published private(set) var attributions: [String] = []
    /// What TMDB adds to the page (cast with photos, trailers, producers, facts, similar titles); nil without a key or an answer.
    @Published private(set) var rich: TitleRichDetails?
    @Published private(set) var tmdbConfigured = true
    /// Ratings from MDBList (IMDb, Rotten Tomatoes, Metacritic…) and the films of the saga the title belongs to.
    @Published private(set) var ratings: [MDBRating] = []
    @Published private(set) var sagaFilms: [TitleRichDetails.Similar] = []
    @Published var selectedSeason: Int?

    let route: MetaRoute

    init(route: MetaRoute) {
        self.route = route
        self.meta = route.preview ?? MetaItem(id: route.id, type: route.type, name: route.id)
    }

    func load(env: AppEnvironment, mode: AddonClient.LoadMode = .normal) async {
        isLoading = true
        let resolution = await env.service.meta(type: route.type, id: route.id, fallback: route.preview, mode: mode)
        if Task.isCancelled { return }
        meta = resolution.meta
        providerName = resolution.providerName
        failures = resolution.failures
        hadDetailProvider = resolution.hadDetailProvider
        isLoading = false
        await refreshLibraryState(env: env)
        let handles = await env.addons.handles()
        canPlay = RequestPlanner.canProvideStreams(type: meta.type, id: playableVideoID(), handles: handles)
        if selectedSeason == nil {
            selectedSeason = initialSeason()
        }
        FanartLogoStore.shared.prefetch(meta: meta, env: env)
        async let enriched: Void = enrich(env: env)
        async let richLoaded: Void = loadRich(env: env)
        _ = await (enriched, richLoaded)
        // The logo for the preparing page is fetched now, so it is on screen the moment a source is chosen.
        FanartLogoStore.shared.prefetch(meta: meta, env: env)
    }

    /// The sections that need TMDB. Silent: without a key, or when the service does not answer, the page keeps what the addon gave.
    private func loadRich(env: AppEnvironment) async {
        let base = meta
        tmdbConfigured = await env.metadata.tmdbConfigured
        guard tmdbConfigured else {
            rich = nil
            return
        }
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        let result = await env.metadata.richDetails(for: base, language: language)
        guard !Task.isCancelled, meta.id == base.id else { return }
        rich = result
        guard let result else { return }
        let content = env.settings.value.content
        var films: [TitleRichDetails.Similar] = []
        if content.titleModules.collection, let collection = result.collection {
            films = await env.metadata.collectionParts(id: collection.id, language: language)
        }
        var found: [MDBRating] = []
        if content.ratings.enabled, env.mdblist.isConfigured {
            found = await env.mdblist.ratings(tmdbID: result.tmdbID, isMovie: result.isMovie)
        }
        guard !Task.isCancelled, meta.id == base.id else { return }
        sagaFilms = films.count > 1 ? films : []
        ratings = found
    }

    /// The page can offer to add a key only for the types TMDB covers.
    var suggestsTMDBKey: Bool {
        return !tmdbConfigured && !isLoading && MetadataEnricher.isCovered(type: meta.type)
    }

    /// Every trailer to offer: TMDB's when there are some, else the ones the addon listed.
    var trailerLinks: [(title: String, url: URL)] {
        if let rich = rich, !rich.trailers.isEmpty {
            return rich.trailers.compactMap { trailer in trailer.watchURL.map { (trailer.name, $0) } }
        }
        let found = meta.trailers.compactMap { trailer in trailer.watchURL }
        return found.enumerated().map { (title: found.count > 1 ? "Trailer \($0.offset + 1)" : "Trailer", url: $0.element) }
    }

    /// Adds what the user's own TMDB / TheTVDB keys know to the addon's meta, filling only what the addon left empty.
    /// Silent: without a key, or when a service does not answer, the meta stays as the addon provided it.
    private func enrich(env: AppEnvironment) async {
        let base = meta
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        guard let enrichment = await env.metadata.enrich(base, language: language), !Task.isCancelled, meta.id == base.id else { return }
        attributions = enrichment.creditLines(whenMergedInto: base)
        meta = base.merging(enrichment: enrichment, preferProviderText: true)
        if selectedSeason == nil { selectedSeason = initialSeason() }
    }

    func refreshLibraryState(env: AppEnvironment) async {
        watchedIDs = await env.libraryStore.watchedVideoIDs(metaID: meta.id)
        var map: [String: PlaybackProgress] = [:]
        for record in await env.libraryStore.history(limit: 2000) where record.metaID == meta.id {
            map[record.videoID] = record
        }
        progress = map
    }

    private func playableVideoID() -> String {
        return meta.videos.first?.id ?? meta.id
    }

    private func initialSeason() -> Int? {
        let seasons = meta.seasons
        guard !seasons.isEmpty else { return nil }
        if let focus = route.videoID, let video = meta.videos.first(where: { $0.id == focus }), let season = video.season { return season }
        // Continue where the user is: the season of the most recent progress, else the first regular season.
        if let latest = progress.values.max(by: { $0.updatedAt < $1.updatedAt }), let season = latest.season, seasons.contains(season) {
            return season
        }
        return seasons.first(where: { $0 != 0 }) ?? seasons.first
    }

    var isSeries: Bool { return !meta.videos.isEmpty && meta.videos.contains(where: { $0.isEpisode }) }

    var visibleEpisodes: [Video] {
        guard let season = selectedSeason else { return meta.videos }
        return meta.videos(inSeason: season)
    }

    /// What the main Play button should start.
    func primaryVideo() -> Video? {
        guard isSeries else { return nil }
        let lastCompleted = progress.values.filter { $0.isCompleted }.max(by: { $0.updatedAt < $1.updatedAt })?.videoID
        let inProgress = progress.values.filter { !$0.isCompleted && $0.position >= 10 }.max(by: { $0.updatedAt < $1.updatedAt })?.videoID
        return NextEpisodeResolver.episodeToPlay(in: meta, watched: watchedIDs, lastWatchedID: lastCompleted, inProgressID: inProgress)
    }

    func primaryButtonTitle() -> String {
        if let video = primaryVideo() {
            let label = video.episodeLabel ?? "episodio"
            if let record = progress[video.id], !record.isCompleted, record.position >= 10 { return "Riprendi \(label)" }
            if watchedIDs.isEmpty && progress.isEmpty { return "Guarda \(label)" }
            return "Guarda \(label)"
        }
        if let record = progress[meta.id], !record.isCompleted, record.position >= 10 { return "Riprendi" }
        return "Guarda"
    }
}
