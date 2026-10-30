import SwiftUI
import AetherCore

// MARK: - Shared filter helpers (Search and Discover)

/// Local year filter helper: offers the decades the items on screen actually cover, so the menu never lists a range
/// that cannot match anything. The filter itself is `AetherCore.ResultFilters`, applied by Aether (never sent to an addon).
enum YearBuckets {
    /// Menu tag meaning "no year filter".
    static let allKey = "all"

    /// Decades covered by `items`, newest first. Items without a parsable year contribute nothing.
    static func decades(in items: [MetaItem]) -> [YearFilter] {
        var starts = Set<Int>()
        for item in items {
            if let years = ReleaseYears.of(item) {
                starts.insert((years.start / 10) * 10)
            }
        }
        let ordered: [Int] = starts.sorted { (lhs: Int, rhs: Int) -> Bool in lhs > rhs }
        return ordered.map { (start: Int) -> YearFilter in YearFilter.decade(containing: start) }
    }

    /// Stable menu tag of a filter ("2020-2029"); `allKey` for no filter.
    static func key(_ filter: YearFilter?) -> String {
        guard let filter = filter else { return allKey }
        return text(filter.lowerBound) + "-" + text(filter.upperBound)
    }

    /// The option with the given tag; nil for `allKey` or an unknown tag.
    static func filter(forKey key: String, in options: [YearFilter]) -> YearFilter? {
        if key == allKey { return nil }
        for option in options where YearBuckets.key(option) == key {
            return option
        }
        return nil
    }

    /// `decades` plus the active filter when the data no longer contains it, so the menu always shows the real
    /// selection. Newest first.
    static func menuOptions(_ decades: [YearFilter], selected: YearFilter?) -> [YearFilter] {
        guard let selected = selected, !decades.contains(selected) else { return decades }
        var all = decades
        all.append(selected)
        return all.sorted { (lhs: YearFilter, rhs: YearFilter) -> Bool in
            return (lhs.lowerBound ?? 0) > (rhs.lowerBound ?? 0)
        }
    }

    private static func text(_ value: Int?) -> String {
        if let value = value { return String(value) }
        return ""
    }
}

/// Capsule label of a filter menu (Search and Discover). At least 44 pt tall so it is easy to hit, and it follows Dynamic Type.
struct FilterMenuLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(.footnote, design: AetherTypography.design).weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .aetherGlassCapsule(interactive: true)
    }
}

// MARK: - Catalog filters (pure)

/// What a catalog's `genre` extra lets Discover ask the addon for.
struct DiscoverServerFilter: Equatable {
    enum Kind: Equatable {
        /// Plain genre names.
        case genre
        /// The extra is really a list of release years (Cinemeta's "New" catalog).
        case year
    }

    var kind: Kind
    /// The addon's own spellings (sent back verbatim: servers compare them literally). Years are newest first.
    var options: [String]
    /// The catalog cannot be listed without choosing one.
    var isRequired: Bool

    var title: String {
        return kind == .year ? "Anno" : "Genere"
    }

    var allTitle: String {
        return kind == .year ? "Tutti gli anni" : "Tutti i generi"
    }

    var symbolName: String {
        return kind == .year ? "calendar" : "tag"
    }
}

/// What the grid shows after the local year filter.
struct DiscoverGridState {
    var items: [MetaItem]
    /// Decades covered by the loaded items (empty when the year is chosen on the server).
    var yearOptions: [YearFilter]
    /// "N risultati senza anno nascosti" when the year filter hides items for lack of data.
    var hiddenSummary: String?
    var hiddenCount: Int
}

enum DiscoverFiltering {
    private struct YearOption {
        var value: Int
        var text: String
    }

