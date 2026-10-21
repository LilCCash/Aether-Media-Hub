import SwiftUI
import AetherCore

struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = HomeViewModel()
    @State private var showingInstall = false
    @State private var showingCast = false

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                content
            }
            .sheet(isPresented: $showingCast) {
                CastSheet()
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingCast = true
                    } label: {
                        Image(systemName: "tv.and.mediabox")
                    }
                    .accessibilityLabel("Trasmetti su un dispositivo")
                    .accessibilityIdentifier("home.cast")
                }
            }
            .navigationDestination(for: MetaRoute.self) { route in
                DetailView(route: route)
            }
            .refreshable { await model.reload(env: env, mode: .reload) }
            .task(id: ReloadKey(revision: addons.revision, token: network.reconnectToken)) {
                await model.reload(env: env, mode: .normal)
            }
            .sheet(isPresented: $showingInstall) {
                AddonInstallSheet(prefill: KnownAddons.cinemetaManifestURL.absoluteString)
            }
        }
    }

    private struct ReloadKey: Equatable {
        var revision: Int
        var token: Int
    }

    @ViewBuilder
    private var content: some View {
        if addons.enabledAddons.isEmpty {
            ScrollView {
                VStack(spacing: 24) {
                    OfflineBanner()
                    EmptyStateView(systemImage: "puzzlepiece.extension",
                                   title: "Nessun addon installato",
                                   message: "Aether mostra contenuti solo tramite addon compatibili con il protocollo Stremio. Installa il tuo primo addon per riempire Home e Scopri.",
                                   actionTitle: "Installa Cinemeta (consigliato)",
                                   action: { showingInstall = true })
                    Button("Aggiungi un addon da URL") { router.tab = .more }
                        .buttonStyle(SecondaryActionButtonStyle())
                    Text("Aether non fornisce contenuti né addon preinstallati. Cinemeta è il catalogo di metadati ufficiale di Stremio.")
                        .font(.footnote).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 40)
            }
            .accessibilityIdentifier("home.empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26, pinnedViews: []) {
                    OfflineBanner().frame(maxWidth: .infinity)
                    if settings.value.appearance.greetingEnabled {
                        greeting
                    }
                    ForEach(settings.value.appearance.homeSections.filter { $0.isVisible }) { section in
                        sectionView(for: section.id)
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .accessibilityIdentifier("home.scroll")
        }
    }

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        return Text(Greeting.text(hour: hour, name: settings.value.appearance.greetingName))
            .font(.aetherTitle(26))
            .padding(.horizontal, Theme.pageMargin)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home.greeting")
    }

    @ViewBuilder
    private func sectionView(for id: String) -> some View {
        let appearance = settings.value.appearance
        let config = appearance.section(id)
        let style = config.effectiveStyle ?? .poster
        let size = config.effectiveSize(general: appearance.posterSize)
        switch id {
        case HomeSectionConfig.hero:
            if !model.heroItems.isEmpty {
                HeroCarousel(items: model.heroItems, style: appearance.heroStyle)
            }
        case HomeSectionConfig.continueWatching:
            if !library.continueWatching.isEmpty {
                ContinueWatchingRow(items: library.continueWatching, style: style, size: size)
            }
        case HomeSectionConfig.nextUp:
            if !model.nextUp.isEmpty {
                NextUpRow(items: model.nextUp, style: style, size: size)
            }
        case HomeSectionConfig.watchlist:
            if !library.watchlist.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "La mia watchlist")
                    PosterRowView(items: library.watchlist.map { $0.asMeta }, watchlistIDs: library.watchlistIDs, style: style, size: size)
                }
            }
        case HomeSectionConfig.catalogs:
            ForEach(model.catalogRefs) { ref in
                CatalogRowView(ref: ref, style: style, size: size)
                    .id("\(ref.id)#\(addons.revision)#\(network.reconnectToken)")
            }
        default:
            EmptyView()
        }
    }
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var catalogRefs: [CatalogRef] = []
    @Published private(set) var heroItems: [MetaItem] = []
    @Published private(set) var nextUp: [NextUpItem] = []

    struct NextUpItem: Identifiable {
        var id: String { video.id }
        var meta: MetaItem
        var video: Video
    }

    func reload(env: AppEnvironment, mode: AddonClient.LoadMode) async {
        let handles = await env.addons.handles()
        var refs = RequestPlanner.feedCatalogs(handles: handles)
        if env.settings.value.content.hideAdultCatalogs {
            let adultAddons = Set(handles.filter { $0.addon.manifest.behaviorHints.adult }.map { $0.addon.id })
            refs.removeAll(where: { adultAddons.contains($0.addonID) })
        }
        catalogRefs = refs
        await loadHero(env: env, refs: refs, mode: mode)
        await loadNextUp(env: env)
    }

    private func loadHero(env: AppEnvironment, refs: [CatalogRef], mode: AddonClient.LoadMode) async {
        // Prefer a movie/series catalog; the first one that yields items with artwork feeds the carousel.
        let preferred = refs.filter { $0.type == ContentType.movie || $0.type == ContentType.series }
        for ref in (preferred.isEmpty ? refs : preferred).prefix(3) {
            if Task.isCancelled { return }
            if let result = try? await env.service.catalog(ref, mode: mode) {
                let candidates = result.items.filter { $0.background != nil || $0.poster != nil }.prefix(6)
                if !candidates.isEmpty {
                    heroItems = Array(candidates)
                    return
                }
            }
        }
        heroItems = []
    }

    private func loadNextUp(env: AppEnvironment) async {
        let seeds = await env.libraryStore.nextUpSeeds(limit: 8)
        var result: [NextUpItem] = []
        for seed in seeds {
            if Task.isCancelled { return }
            let resolution = await env.service.meta(type: seed.type, id: seed.metaID, fallback: seed.asMeta)
            let watched = await env.libraryStore.watchedVideoIDs(metaID: seed.metaID)
            if let next = NextEpisodeResolver.nextUnwatched(after: seed.videoID, in: resolution.meta, watched: watched) {
                result.append(NextUpItem(meta: resolution.meta, video: next))
            }
        }
        nextUp = result
    }
}

