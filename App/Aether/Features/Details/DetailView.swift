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
        await enrich(env: env)
    }

    /// Adds what the user's own TMDB / TheTVDB keys know to the addon's meta, filling only what the addon left empty.
    /// Silent: without a key, or when a service does not answer, the meta stays as the addon provided it.
    private func enrich(env: AppEnvironment) async {
        let base = meta
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        guard let enrichment = await env.metadata.enrich(base, language: language), !Task.isCancelled, meta.id == base.id else { return }
        attributions = enrichment.attributions(whenMergedInto: base)
        meta = base.merging(enrichment: enrichment)
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
    @StateObject private var model: DetailViewModel
    @State private var picker: StreamPickerRequest?
    @State private var descriptionExpanded = false

    init(route: MetaRoute) {
        self.route = route
        _model = StateObject(wrappedValue: DetailViewModel(route: route))
    }

    var body: some View {
        ZStack {
            AetherBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    actions
                    infoBlock
                    if model.isSeries { episodes }
                    if !model.meta.cast.isEmpty || !model.meta.directors.isEmpty { credits }
                    if !model.failures.isEmpty && model.hadDetailProvider && model.providerName == nil { failureNote }
                    footer
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { library.toggleFavorite(model.meta) } label: {
                    Image(systemName: library.favoriteIDs.contains(model.meta.id) ? "heart.fill" : "heart")
                }
                .accessibilityLabel(library.favoriteIDs.contains(model.meta.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")
                .accessibilityIdentifier("detail.favorite")
            }
        }
        .task(id: network.reconnectToken) { await model.load(env: env) }
        .sheet(item: $picker) { request in
            StreamPickerSheet(request: request)
        }
        .accessibilityIdentifier("detail.screen")
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urlString: model.meta.background ?? model.meta.poster, width: 900, placeholderSeed: model.meta.name)
                .frame(maxWidth: .infinity)
                .frame(height: 330)
                .clipped()
                .overlay(
                    LinearGradient(colors: [.clear, Color(UIColor.systemBackground).opacity(0.0), Color(UIColor.systemBackground).opacity(0.95)],
                                   startPoint: .top, endPoint: .bottom)
                )
            HStack(alignment: .bottom, spacing: 14) {
                RemoteImage(urlString: model.meta.poster, width: 220, placeholderSeed: model.meta.name)
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
        .font(.system(.footnote, design: .rounded).weight(.medium))
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

                if let trailer = model.meta.trailers.first, let url = trailer.watchURL {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "film")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 48, height: 48)
                            .aetherGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Guarda il trailer su YouTube")
                }
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
            if !model.meta.directors.isEmpty {
                creditLine("Regia", model.meta.directors)
            }
            if !model.meta.cast.isEmpty {
                creditLine("Cast", Array(model.meta.cast.prefix(12)))
            }
        }
        .padding(.horizontal, Theme.pageMargin)
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
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .aetherGlassCapsule(interactive: true)
                    }
                    .accessibilityIdentifier("detail.seasonMenu")
                }
            }
            .padding(.horizontal, Theme.pageMargin)

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
            ForEach(model.attributions, id: \.self) { line in
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
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
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
            Button(action: toggleWatched) {
                Label(isWatched ? "Segna come non visto" : "Segna come visto", systemImage: isWatched ? "eye.slash" : "checkmark.circle")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Scegli la sorgente e riproduci")
    }
}