    /// The server-side filter a catalog declares through its `genre` extra, or nil when it declares none.
    /// A required `genre` that is not a list of years is a mandatory choice Discover cannot make for the user: nil.
    static func serverFilter(for catalog: ManifestCatalog) -> DiscoverServerFilter? {
        guard let property = catalog.extraProperty("genre") else { return nil }
        var options: [String] = []
        for option in property.options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if !options.contains(option) { options.append(option) }
        }
        if options.isEmpty { return nil }
        if let years = sortedYears(options) {
            return DiscoverServerFilter(kind: .year, options: years, isRequired: property.isRequired)
        }
        if property.isRequired { return nil }
        return DiscoverServerFilter(kind: .genre, options: options, isRequired: false)
    }

    /// The options as years, newest first, when every one of them is a plausible 4-digit year; nil otherwise.
    static func sortedYears(_ options: [String]) -> [String]? {
        if options.isEmpty { return nil }
        var parsed: [YearOption] = []
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count == 4, let value = Int(trimmed), ReleaseYears.plausibleRange.contains(value) else {
                return nil
            }
            parsed.append(YearOption(value: value, text: option))
        }
        let ordered: [YearOption] = parsed.sorted { (lhs: YearOption, rhs: YearOption) -> Bool in
            return lhs.value > rhs.value
        }
        return ordered.map { (entry: YearOption) -> String in entry.text }
    }

    /// The value Discover asks for when the catalog is opened: the newest year of a mandatory year list, else nothing.
    static func defaultSelection(for filter: DiscoverServerFilter?) -> String? {
        guard let filter = filter, filter.isRequired else { return nil }
        return filter.options.first
    }

    /// Catalogs of `typeID` that cannot be listed plainly (`CatalogCapabilities.catalogsToBrowse` leaves them out) but
    /// can once a year is chosen: their only required extra is a `genre` that is a list of years. Addon order.
    static func yearCatalogs(handles: [AddonHandle], typeID: String, hideAdultCatalogs: Bool) -> [CatalogRef] {
        var result: [CatalogRef] = []
        for handle in handles {
            let addon = handle.addon
            if !addon.isEnabled || addon.needsReinstall { continue }
            if hideAdultCatalogs && addon.manifest.behaviorHints.adult { continue }
            for catalog in addon.manifest.catalogs {
                if ContentTypes.canonicalID(catalog.type) != typeID { continue }
                if !addon.isCatalogVisible(catalog) { continue }
                if catalog.isExtraSupported([]) { continue }
                guard let filter = serverFilter(for: catalog), filter.kind == .year,
                      let newest = filter.options.first else { continue }
                let probe = [ExtraValue(name: "genre", value: newest)]
                if !catalog.isExtraSupported(probe) { continue }
                result.append(CatalogRef(addonID: addon.id, addonName: addon.displayName, catalog: catalog))
            }
        }
        return result
    }

    /// Applies the local year filter to the loaded items. With `usesLocalYear` false (the year is chosen on the server,
    /// or the catalog has no years to offer) the items pass through untouched.
    static func gridState(items: [MetaItem], year: YearFilter?, usesLocalYear: Bool) -> DiscoverGridState {
        if !usesLocalYear {
            return DiscoverGridState(items: items, yearOptions: [], hiddenSummary: nil, hiddenCount: 0)
        }
        let decades = YearBuckets.decades(in: items)
        let outcome = ResultFilters(year: year, yearMatch: .premiere).apply(to: items)
        return DiscoverGridState(items: outcome.kept, yearOptions: decades,
                                 hiddenSummary: outcome.missingDataSummary, hiddenCount: outcome.totalHidden)
    }
}