// MARK: - Catalog row

@MainActor
final class CatalogRowModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded([MetaItem])
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    let ref: CatalogRef
    private weak var env: AppEnvironment?

    init(ref: CatalogRef, env: AppEnvironment?) {
        self.ref = ref
        self.env = env
    }

    func load(force: Bool = false) async {
        guard let env = env else { return }
        switch state {
        case .loading: return
        case .loaded where !force: return
        default: break
        }
        state = .loading
        do {
            let result = try await env.service.catalog(ref, mode: force ? .reload : .normal)
            state = .loaded(result.items)
        } catch {
            if error is CancellationError { state = .idle; return }
            state = .failed((error as? AddonError)?.message ?? error.localizedDescription)
        }
    }
}

struct CatalogRowView: View {
    let ref: CatalogRef
    var style: HomeCardStyle = .poster
    var size: PosterSize = .medium
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        // The row model needs the environment, which is only available once the view is in the hierarchy.
        CatalogRowBody(ref: ref, style: style, size: size, env: env)
    }
}

private struct CatalogRowBody: View {
    let ref: CatalogRef
    let style: HomeCardStyle
    let size: PosterSize
    @StateObject private var model: CatalogRowModel
    @EnvironmentObject private var library: LibraryModel

    init(ref: CatalogRef, style: HomeCardStyle, size: PosterSize, env: AppEnvironment) {
        self.ref = ref
        self.style = style
        self.size = size
        _model = StateObject(wrappedValue: CatalogRowModel(ref: ref, env: env))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: ref.title, subtitle: subtitle)
                    SkeletonRow(posterWidth: HomeCardMetrics.width(style: style, size: size),
                                aspectRatio: HomeCardMetrics.aspectRatio(style: style))
                }
            case .loaded(let items):
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: ref.title, subtitle: subtitle)
                        PosterRowView(items: items, watchlistIDs: library.watchlistIDs, style: style, size: size)
                    }
                }
                // Empty catalogs collapse completely: no empty categories.
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: ref.title, subtitle: subtitle)
                    InlineErrorView(message: message) { Task { await model.load(force: true) } }
                }
            }
        }
        .task { await model.load() }
    }

    private var subtitle: String {
        "\(ref.addonName) · \(RequestPlanner.friendlyTypeName(ref.type))"
    }
}

struct PosterRowView: View {
    let items: [MetaItem]
    var watchlistIDs: Set<String> = []
    /// `.poster` (portrait) or `.landscape` (16:9); anything else is drawn as a poster.
    var style: HomeCardStyle = .poster
    /// `nil` follows the general poster size of the appearance settings.
    var size: PosterSize? = nil
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.imageLoader) private var loader
    @Environment(\.displayScale) private var scale

    private var isLandscape: Bool { style == .landscape }

    var body: some View {
        let width = HomeCardMetrics.width(style: isLandscape ? .landscape : .poster, size: size ?? settings.value.appearance.posterSize)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: settings.value.appearance.density == .compact ? 8 : 14) {
                ForEach(Array(items.prefix(60).enumerated()), id: \.offset) { offset, item in
                    NavigationLink(value: MetaRoute(meta: item)) {
                        if isLandscape {
                            MetaLandscapeCard(meta: item, width: width, isInWatchlist: watchlistIDs.contains(item.id))
                        } else {
                            PosterCard(meta: item, width: width, isInWatchlist: watchlistIDs.contains(item.id))
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear { prefetchAhead(from: offset, width: width) }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
        }
        .scrollClipDisabled()
    }

    /// Warm the next few pictures so fast scrolling does not show placeholders (bounded: 6 items). The one prefetched is the
    /// one the card draws: the backdrop for wide cards, the poster otherwise.
    private func prefetchAhead(from index: Int, width: CGFloat) {
        guard let loader = loader else { return }
        let upcoming = items.dropFirst(index + 1).prefix(6).compactMap { item -> URL? in
            guard let string = isLandscape ? (item.background ?? item.poster) : (item.poster ?? item.background) else { return nil }
            return URL.lenient(string)
        }
        guard !upcoming.isEmpty else { return }
        let pixels = Int((isLandscape ? max(280, width) : width) * scale)
        Task { await loader.prefetch(Array(upcoming), maxPixel: pixels) }
    }
}
