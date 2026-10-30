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

struct DetailView: View {
    let route: MetaRoute
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.openURL) private var openURL
    @Environment(\.aetherStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoomed = false
    @State private var revealed = false
    @StateObject private var model: DetailViewModel
    @State private var picker: StreamPickerRequest?
    @State private var posterPicker = false
    @ObservedObject private var posterOverrides = PosterOverrides.shared
    @State private var descriptionExpanded = false
    @State private var openedSimilar: MetaRoute?
    @State private var openedPerson: PersonRoute?
    @State private var similarProblem: String?
    /// True while TMDB is asked for the IMDb code of a similar title: more taps meanwhile would start more lookups.
    @State private var lookingUpSimilar = false
    @State private var isDownloadingSeason = false
    @State private var isCancellingSeasonDownload = false
    @State private var seasonDownloadTask: Task<Void, Never>?
    @State private var seasonBatchDownloadIDs = Set<UUID>()
    @State private var seasonDownloadMessage: String?
    @State private var episodeDetailsRequest: EpisodeDetailsRequest?

    init(route: MetaRoute) {
        self.route = route
        _model = StateObject(wrappedValue: DetailViewModel(route: route))
    }

    var body: some View {
        ZStack {
            AetherBackdrop(immersive: style.cinematic)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    actions
                    infoBlock
                    if model.isSeries { episodes }
                    if !model.meta.cast.isEmpty || !model.meta.directors.isEmpty || !(model.rich?.creators.isEmpty ?? true) { credits }
                    richSections
                    if !model.failures.isEmpty && model.hadDetailProvider && model.providerName == nil { failureNote }
                    footer
                }
                .padding(.bottom, 40)
                // Cinematic reveal: the page fades in and settles instead of just sliding in.
                .opacity(style.cinematic && style.motion && !reduceMotion && !revealed ? 0 : 1)
                .scaleEffect(style.cinematic && style.motion && !reduceMotion && !revealed ? 1.06 : 1, anchor: .top)
            }
            .ignoresSafeArea(edges: .top)
        }
        .preferredColorScheme(style.cinematic ? .dark : nil)
        .onAppear { withAnimation(.easeOut(duration: 0.8)) { revealed = true } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { posterPicker = true } label: {
                    Image(systemName: "photo.on.rectangle")
                }
                .accessibilityLabel("Locandine alternative")
                .accessibilityIdentifier("detail.posters")
                Button { library.toggleFavorite(model.meta) } label: {
                    Image(systemName: library.favoriteIDs.contains(model.meta.id) ? "heart.fill" : "heart")
                }
                .accessibilityLabel(library.favoriteIDs.contains(model.meta.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")
                .accessibilityIdentifier("detail.favorite")
            }
        }
        .task(id: network.reconnectToken) { await model.load(env: env) }
        .task(id: model.meta.background ?? model.meta.poster) {
            guard style.mood else { return }
            CinematicMood.shared.color = await CinematicMood.color(fromURL: model.meta.background ?? model.meta.poster)
        }
        .onDisappear { CinematicMood.shared.color = CinematicMood.shared.homeColor }
        .sheet(isPresented: $posterPicker) { PosterPickerSheet(meta: model.meta) }
        .sheet(item: $picker) { request in
            StreamPickerSheet(request: request)
        }
        .sheet(item: $episodeDetailsRequest) { request in
            EpisodeDetailsSheet(meta: model.meta, video: request.video)
        }
        .navigationDestination(item: $openedSimilar) { DetailView(route: $0) }
        .navigationDestination(item: $openedPerson) { PersonFilmographyView(route: $0) }
        .alert("Titolo non disponibile", isPresented: Binding(get: { similarProblem != nil }, set: { if !$0 { similarProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(similarProblem ?? "")
        }
        .accessibilityIdentifier("detail.screen")
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urlString: model.meta.background ?? model.meta.poster, width: 900, placeholderSeed: model.meta.name)
                .frame(maxWidth: .infinity)
                .frame(height: style.cinematic ? 470 : 330)
                .scaleEffect(style.cinematic && style.motion && !reduceMotion && zoomed ? 1.2 : 1)
                .animation(style.motion && !reduceMotion ? .easeInOut(duration: 16) : nil, value: zoomed)
                .clipped()
                .onAppear { zoomed = true }
                // Cinematic: the artwork itself dissolves into the page (a mask), so the film's colours flow into the background
                // with no seam; the classic header keeps its fade to the system background.
                .mask(
                    LinearGradient(stops: style.cinematic
                                   ? [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)]
                                   : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    LinearGradient(colors: [.clear, Color(UIColor.systemBackground).opacity(0.0), Color(UIColor.systemBackground).opacity(style.cinematic ? 0 : 0.95)],
                                   startPoint: .top, endPoint: .bottom)
                )
            HStack(alignment: .bottom, spacing: 14) {
                RemoteImage(urlString: posterOverrides.url(for: model.meta.id) ?? model.meta.poster, width: 220, placeholderSeed: model.meta.name)
                    .frame(width: 104, height: 104 / CGFloat(model.meta.posterShape.aspectRatio))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.meta.name)
                        .font(.aetherTitle(26))
                        .lineLimit(3)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("detail.title")
                    metaLine
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.bottom, 4)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            if let year = model.meta.releaseInfo { Text(year) }
            if let runtime = model.meta.runtime { Text("· \(runtime)") }
            if let rating = model.meta.imdbRating { Label(rating, systemImage: "star.fill").labelStyle(.titleAndIcon).foregroundStyle(.yellow) }
        }
        .font(.system(.footnote, design: AetherTypography.design).weight(.medium))
        .foregroundStyle(Color.aetherSecondary)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    startPlayback(video: model.primaryVideo())
                } label: {
                    Label(model.primaryButtonTitle(), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(model.isLoading && model.meta.videos.isEmpty && model.isSeries)
                .accessibilityIdentifier("detail.play")

                Button {
                    library.toggleWatchlist(model.meta)
                } label: {
                    Image(systemName: library.watchlistIDs.contains(model.meta.id) ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .aetherGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(library.watchlistIDs.contains(model.meta.id) ? "Rimuovi dalla watchlist" : "Aggiungi alla watchlist")
                .accessibilityIdentifier("detail.watchlist")

                trailerButton
            }
            if !model.canPlay && !model.isLoading {
                Label("Nessun addon attivo fornisce sorgenti per questo titolo.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
        }
        .padding(.horizontal, Theme.pageMargin)
    }

    private func startPlayback(video: Video?) {
        picker = StreamPickerRequest(meta: model.meta, video: video, resumeAt: nil)
    }

    /// Queues the selected season using one consistent language/quality policy.
    /// A missing source only skips that episode; it never aborts the rest of the season.
    private func downloadSelectedSeason() async {
        guard !isDownloadingSeason, let season = model.selectedSeason else { return }
        let episodes = model.meta.videos(inSeason: season)
            .filter { ($0.released ?? .distantPast) <= Date() }
            .sorted { ($0.episode ?? Int.max) < ($1.episode ?? Int.max) }
        guard !episodes.isEmpty else {
            seasonDownloadMessage = "Non ci sono episodi già disponibili in questa stagione."
            return
        }
        guard !model.meta.isLive else {
            seasonDownloadMessage = "Il download di una stagione non è disponibile per i contenuti live."
            return
        }

        isDownloadingSeason = true
        isCancellingSeasonDownload = false
        seasonDownloadMessage = "Cerco sorgenti per \(episodes.count) episodi…"
        defer {
            isDownloadingSeason = false
            isCancellingSeasonDownload = false
            seasonDownloadTask = nil
            seasonBatchDownloadIDs.removeAll()
        }

        let storage = settings.value.storage
        var preferences = env.streamPreferences()
        preferences.qualityCap = storage.seasonDownloadQuality
        if storage.seasonDownloadSizePolicy == .preferSmaller && storage.seasonDownloadQuality == .auto {
            preferences.qualityCap = .p1080
        }
        let languageSetting = storage.seasonDownloadLanguage
        if languageSetting == "any" {
            preferences.preferredLanguage = nil
            preferences.preferLanguage = false
        } else if languageSetting == "preferred" {
            preferences.preferredLanguage = SettingsStore.resolvedLanguage(settings.value.playback.preferredAudioLanguage)
            preferences.preferLanguage = preferences.preferredLanguage != nil
        } else {
            preferences.preferredLanguage = languageSetting
            preferences.preferLanguage = true
        }

        var targetLanguage = preferences.preferredLanguage.map(normalizeSeasonLanguage)
        var targetHeight: Int?
        var queued = 0
        var skipped = 0
        var alreadyPresent = 0
        let allowLocal = settings.value.privacy.allowLocalNetwork

        for (index, video) in episodes.enumerated() {
            if Task.isCancelled { break }
            seasonDownloadMessage = "Cerco sorgenti · episodio \(index + 1) di \(episodes.count)…"
            if let existing = env.downloads.item(metaID: model.meta.id, videoID: video.id), existing.state != .failed {
                alreadyPresent += 1
                continue
            }

            // Always query the configured addons, even when metadata embeds streams: embedded
            // lists can be partial and may omit the matching-language release from another addon.
            let disabledAddonIDs = Set(storage.seasonDownloadDisabledAddonIDs)
            var episodeStreams = video.streams.filter { stream in
                guard let addonID = stream.addonID else { return true }
                return !disabledAddonIDs.contains(addonID)
            }
            let fetchedStreams = await env.service.allStreams(type: model.meta.type, videoID: video.id).streams
                .filter { stream in
                    guard let addonID = stream.addonID else { return true }
                    return !disabledAddonIDs.contains(addonID)
                }
            if Task.isCancelled { break }
            for stream in fetchedStreams where !episodeStreams.contains(stream) {
                episodeStreams.append(stream)
            }
            await env.diagnostics.log(.info, "season-download",
                "Ricerca episodio \(index + 1)/\(episodes.count): titolo=\(model.meta.name), file=\(video.title), videoID=\(video.id), stagione=\(video.season.map(String.init) ?? "?"), episodio=\(video.episode.map(String.init) ?? "?"), sorgentiRicevute=\(episodeStreams.count)")
            for (sourceIndex, source) in episodeStreams.enumerated() {
                let kind: String
                switch source.source {
                case .torrent(let infoHash, let fileIndex, _): kind = "torrent hash=\(infoHash) fileIndex=\(fileIndex.map(String.init) ?? "?")"
                case .url(let raw): kind = "url host=\(URL(string: raw)?.host ?? "non-valido")"
                case .youtube: kind = "youtube"
                case .external: kind = "external"
                case .playerFrame: kind = "playerFrame"
                case .archive(let archive): kind = "archive:\(archive)"
                case .unknown: kind = "unknown"
                }
                await env.diagnostics.log(.info, "season-download",
                    "Sorgente \(sourceIndex + 1)/\(episodeStreams.count): addon=\(source.addonName ?? source.addonID ?? "sconosciuto"), tipo=\(kind), nomeFile=\(source.behaviorHints.filename ?? "n/d"), nome=\(source.name ?? "n/d"), dettagli=\(source.details ?? "n/d"), bytes=\(source.behaviorHints.videoSize.map(String.init) ?? "n/d")")
            }
            let ranked = StreamSelector.rank(episodeStreams, preferences: preferences)
            // Torrent sources are marked unsupported by the playback analyzer without a local streaming server.
            // For season downloads TorBox resolves torrents, so do not discard them when debrid is configured.
            let playable = ranked.filter { item in
                if item.info.support.isPlayable { return true }
                if env.debrid.isConfigured, case .torrent = item.stream.source { return true }
                return false
            }
            await env.diagnostics.log(.info, "season-download",
                "Analisi sorgenti: ricevute=\(episodeStreams.count), candidateUtilizzabili=\(playable.count), debridConfigurato=\(env.debrid.isConfigured), lingua=\(storage.seasonDownloadLanguage), qualitàMax=\(preferences.qualityCap.maxHeight)")
            guard !playable.isEmpty else {
                await env.diagnostics.log(.warning, "season-download", "Nessuna sorgente utilizzabile per \(video.title): verificare risposta addon, filtri lingua/qualità e configurazione TorBox.")
                skipped += 1
                continue
            }

            // Inspect every playable source before choosing. If a source explicitly matches the
            // configured language, prefer that pool; otherwise keep the episode downloadable by
            // falling back to the normal ranked pool rather than silently skipping the episode.
            let requiredLanguage = targetLanguage
            let matchingLanguageStreams: [RankedStream]
            if let requiredLanguage {
                matchingLanguageStreams = playable.filter { item in
                    seasonLanguagesEvidence(for: item).contains(requiredLanguage)
                }
            } else {
                matchingLanguageStreams = []
            }
            let languageMatches = matchingLanguageStreams.isEmpty ? playable : matchingLanguageStreams

            // Apply the selected quality cap strictly: do not silently fall back to a release above it.
            let maxHeight = preferences.qualityCap.maxHeight
            let withinCap = languageMatches.filter { $0.info.quality.height == 0 || $0.info.quality.height <= maxHeight }
            guard !withinCap.isEmpty else {
                skipped += 1
                continue
            }
            if targetHeight == nil {
                targetHeight = withinCap.first(where: { $0.info.quality.height > 0 })?.info.quality.height
            }
            let consistentQuality = withinCap.filter { item in
                guard let targetHeight, item.info.quality.height > 0 else { return true }
                return item.info.quality.height <= targetHeight
            }
            let pool = consistentQuality.isEmpty ? withinCap : consistentQuality
            let orderedCandidates: [RankedStream]
            if storage.seasonDownloadSizePolicy == .preferSmaller {
                orderedCandidates = pool.sorted { lhs, rhs in
                    let left = lhs.info.sizeBytes ?? Int64.max
                    let right = rhs.info.sizeBytes ?? Int64.max
                    if left != right { return left < right }
                    return lhs.score > rhs.score
                }
            } else {
                orderedCandidates = pool.sorted { $0.score > $1.score }
            }
            guard !orderedCandidates.isEmpty else {
                skipped += 1
                continue
            }

            // Validate candidates sequentially. A failed provider/API resolution or an ineligible
            // URL moves to the next source for this same episode; only a successfully resolved
            // and enqueued candidate ends the search.
            var episodeQueued = false
            for (candidateIndex, candidate) in orderedCandidates.enumerated() {
                if Task.isCancelled { break }
                do {
                    let stream = candidate.stream
                    let enqueueError: String?
                    if case .torrent = stream.source {
                        guard env.debrid.isConfigured,
                              let request = DebridRequest(stream: stream, stremioID: video.id, mode: .startIfNeeded) else {
                            continue
                        }
                        // Respect the provider selected in Settings > Services > Torrent provider.
                        let resolution = try await env.debrid.resolve(request, onProgress: nil)
                        if Task.isCancelled { break }
                        let resolvedStream = resolution.playableStream(from: stream)
                        enqueueError = await env.downloads.enqueue(meta: model.meta, video: video, stream: resolvedStream,
                                                                    allowLocalNetwork: allowLocal, ephemeralURL: resolution.url)
                    } else {
                        enqueueError = await env.downloads.enqueue(meta: model.meta, video: video, stream: stream,
                                                                    allowLocalNetwork: allowLocal)
                    }
                    if enqueueError == nil {
                        queued += 1
                        trackSeasonDownload(videoID: video.id)
                        // Keep direct HTTP(S) alternatives ready so a later HTTP/provider failure can
                        // switch sources without restarting the whole season search.
                        let fallbacks = orderedCandidates.dropFirst(candidateIndex + 1).compactMap { alternate -> SeasonDownloadFallback? in
                            guard case .url(let rawURL) = alternate.stream.source,
                                  let url = URL(string: rawURL),
                                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                            return SeasonDownloadFallback(
                                url: url,
                                headers: alternate.stream.behaviorHints.proxyRequestHeaders,
                                container: alternate.info.container,
                                totalBytes: alternate.info.sizeBytes ?? alternate.stream.behaviorHints.videoSize ?? 0
                            )
                        }
                        if !fallbacks.isEmpty,
                           let item = env.downloads.item(metaID: model.meta.id, videoID: video.id) {
                            env.downloads.setSeasonFallbacks(for: item.id, candidates: fallbacks)
                        }
                        episodeQueued = true
                        break
                    }
                    // Unsupported source / provider resolution refusal: test the next ranked source.
                } catch {
                    // A source-specific failure is not an episode failure; try the next candidate.
                    continue
                }
            }
            if !episodeQueued { skipped += 1 }
        }

        if Task.isCancelled {
            seasonDownloadMessage = "Download stagione annullato. I file già completati sono stati conservati."
            return
        }

        var summary = "Download stagione: \(queued) episodi accodati"
        if alreadyPresent > 0 { summary += ", \(alreadyPresent) già presenti" }
        if skipped > 0 { summary += ", \(skipped) non disponibili o non compatibili" }
        summary += "."
        seasonDownloadMessage = summary
    }

    private func trackSeasonDownload(videoID: String) {
        guard let item = env.downloads.item(metaID: model.meta.id, videoID: videoID) else { return }
        seasonBatchDownloadIDs.insert(item.id)
        // If cancellation raced with an enqueue, remove the just-created item too.
        if Task.isCancelled { env.downloads.remove(item.id) }
    }

    private func cancelSeasonDownload() {
        guard isDownloadingSeason, !isCancellingSeasonDownload else { return }
        isCancellingSeasonDownload = true
        seasonDownloadMessage = "Annullamento del download della stagione…"
        seasonDownloadTask?.cancel()
        for id in seasonBatchDownloadIDs {
            if let item = env.downloads.items.first(where: { $0.id == id }), item.state != .completed {
                env.downloads.remove(id)
            }
        }
        seasonBatchDownloadIDs.removeAll()
    }

    /// Collect every language explicitly indicated by addon metadata and release title.
    /// Stream titles often contain multiple audio tags (for example ITA.ENG), so preserve all of them.
    private func seasonLanguagesEvidence(for item: RankedStream) -> Set<String> {
        var languages = Set<String>()
        for rawLanguage in item.info.languages {
            languages.insert(normalizeSeasonLanguage(rawLanguage))
        }
        for language in ReleaseLanguageDetector.languages(in: item.stream.searchableText) {
            languages.insert(normalizeSeasonLanguage(language))
        }
        return languages
    }

    private func normalizeSeasonLanguage(_ raw: String) -> String {
        switch raw.lowercased() {
        case "ita", "italian": return "it"
        case "eng", "english": return "en"
        case "fra", "fre", "french": return "fr"
        case "spa", "spanish": return "es"
        case "deu", "ger", "german": return "de"
        case "por", "portuguese": return "pt"
        default: return raw.lowercased()
        }
    }

    // MARK: Info

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.meta.genres.isEmpty { GenreChips(genres: model.meta.genres) }
            if let description = model.meta.description, !description.isEmpty {
                Text(description)
                    .font(.body)
                    .lineLimit(descriptionExpanded ? nil : 5)
                    .onTapGesture { withAnimation { descriptionExpanded.toggle() } }
                    .accessibilityHint(descriptionExpanded ? "Tocca per ridurre" : "Tocca per leggere tutto")
            } else if model.isLoading {
                SkeletonBlock(cornerRadius: 6).frame(height: 70)
            }
            HStack(spacing: 16) {
                if let language = model.meta.language { infoPill("Lingua", language) }
                if let country = model.meta.country { infoPill("Paese", country) }
                if let awards = model.meta.awards { infoPill("Premi", awards) }
            }
        }
        .padding(.horizontal, Theme.pageMargin)
    }

    private func infoPill(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Color.aetherSecondary)
            Text(value).font(.caption.weight(.semibold)).lineLimit(2)
        }
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 8) {
            let directors = model.meta.directors
            if !directors.isEmpty {
                creditLine("Regia", directors)
            } else if let creators = model.rich?.creators, !creators.isEmpty {
                creditLine("Creato da", creators)
            }
            // With photos available the cast is a row of faces instead of a line of names.
            if !model.meta.cast.isEmpty, model.rich?.cast.isEmpty != false {
                creditLine("Cast", Array(model.meta.cast.prefix(12)))
            }
        }
        .padding(.horizontal, Theme.pageMargin)
    }

    /// The film button next to Play: one trailer opens directly, several open a menu to choose from.
    @ViewBuilder
    private var trailerButton: some View {
        let links = model.trailerLinks
        if links.count > 1 {
            Menu {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button(link.title) { openURL(link.url) }
                }
            } label: {
                trailerIcon
            }
            .foregroundStyle(Color.primary)
            .accessibilityLabel("Guarda un trailer su YouTube")
            .accessibilityIdentifier("detail.trailerMenu")
        } else if let link = links.first {
            Button {
                openURL(link.url)
            } label: {
                trailerIcon
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Guarda il trailer su YouTube")
            .accessibilityIdentifier("detail.trailer")
        }
    }

    private var trailerIcon: some View {
        Image(systemName: "film")
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 48, height: 48)
            .aetherGlass(in: Circle(), interactive: true)
    }

    // MARK: TMDB sections

    @ViewBuilder
    private var richSections: some View {
        if let rich = model.rich {
            let modules = env.settings.value.content.titleModules
            let shown = env.settings.value.content.ratings
            let chosen = model.ratings.filter { shown.sources.contains($0.source) && $0.display != nil }
            if !chosen.isEmpty { TitleRatingsSection(ratings: chosen) }
            if !rich.cast.isEmpty && modules.cast {
                TitleCastSection(people: rich.cast) { person in
                    if let id = person.tmdbPersonID { openedPerson = PersonRoute(personID: id, name: person.name) }
                }
            }
            if !rich.trailers.isEmpty && modules.trailers { TitleTrailersSection(trailers: rich.trailers) }
            if !model.sagaFilms.isEmpty, let saga = rich.collection {
                TitleSimilarSection(titles: model.sagaFilms, heading: saga.name, identifier: "detail.saga", open: openSimilar)
            }
            if !rich.companies.isEmpty && modules.companies { TitleCompaniesSection(companies: rich.companies) }
            if (rich.budget != nil || rich.revenue != nil) && modules.financials { TitleFinancialsSection(budget: rich.budget, revenue: rich.revenue) }
            let rows = rich.detailRows()
            if !rows.isEmpty && modules.facts { TitleFactsSection(rows: rows) }
            if !rich.similar.isEmpty && modules.similar { TitleSimilarSection(titles: similarTitles(rich), open: openSimilar) }
        } else if model.suggestsTMDBKey {
            TMDBKeyHint()
        }
    }

    /// The similar titles, without the talk shows when the viewer asked for that here.
    private func similarTitles(_ rich: TitleRichDetails) -> [TitleRichDetails.Similar] {
        guard settings.value.content.hiddenTalkScopes.contains(.similar) else { return rich.similar }
        return rich.similar.filter { !($0.genreIDs ?? []).contains(TalkShowFilter.tmdbGenre) }
    }

    /// A similar title is known to TMDB by its own id; the catalog knows it by its IMDb id, which has to be asked for first.
    private func openSimilar(_ item: TitleRichDetails.Similar) {
        guard !lookingUpSimilar else { return }
        lookingUpSimilar = true
        let type = model.meta.type
        Task {
            defer { lookingUpSimilar = false }
            guard let imdb = await env.metadata.imdbID(forTMDBID: item.tmdbID, metaType: type) else {
                similarProblem = "Aether non riesce a trovare «\(item.title)» negli addon: TMDB non indica il suo codice IMDb oppure non risponde. Controlla la connessione e riprova."
                return
            }
            let preview = MetaItem(id: imdb, type: type, name: item.title, poster: item.posterURL)
            openedSimilar = MetaRoute(type: type, id: imdb, preview: preview)
        }
    }

    private func creditLine(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.aetherHeadline())
            Text(names.joined(separator: ", ")).font(.subheadline).foregroundStyle(Color.aetherSecondary)
        }
    }

    // MARK: Episodes

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodi").font(.aetherTitle(22)).accessibilityAddTraits(.isHeader)
                Spacer()
                if model.meta.seasons.count > 1 {
                    Menu {
                        ForEach(model.meta.seasons, id: \.self) { season in
                            Button(season == 0 ? "Speciali" : "Stagione \(season)") { model.selectedSeason = season }
                        }
                    } label: {
                        Label(seasonTitle(model.selectedSeason), systemImage: "chevron.up.chevron.down")
                            .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .aetherGlassCapsule(interactive: true)
                    }
                    .accessibilityIdentifier("detail.seasonMenu")
                }
                if model.selectedSeason != nil, !model.visibleEpisodes.isEmpty {
                    if isDownloadingSeason {
                        Button(action: cancelSeasonDownload) {
                            Label(isCancellingSeasonDownload ? "Annullamento…" : "Annulla",
                                  systemImage: isCancellingSeasonDownload ? "hourglass" : "xmark.circle")
                                .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .aetherGlassCapsule(interactive: !isCancellingSeasonDownload)
                        }
                        .buttonStyle(.plain)
                        .disabled(isCancellingSeasonDownload)
                        .accessibilityIdentifier("detail.cancelSeasonDownload")
                    } else {
                        Button {
                            seasonBatchDownloadIDs.removeAll()
                            isCancellingSeasonDownload = false
                            seasonDownloadTask = Task { await downloadSelectedSeason() }
                        } label: {
                            Label("Scarica", systemImage: "arrow.down.circle")
                                .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .aetherGlassCapsule(interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Scarica \(seasonTitle(model.selectedSeason).lowercased())")
                        .accessibilityIdentifier("detail.downloadSeason")
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)

            if let message = seasonDownloadMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.aetherSecondary)
                    .padding(.horizontal, Theme.pageMargin)
                    .accessibilityIdentifier("detail.downloadSeasonStatus")
            }

            if let season = model.selectedSeason, model.visibleEpisodes.count > 1 {
                Button {
                    Task {
                        let allWatched = model.visibleEpisodes.allSatisfy { model.watchedIDs.contains($0.id) }
                        await env.libraryStore.markWatched(!allWatched, meta: model.meta, videos: model.visibleEpisodes)
                        await model.refreshLibraryState(env: env)
                    }
                } label: {
                    let allWatched = model.visibleEpisodes.allSatisfy { model.watchedIDs.contains($0.id) }
                    Label(allWatched ? "Segna \(seasonTitle(season).lowercased()) come non vista" : "Segna \(seasonTitle(season).lowercased()) come vista",
                          systemImage: allWatched ? "eye.slash" : "checkmark.circle")
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, Theme.pageMargin)
            }

            LazyVStack(spacing: 10) {
                ForEach(model.visibleEpisodes) { video in
                    EpisodeRow(video: video,
                               isWatched: model.watchedIDs.contains(video.id),
                               progress: model.progress[video.id],
                               isFuture: (video.released ?? .distantPast) > Date()) {
                        startPlayback(video: video)
                    } toggleWatched: {
                        Task {
                            let watched = model.watchedIDs.contains(video.id)
                            await env.libraryStore.markWatched(!watched, meta: model.meta, video: video)
                            await model.refreshLibraryState(env: env)
                        }
                    } showDetails: {
                        episodeDetailsRequest = EpisodeDetailsRequest(video: video)
                    }
                    .accessibilityIdentifier("episode.\(video.id)")
                }
            }
            .padding(.horizontal, Theme.pageMargin)
        }
    }

    private func seasonTitle(_ season: Int?) -> String {
        guard let season = season else { return "Stagione" }
        return season == 0 ? "Speciali" : "Stagione \(season)"
    }

    private var failureNote: some View {
        InlineErrorView(message: "I dettagli completi non sono disponibili: \(model.failures.first?.message ?? "errore")") {
            Task { await model.load(env: env, mode: .reload) }
        }
    }

    private var footer: some View {
        Group {
            if let provider = model.providerName {
                Text("Metadati forniti da \(provider)").font(.caption).foregroundStyle(Color.aetherSecondary)
            } else if !model.hadDetailProvider && !model.isLoading {
                Text("Nessun addon fornisce i dettagli di questo titolo: mostro solo le informazioni del catalogo.")
                    .font(.caption).foregroundStyle(Color.aetherSecondary)
            }
            if model.rich != nil {
                TMDBAttributionView()
            }
            // The credits of the other services (and TMDB's own when there is no page section carrying it).
            ForEach(model.attributions.filter { model.rich == nil || $0 != MetadataService.tmdb.attribution }, id: \.self) { line in
                Text(line).font(.caption2).foregroundStyle(Color.aetherSecondary)
            }
        }
        .padding(.horizontal, Theme.pageMargin)
    }
}