// MARK: - View model

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var capabilities: CatalogCapabilities = CatalogCapabilities.empty
    @Published private(set) var hasLoaded = false
    /// Canonical id of the selected type.
    @Published private(set) var selectedType: String?
    @Published private(set) var catalogs: [CatalogRef] = []
    @Published private(set) var selectedCatalog: CatalogRef?
    @Published private(set) var serverFilter: DiscoverServerFilter? {
        didSet { updateGrid() }
    }
    /// The value of the `genre` extra being requested (a genre name, or a year for a year catalog).
    @Published private(set) var selectedGenre: String?
    @Published private(set) var yearFilter: YearFilter? {
        didSet { updateGrid() }
    }
    @Published private(set) var items: [MetaItem] = [] {
        didSet { updateGrid() }
    }
    @Published private(set) var grid = DiscoverGridState(items: [], yearOptions: [], hiddenSummary: nil, hiddenCount: 0)
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isStale = false

    private var handles: [AddonHandle] = []
    private var hideAdult = true
    private var pager: CatalogPager?
    private var loadTask: Task<Void, Never>?
    /// Bumped by every restart so an answer to a superseded request is dropped.
    private var generation = 0

    // MARK: Layout

    /// The stored order/visibility reconciled with the types the installed addons provide now.
    func layoutState(stored: [DiscoverTypeSetting]) -> DiscoverLayoutState {
        var ids: [String] = []
        for type in capabilities.availableTypes {
            ids.append(type.id)
        }
        return DiscoverLayout.normalise(stored: stored, available: ids)
    }

    /// The chips Discover shows: available and not hidden, in the user's order.
    func visibleTypes(stored: [DiscoverTypeSetting]) -> [CatalogTypeCapability] {
        let state = layoutState(stored: stored)
        var result: [CatalogTypeCapability] = []
        for id in state.visibleTypes {
            if let capability = capabilities.capability(forType: id) {
                result.append(capability)
            }
        }
        return result
    }

    // MARK: Loading

    /// Re-reads the addons (they or the network changed) and reloads the selected catalog.
    func reload(env: AppEnvironment) async {
        let loaded = await env.addons.handles()
        if Task.isCancelled { return }
        let content = env.settings.value.content
        hideAdult = content.hideAdultCatalogs
        handles = loaded
        capabilities = CatalogCapabilities.build(handles: loaded, hideAdultCatalogs: content.hideAdultCatalogs)
        hasLoaded = true
        applyLayout(stored: content.discoverTypes, env: env, forceRestart: true)
    }

    /// The user changed order or visibility of the types: update the chips and the selection without refetching
    /// the catalog that stays selected.
    func syncLayout(stored: [DiscoverTypeSetting], env: AppEnvironment) {
        if !hasLoaded { return }
        applyLayout(stored: stored, env: env, forceRestart: false)
    }

    private func applyLayout(stored: [DiscoverTypeSetting], env: AppEnvironment, forceRestart: Bool) {
        let state = layoutState(stored: stored)
        let resolved = DiscoverLayout.resolveSelection(current: selectedType, visible: state.visibleTypes)
        let typeChanged = resolved != selectedType
        if typeChanged {
            selectedType = resolved
            selectedCatalog = nil
        }
        updateCatalogs(env: env, forceRestart: forceRestart || typeChanged)
    }

    func select(type: String, env: AppEnvironment) {
        let key = ContentTypes.canonicalID(type)
        if key == selectedType { return }
        selectedType = key
        selectedCatalog = nil
        updateCatalogs(env: env, forceRestart: true)
    }

    func select(catalog: CatalogRef, env: AppEnvironment) {
        if catalog == selectedCatalog { return }
        selectedCatalog = catalog
        updateCatalogs(env: env, forceRestart: true)
    }

    /// Chooses the `genre` extra sent to the addon (a genre, or a year for a year catalog); nil asks for no filter.
    func select(genre: String?, env: AppEnvironment) {
        if genre == selectedGenre { return }
        selectedGenre = genre
        yearFilter = nil
        restart(env: env)
    }

    /// Local year filter: nothing is requested, the loaded items are filtered by Aether.
    func select(year: YearFilter?) {
        yearFilter = year
    }

    private func updateCatalogs(env: AppEnvironment, forceRestart: Bool) {
        guard let type = selectedType else {
            loadTask?.cancel()
            generation += 1
            catalogs = []
            selectedCatalog = nil
            serverFilter = nil
            selectedGenre = nil
            yearFilter = nil
            items = []
            hasMore = false
            isLoading = false
            errorMessage = nil
            isStale = false
            pager = nil
            return
        }
        var list = capabilities.catalogsToBrowse(forType: type)
        list.append(contentsOf: DiscoverFiltering.yearCatalogs(handles: handles, typeID: type, hideAdultCatalogs: hideAdult))
        let ordered = env.settings.value.content.catalogLayout.sorted(list, id: { $0.id })
        catalogs = ordered
        list = ordered

        let previous = selectedCatalog
        if let current = selectedCatalog, list.contains(current) {
            // The selected catalog is still offered: keep it.
        } else {
            selectedCatalog = list.first
        }
        let catalogChanged = previous != selectedCatalog

        let genreBefore = selectedGenre
        configureFilter(catalogChanged: catalogChanged)
        let genreChanged = genreBefore != selectedGenre

        if forceRestart || catalogChanged || genreChanged || pager == nil {
            restart(env: env)
        }
    }

    /// Reads the `genre` extra of the selected catalog. A new catalog starts from its default (no filter, or the newest
    /// year of a mandatory year list); the same catalog keeps the user's choice while the addon still offers it.
    private func configureFilter(catalogChanged: Bool) {
        guard let catalog = selectedCatalog else {
            serverFilter = nil
            selectedGenre = nil
            yearFilter = nil
            return
        }
        let filter = DiscoverFiltering.serverFilter(for: catalog.catalog)
        serverFilter = filter
        if catalogChanged {
            selectedGenre = DiscoverFiltering.defaultSelection(for: filter)
            yearFilter = nil
            return
        }
        if let current = selectedGenre, let filter = filter, filter.options.contains(current) {
            return
        }
        selectedGenre = DiscoverFiltering.defaultSelection(for: filter)
    }

    func restart(env: AppEnvironment, mode: AddonClient.LoadMode = .normal) {
        loadTask?.cancel()
        generation += 1
        items = []
        errorMessage = nil
        hasMore = false
        isStale = false
        isLoading = false
        guard let ref = selectedCatalog else {
            pager = nil
            return
        }
        var extra: [ExtraValue] = []
        if let genre = selectedGenre {
            extra.append(ExtraValue(name: "genre", value: genre))
        }
        pager = CatalogPager(ref: ref, service: env.service, extra: extra)
        loadTask = Task { await loadMore(mode: mode) }
    }

    /// Pull to refresh: the spinner stays until the first page is back.
    func refresh(env: AppEnvironment) async {
        restart(env: env, mode: .reload)
        await loadTask?.value
    }

    func loadMore(mode: AddonClient.LoadMode = .normal) async {
        guard let pager = pager, !isLoading else { return }
        let myGeneration = generation
        isLoading = true
        do {
            let page = try await pager.loadNext(mode: mode)
            guard myGeneration == generation else { return }
            isLoading = false
            items.append(contentsOf: page.newItems)
            hasMore = page.hasMore
            isStale = isStale || page.isStale
            errorMessage = nil
        } catch {
            guard myGeneration == generation else { return }
            isLoading = false
            if error is CancellationError { return }
            errorMessage = (error as? AddonError)?.message ?? error.localizedDescription
        }
    }

    /// Loads the next page when `item` is among the last ones *shown* (the local year filter may hide many loaded items).
    func loadMoreIfNeeded(current item: MetaItem) async {
        guard hasMore, !isLoading else { return }
        let visible = grid.items
        guard let index = visible.firstIndex(where: { (candidate: MetaItem) -> Bool in candidate.id == item.id }) else { return }
        if index >= visible.count - 8 {
            await loadMore()
        }
    }

    private func updateGrid() {
        var yearIsChosenOnTheServer = false
        if let filter = serverFilter, filter.kind == DiscoverServerFilter.Kind.year {
            yearIsChosenOnTheServer = true
        }
        grid = DiscoverFiltering.gridState(items: items, year: yearFilter, usesLocalYear: !yearIsChosenOnTheServer)
    }
}

