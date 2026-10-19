import SwiftUI
import AetherCore

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var types: [String] = []
    @Published var selectedType: String?
    @Published private(set) var catalogs: [CatalogRef] = []
    @Published private(set) var selectedCatalog: CatalogRef?
    @Published private(set) var genres: [String] = []
    @Published var selectedGenre: String?
    @Published private(set) var items: [MetaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isStale = false

    private var handles: [AddonHandle] = []
    private var pager: CatalogPager?
    private var loadTask: Task<Void, Never>?

    func reload(env: AppEnvironment) async {
        handles = await env.addons.handles()
        if env.settings.value.content.hideAdultCatalogs {
            let adult = Set(handles.filter { $0.addon.manifest.behaviorHints.adult }.map { $0.id })
            handles.removeAll(where: { adult.contains($0.id) })
        }
        types = RequestPlanner.availableTypes(handles: handles)
        if selectedType == nil || !types.contains(selectedType ?? "") { selectedType = types.first }
        updateCatalogs(env: env)
    }

    func select(type: String, env: AppEnvironment) {
        guard type != selectedType else { return }
        selectedType = type
        selectedGenre = nil
        updateCatalogs(env: env)
    }

    func select(catalog: CatalogRef, env: AppEnvironment) {
        selectedCatalog = catalog
        selectedGenre = nil
        genres = catalog.catalog.genreOptions
        restart(env: env)
    }

    func select(genre: String?, env: AppEnvironment) {
        selectedGenre = genre
        restart(env: env)
    }

    private func updateCatalogs(env: AppEnvironment) {
        guard let type = selectedType else {
            catalogs = []; selectedCatalog = nil; genres = []; items = []; hasMore = false; pager = nil
            return
        }
        catalogs = RequestPlanner.feedCatalogs(handles: handles, type: type)
        if let current = selectedCatalog, catalogs.contains(current) {
            // keep
        } else {
            selectedCatalog = catalogs.first
        }
        genres = selectedCatalog?.catalog.genreOptions ?? []
        restart(env: env)
    }

    func restart(env: AppEnvironment, mode: AddonClient.LoadMode = .normal) {
        loadTask?.cancel()
        items = []
        errorMessage = nil
        hasMore = false
        isStale = false
        guard let ref = selectedCatalog else { pager = nil; return }
        var extra: [ExtraValue] = []
        if let genre = selectedGenre { extra.append(ExtraValue(name: "genre", value: genre)) }
        let newPager = CatalogPager(ref: ref, service: env.service, extra: extra)
        pager = newPager
        loadTask = Task { await loadMore(mode: mode) }
    }

    func loadMore(mode: AddonClient.LoadMode = .normal) async {
        guard let pager = pager, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await pager.loadNext(mode: mode)
            if Task.isCancelled { return }
            items.append(contentsOf: page.newItems)
            hasMore = page.hasMore
            isStale = isStale || page.isStale
            errorMessage = nil
        } catch {
            if error is CancellationError { return }
            errorMessage = (error as? AddonError)?.message ?? error.localizedDescription
        }
    }

    func loadMoreIfNeeded(current item: MetaItem) async {
        guard hasMore, !isLoading, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if index >= items.count - 8 { await loadMore() }
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = DiscoverViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                VStack(spacing: 0) {
                    if !model.types.isEmpty { controls }
                    content
                }
            }
            .navigationTitle("Scopri")
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
            .task(id: "\(addons.revision)-\(network.reconnectToken)") { await model.reload(env: env) }
            .refreshable { model.restart(env: env, mode: .reload) }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.types, id: \.self) { type in
                        FilterChip(title: RequestPlanner.friendlyTypeName(type), isSelected: model.selectedType == type) {
                            model.select(type: type, env: env)
                        }
                        .accessibilityIdentifier("discover.type.\(type)")
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
            HStack(spacing: 10) {
                if model.catalogs.count > 1 {
                    Menu {
                        ForEach(model.catalogs) { ref in
                            Button("\(ref.title) · \(ref.addonName)") { model.select(catalog: ref, env: env) }
                        }
                    } label: {
                        menuLabel(model.selectedCatalog.map { "\($0.title)" } ?? "Catalogo", "list.bullet")
                    }
                    .accessibilityIdentifier("discover.catalogMenu")
                } else if let catalog = model.selectedCatalog {
                    Text("\(catalog.title) · \(catalog.addonName)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                if !model.genres.isEmpty {
                    Menu {
                        Button("Tutti i generi") { model.select(genre: nil, env: env) }
                        ForEach(model.genres, id: \.self) { genre in
                            Button(genre) { model.select(genre: genre, env: env) }
                        }
                    } label: {
                        menuLabel(model.selectedGenre ?? "Genere", "tag")
                    }
                    .accessibilityIdentifier("discover.genreMenu")
                }
                Spacer()
            }
            .padding(.horizontal, Theme.pageMargin)
        }
        .padding(.vertical, 8)
    }

    private func menuLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .aetherGlassCapsule(interactive: true)
    }

    @ViewBuilder
    private var content: some View {
        if model.types.isEmpty {
            ScrollView {
                EmptyStateView(systemImage: "square.grid.2x2",
                               title: "Niente da scoprire (ancora)",
                               message: "Scopri si costruisce dai cataloghi degli addon installati. Se nessun addon espone un catalogo, non mostro categorie vuote.",
                               actionTitle: "Gestisci gli addon", action: { router.tab = .more })
                    .padding(.top, 60)
            }
        } else {
            ScrollView {
                if let message = model.errorMessage, model.items.isEmpty {
                    InlineErrorView(message: message) { model.restart(env: env, mode: .reload) }.padding(.top, 20)
                } else if model.items.isEmpty && !model.isLoading {
                    EmptyStateView(systemImage: "magnifyingglass", title: "Nessun risultato",
                                   message: "Questo catalogo non ha restituito contenuti per i filtri scelti.")
                }
                if model.isStale {
                    Label("Contenuti salvati: l'addon non risponde.", systemImage: "clock.arrow.circlepath")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                }
                let width = CGFloat(settings.value.appearance.posterSize.rowWidth)
                let spacing: CGFloat = settings.value.appearance.density == .compact ? 8 : 14
                LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width + 40), spacing: spacing, alignment: .top)], spacing: spacing + 6) {
                    ForEach(model.items) { item in
                        NavigationLink(value: MetaRoute(meta: item)) {
                            PosterCard(meta: item, width: width, isInWatchlist: library.watchlistIDs.contains(item.id))
                        }
                        .buttonStyle(.plain)
                        .task { await model.loadMoreIfNeeded(current: item) }
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.top, 8)
                if model.isLoading {
                    if model.items.isEmpty {
                        SkeletonRow(posterWidth: width).padding(.top, 8)
                    } else {
                        ProgressView().padding(24)
                    }
                }
                if let message = model.errorMessage, !model.items.isEmpty {
                    InlineErrorView(message: message) { Task { await model.loadMore() } }.padding(.vertical, 12)
                }
                Color.clear.frame(height: 24)
            }
            .accessibilityIdentifier("discover.grid")
        }
    }
}