struct EpisodeRow: View {
    let video: Video
    let isWatched: Bool
    let progress: PlaybackProgress?
    let isFuture: Bool
    let play: () -> Void
    let toggleWatched: () -> Void
    let showDetails: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    RemoteImage(urlString: video.thumbnail, width: 220, placeholderSeed: video.id, systemPlaceholder: "play.rectangle")
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if let progress = progress, !progress.isCompleted, progress.fraction > 0 {
                        ProgressBar(value: progress.fraction, height: 3).padding(6)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let episode = video.episode { Text("\(episode).").foregroundStyle(Color.aetherSecondary) }
                        Text(video.title.isEmpty ? "Episodio" : video.title).lineLimit(2)
                    }
                    .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                    if let overview = video.overview, !overview.isEmpty {
                        Text(overview).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(2)
                    }
                    if isFuture, let released = video.released {
                        Text("Esce il \(released.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                if isWatched {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Visto")
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isFuture ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .contextMenu {
            Button(action: showDetails) {
                Label("Trama completa e voti", systemImage: "text.alignleft")
            }
            Button(action: toggleWatched) {
                Label(isWatched ? "Segna come non visto" : "Segna come visto", systemImage: isWatched ? "eye.slash" : "checkmark.circle")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Scegli la sorgente e riproduci")
    }
}

private struct EpisodeDetailsRequest: Identifiable {
    let video: Video
    var id: String { video.id }
}

private struct EpisodeDetailsSheet: View {
    let meta: MetaItem
    let video: Video
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var details: EpisodeRichDetails?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(video.episodeLabel.map { "\($0) · \(details?.title ?? video.title)" } ?? (details?.title ?? video.title))
                        .font(.aetherTitle(24))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let rating = details?.tmdbRating, rating > 0 {
                        Label(String(format: "TMDB %.1f/10", rating), systemImage: "star.fill")
                            .font(.headline).foregroundStyle(.yellow)
                    }
                    if let imdbID = details?.imdbID, let url = URL(string: "https://www.imdb.com/title/\(imdbID)/") {
                        Button { openURL(url) } label: {
                            Label("Apri la puntata su IMDb", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Trama completa").font(.headline)
                    Text(details?.overview?.isEmpty == false ? details!.overview! : (video.overview?.isEmpty == false ? video.overview! : "La trama completa non è disponibile."))
                        .font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if details?.tmdbRating == nil && details?.imdbID == nil {
                        Text(isLoading ? "Recupero dettagli da TMDB…" : "TMDB non ha restituito altri dettagli. Controlla che la chiave TMDB sia configurata in Impostazioni > Servizi.")
                            .font(.footnote).foregroundStyle(Color.aetherSecondary)
                    }
                    Text("I voti mostrati qui provengono da TMDB. L'ID IMDb viene aggiunto quando disponibile; il punteggio IMDb richiede una fonte/API IMDb dedicata.")
                        .font(.caption2).foregroundStyle(Color.aetherSecondary)
                }
                .padding(20)
            }
            .navigationTitle("Dettagli episodio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() } } }
        }
        .task(id: video.id) {
            let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
            details = await env.metadata.episodeDetails(for: meta, video: video, language: language)
            isLoading = false
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