// MARK: - View

struct DiscoverView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = DiscoverViewModel()
    @State private var showingCustomize = false

    private var storedTypes: [DiscoverTypeSetting] {
        return settings.value.content.discoverTypes
    }

    private var loadKey: String {
        return "\(addons.revision)-\(network.reconnectToken)-\(settings.value.content.hideAdultCatalogs)-\(settings.value.content.hideTalkShows)"
    }

    var body: some View {
        let layout = model.layoutState(stored: storedTypes)
        let types = model.visibleTypes(stored: storedTypes)
        NavigationStack {
            ZStack {
                AetherBackdrop()
                VStack(spacing: 0) {
                    if !types.isEmpty { controls(types) }
                    content(layout)
                }
            }
            .navigationTitle("Scopri")
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.hasLoaded && !model.capabilities.availableTypes.isEmpty {
                        Button {
                            showingCustomize = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Personalizza le categorie")
                        .accessibilityIdentifier("discover.customize")
                    }
                }
            }
            .task(id: loadKey) { await model.reload(env: env) }
            .onChange(of: storedTypes) { _, newValue in
                model.syncLayout(stored: newValue, env: env)
            }
            .refreshable { await model.refresh(env: env) }
            .sheet(isPresented: $showingCustomize) {
                NavigationStack { DiscoverSettingsView(showsCloseButton: true) }
            }
        }
    }

    // MARK: Controls

    private func controls(_ types: [CatalogTypeCapability]) -> some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(types) { type in
                        FilterChip(title: type.title, isSelected: model.selectedType == type.id) {
                            model.select(type: type.id, env: env)
                        }
                        .accessibilityIdentifier("discover.type.\(type.id)")
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
            if !model.catalogs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        catalogControl
                        if let filter = model.serverFilter { serverFilterMenu(filter) }
                        if !model.grid.yearOptions.isEmpty || model.yearFilter != nil {
                            localYearMenu(model.grid.yearOptions)
                        }
                    }
                    .padding(.horizontal, Theme.pageMargin)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func catalogName(_ ref: CatalogRef) -> String {
        return settings.value.content.catalogLayout.title(forID: ref.id, fallback: ref.title)
    }

    @ViewBuilder
    private var catalogControl: some View {
        if model.catalogs.count > 1 {
            Menu {
                Picker("Catalogo", selection: catalogSelection) {
                    ForEach(model.catalogs) { ref in
                        Text("\(catalogName(ref)) · \(ref.addonName)").tag(ref.id)
                    }
                }
            } label: {
                FilterMenuLabel(title: model.selectedCatalog.map { catalogName($0) } ?? "Catalogo", systemImage: "list.bullet")
            }
            .accessibilityLabel("Catalogo")
            .accessibilityValue(model.selectedCatalog.map { catalogName($0) } ?? "")
            .accessibilityIdentifier("discover.catalogMenu")
        } else if let catalog = model.selectedCatalog {
            Text("\(catalogName(catalog)) · \(catalog.addonName)")
                .font(.footnote)
                .foregroundStyle(Color.aetherSecondary)
                .lineLimit(1)
        }
    }

    private func serverFilterMenu(_ filter: DiscoverServerFilter) -> some View {
        Menu {
            Picker(filter.title, selection: genreSelection) {
                if !filter.isRequired {
                    Text(filter.allTitle).tag("")
                }
                ForEach(filter.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        } label: {
            FilterMenuLabel(title: model.selectedGenre ?? filter.title, systemImage: filter.symbolName)
        }
        .accessibilityLabel(filter.title)
        .accessibilityValue(model.selectedGenre ?? filter.allTitle)
        .accessibilityIdentifier(filter.kind == .year ? "discover.yearMenu" : "discover.genreMenu")
    }

    private func localYearMenu(_ decades: [YearFilter]) -> some View {
        let options = YearBuckets.menuOptions(decades, selected: model.yearFilter)
        return Menu {
            Picker("Anno", selection: yearSelection(options)) {
                Text("Tutti gli anni").tag(YearBuckets.allKey)
                ForEach(options, id: \.self) { option in
                    Text(option.label).tag(YearBuckets.key(option))
                }
            }
        } label: {
            FilterMenuLabel(title: model.yearFilter?.label ?? "Anno", systemImage: "calendar")
        }
        .accessibilityLabel("Anno")
        .accessibilityValue(model.yearFilter?.label ?? "Tutti gli anni")
        .accessibilityIdentifier("discover.yearMenu")
    }

    private var catalogSelection: Binding<String> {
        return Binding<String>(
            get: { return model.selectedCatalog?.id ?? "" },
            set: { (newID: String) in
                let match = model.catalogs.first(where: { (candidate: CatalogRef) -> Bool in candidate.id == newID })
                if let match = match { model.select(catalog: match, env: env) }
            })
    }

    private var genreSelection: Binding<String> {
        return Binding<String>(
            get: { return model.selectedGenre ?? "" },
            set: { (value: String) in
                model.select(genre: value.isEmpty ? nil : value, env: env)
            })
    }

    private func yearSelection(_ options: [YearFilter]) -> Binding<String> {
        return Binding<String>(
            get: { return YearBuckets.key(model.yearFilter) },
            set: { (key: String) in
                model.select(year: YearBuckets.filter(forKey: key, in: options))
            })
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ layout: DiscoverLayoutState) -> some View {
        if !model.hasLoaded {
            ScrollView {
                SkeletonRow(posterWidth: CGFloat(settings.value.appearance.posterSize.rowWidth)).padding(.top, 20)
            }
        } else if model.capabilities.availableTypes.isEmpty {
            ScrollView {
                EmptyStateView(systemImage: "square.grid.2x2",
                               title: "Niente da scoprire (ancora)",
                               message: "Scopri si costruisce dai cataloghi degli addon installati. Se nessun addon espone un catalogo, non mostro categorie vuote.",
                               actionTitle: "Gestisci gli addon", action: { router.tab = .more })
                    .padding(.top, 60)
                    .accessibilityIdentifier("discover.empty")
            }
        } else if layout.isEverythingHidden {
            ScrollView {
                EmptyStateView(systemImage: "eye.slash",
                               title: "Tutte le categorie sono nascoste",
                               message: "Hai nascosto ogni tipo di contenuto di Scopri. Scegline almeno uno per vedere i cataloghi dei tuoi addon.",
                               actionTitle: "Scegli le categorie", action: { showingCustomize = true })
                    .padding(.top, 60)
                    .accessibilityIdentifier("discover.allHidden")
            }
        } else {
            gridContent
        }
    }

    private var gridContent: some View {
        let width = CGFloat(settings.value.appearance.posterSize.rowWidth)
        let spacing: CGFloat = settings.value.appearance.density == .compact ? 8 : 14
        let state = model.grid
        return ScrollView {
            if let message = model.errorMessage, model.items.isEmpty {
                InlineErrorView(message: message) { model.restart(env: env, mode: .reload) }.padding(.top, 20)
            } else if state.items.isEmpty && !model.isLoading {
                emptyResults
            }
            if model.isStale {
                Label("Contenuti salvati: l'addon non risponde.", systemImage: "clock.arrow.circlepath")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary).padding(.top, 6)
            }
            AdaptiveCardGrid(items: state.items, minColumns: 3, preferredWidth: width, spacing: spacing, rowSpacing: spacing + 6) { item, cardWidth in
                NavigationLink(value: MetaRoute(meta: item)) {
                    PosterCard(meta: item, width: cardWidth, isInWatchlist: library.watchlistIDs.contains(item.id))
                }
                .buttonStyle(.plain)
                .task { await model.loadMoreIfNeeded(current: item) }
            }
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
            if let summary = state.hiddenSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Color.aetherSecondary)
                    .padding(.horizontal, Theme.pageMargin)
                    .padding(.top, 8)
                    .accessibilityIdentifier("discover.hidden")
            }
            if model.yearFilter != nil && model.hasMore && !model.isLoading {
                Button("Carica altri titoli") { Task { await model.loadMore() } }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .padding(.top, 12)
                    .accessibilityIdentifier("discover.loadMore")
            }
            Color.clear.frame(height: 24)
        }
        .accessibilityIdentifier("discover.grid")
    }

    @ViewBuilder
    private var emptyResults: some View {
        if model.items.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass", title: "Nessun risultato",
                           message: "Questo catalogo non ha restituito contenuti per i filtri scelti.")
        } else {
            EmptyStateView(systemImage: "calendar", title: "Nessun titolo per questo anno",
                           message: (model.items.count == 1 ? "Il titolo caricato non corrisponde a" : "Tra i \(model.items.count) titoli caricati nessuno corrisponde a") + " «\(model.yearFilter?.label ?? "")».",
                           actionTitle: "Mostra tutti gli anni", action: { model.select(year: nil) })
                .accessibilityIdentifier("discover.yearEmpty")
        }
    }
}
