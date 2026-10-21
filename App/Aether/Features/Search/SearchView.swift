import SwiftUI
import AetherCore

// MARK: - Filter state (pure)

/// What the user chose in the filter bar below the search field.
///
/// Type and genre are part of the request (`SearchPlan` decides, from the addons' manifests, what is really sent);
/// year and sort are always applied by Aether to the answers it already has.
struct SearchFilterState: Equatable {
    /// Canonical id of the type (`ContentTypes.canonicalID`); nil searches every type.
    var typeID: String?
    var genre: String?
    var year: YearFilter?
    var sort: SearchSort

    init(typeID: String? = nil, genre: String? = nil, year: YearFilter? = nil, sort: SearchSort = SearchSort.relevance) {
        self.typeID = typeID
        self.genre = genre
        self.year = year
        self.sort = sort
    }

    /// Sorting is not a filter: it never hides anything.
    var hasActiveFilters: Bool {
        return typeID != nil || genre != nil || year != nil
    }

    mutating func reset() {
        typeID = nil
        genre = nil
        year = nil
    }

    /// The same choices checked against what the installed addons offer now: a type nobody provides any more is
    /// dropped, and so is a genre the (new) type does not list.
    func reconciled(with capabilities: CatalogCapabilities) -> SearchFilterState {
        var result = self
        if let type = result.typeID {
            if let capability = capabilities.capability(forType: type) {
                result.typeID = capability.id
            } else {
                result.typeID = nil
            }
        }
        if let genre = result.genre {
            let offered = capabilities.filterGenres(forType: result.typeID)
            result.genre = SearchFilterState.matchingGenre(genre, in: offered)
        }
        return result
    }

    /// Chooses a type (nil: all) and drops the genre when the new type does not list it.
    mutating func select(type: String?, capabilities: CatalogCapabilities) {
        if let type = type {
            typeID = ContentTypes.canonicalID(type)
        } else {
            typeID = nil
        }
        self = reconciled(with: capabilities)
    }

    /// The spelling of `genre` in `offered` (compared ignoring case and accents); nil when it is not offered.
    static func matchingGenre(_ genre: String, in offered: [String]) -> String? {
        let wanted = GenreNames.key(genre)
        if wanted.isEmpty { return nil }
        for candidate in offered where GenreNames.key(candidate) == wanted {
            return candidate
        }
        return nil
    }

    /// Italian notice when the chosen type exists but no addon can search it; nil otherwise.
    func unsupportedTypeNotice(capabilities: CatalogCapabilities) -> String? {
        guard let type = typeID, let capability = capabilities.capability(forType: type) else { return nil }
        if capability.isSearchable { return nil }
        return "Nessun addon installato supporta la ricerca per «\(capability.title)»."
    }
}

// MARK: - Results (pure)

/// One catalog's answer to the planned search, ready to be presented.
struct SearchCatalogResult: Identifiable {
    let id: String
    let title: String
    let addonName: String
    /// Canonical id of the catalog's type.
    let typeID: String
    /// Position of the catalog in the plan (addon order), so rows never depend on which addon answered first.
    let order: Int
    /// Items that passed the plan's local filters (genre).
    let items: [MetaItem]
    let error: AddonError?
    let isStale: Bool
    /// What the plan's local filters hid from this answer (`kept` is empty).
    let hiddenByPlan: ResultFilterOutcome

    init(id: String, title: String, addonName: String, typeID: String, order: Int, items: [MetaItem],
         error: AddonError? = nil, isStale: Bool = false,
         hiddenByPlan: ResultFilterOutcome = ResultFilterOutcome(kept: [])) {
        self.id = id
        self.title = title
        self.addonName = addonName
        self.typeID = typeID
        self.order = order
        self.items = items
        self.error = error
        self.isStale = isStale
        self.hiddenByPlan = hiddenByPlan
    }

    init(update: PlannedSearchUpdate, order: Int) {
        let row = update.row
        var counts = update.filtering
        counts.kept = []
        self.id = row.ref.id
        self.title = row.ref.title
        self.addonName = row.ref.addonName
        self.typeID = ContentTypes.canonicalID(row.ref.type)
        self.order = order
        self.items = row.items
        self.error = row.error
        self.isStale = row.isStale
        self.hiddenByPlan = counts
    }
}

struct PresentedSearchRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let items: [MetaItem]
}

struct SearchPresentation {
    /// The best results of all catalogs, de-duplicated and sorted.
    var merged: [MetaItem]
    /// One row per catalog that has something to show.
    var rows: [PresentedSearchRow]
    /// Matches in the user's library.
    var library: [MetaItem]
    /// Decades covered by the results before the year filter; empty when no result carries a year.
    var yearOptions: [YearFilter]
    /// What the local filters hid (`kept` is empty).
    var hidden: ResultFilterOutcome
    /// Library matches left out only because of their type.
    var libraryTypeMismatches: Int

    var visibleCount: Int {
        return merged.count + library.count
    }

    /// Everything the filters took away, whatever the reason.
    var filteredOutCount: Int {
        return hidden.totalHidden + libraryTypeMismatches
    }

    /// "3 risultati senza anno nascosti": hidden only because the data to decide was missing.
    var missingDataSummary: String? {
        return hidden.missingDataSummary
    }
}

enum SearchPresenter {
    /// How many items per catalog are requested from `PlannedSearch`: more than shown, so the local year filter can choose.
    static let fetchLimit = 100
    /// How many items a row (or the merged row) shows.
    static let displayLimit = 40

    /// Applies the filters Aether owns (year, and genre/type for the library) to what the plan fetched, and counts what
    /// they hid because the data was missing.
    static func present(results: [SearchCatalogResult], library: [MetaItem], filters: SearchFilterState) -> SearchPresentation {
        let ordered = results.sorted { (lhs: SearchCatalogResult, rhs: SearchCatalogResult) -> Bool in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.id < rhs.id
        }

        // Library matches: type first, then genre, then year, the same order the remote answers go through.
        var typeMatches: [MetaItem] = []
        if let typeID = filters.typeID {
            for item in library where ContentTypes.canonicalID(item.type) == typeID {
                typeMatches.append(item)
            }
        } else {
            typeMatches = library
        }
        let libraryTypeMismatches = library.count - typeMatches.count
        let libraryGenre = ResultFilters(genre: filters.genre).apply(to: typeMatches)
        let yearFilters = ResultFilters(year: filters.year, yearMatch: YearMatch.premiere)
        let libraryYear = yearFilters.apply(to: libraryGenre.kept)

        // The year menu offers the decades of everything that passed the earlier stages.
        var yearSource: [MetaItem] = libraryGenre.kept
        for result in ordered {
            yearSource.append(contentsOf: result.items)
        }
        let decades = YearBuckets.decades(in: yearSource)

        var outcomes: [ResultFilterOutcome] = [countsOnly(libraryGenre), countsOnly(libraryYear)]
        var perCatalog: [[MetaItem]] = []
        var rows: [PresentedSearchRow] = []
        for result in ordered {
            outcomes.append(result.hiddenByPlan)
            let yearOutcome = yearFilters.apply(to: result.items)
            outcomes.append(countsOnly(yearOutcome))
            perCatalog.append(yearOutcome.kept)
            if yearOutcome.kept.isEmpty { continue }
            let sortedItems = filters.sort.apply(to: yearOutcome.kept)
            let subtitle = result.addonName + " · " + ContentTypes.title(for: result.typeID)
            rows.append(PresentedSearchRow(id: result.id, title: result.title, subtitle: subtitle,
                                           items: Array(sortedItems.prefix(displayLimit))))
        }
        let interleaved = MetaDeduper.interleave(perCatalog)
        let merged = Array(filters.sort.apply(to: interleaved).prefix(displayLimit))

        return SearchPresentation(merged: merged, rows: rows, library: libraryYear.kept, yearOptions: decades,
                                  hidden: ResultFilterOutcome.combine(outcomes),
                                  libraryTypeMismatches: libraryTypeMismatches)
    }

    private static func countsOnly(_ outcome: ResultFilterOutcome) -> ResultFilterOutcome {
        var copy = outcome
        copy.kept = []
        return copy
    }
}

/// Everything that makes a new search necessary. Year and sort are not here: they only re-filter what is on screen.
struct SearchRunKey: Equatable {
    var query: String
    var typeID: String?
    var genre: String?
    var capabilitiesStamp: Int
}

// MARK: - View model

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var filters = SearchFilterState()
    @Published private(set) var capabilities: CatalogCapabilities = CatalogCapabilities.empty
    /// 0 until the capabilities were computed for the first time; bumped whenever they change.
    @Published private(set) var capabilitiesStamp = 0
    @Published private(set) var results: [SearchCatalogResult] = []
    @Published private(set) var localResults: [MetaItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var hasSearched = false
    /// The plan of the last search: tells which filters went to the addons and which only Aether applies.
    @Published private(set) var plan: SearchPlan?
    @Published private(set) var remoteSearchEnabled = true

    private var lastQuery = ""
    private var sortInitialised = false

    // MARK: Derived

    var normalisedQuery: String {
        return SearchService.normalisedQuery(query)
    }

    var searchableCatalogCount: Int {
        return capabilities.searchCatalogs.count
    }

    var showsFilterBar: Bool {
        return !capabilities.types.isEmpty
    }

    /// Genres of the catalogs that can serve the chosen type (all searchable types when none is chosen).
    var genreOptions: [String] {
        return capabilities.filterGenres(forType: filters.typeID)
    }

    var unsupportedTypeNotice: String? {
        return filters.unsupportedTypeNotice(capabilities: capabilities)
    }

    var searchPrompt: String {
        if let type = filters.typeID, let capability = capabilities.capability(forType: type) {
            return "Cerca in \(capability.title)…"
        }
        return "Film, serie, canali, eventi…"
    }

    var runKey: SearchRunKey {
        return SearchRunKey(query: normalisedQuery, typeID: filters.typeID, genre: filters.genre,
                            capabilitiesStamp: capabilitiesStamp)
    }

    var failedResults: [SearchCatalogResult] {
        let failed = results.filter { (result: SearchCatalogResult) -> Bool in result.error != nil }
        return failed.sorted { (lhs: SearchCatalogResult, rhs: SearchCatalogResult) -> Bool in lhs.order < rhs.order }
    }

    /// How the type and genre were handled, and that year is applied by Aether.
    var filterNotes: [String] {
        var notes: [String] = []
        if let plan = plan, let note = plan.genreNotice {
            notes.append(note)
        }
        if filters.year != nil {
            notes.append("Il filtro per anno è applicato da Aether sui risultati ricevuti: gli addon non lo supportano nella ricerca.")
        }
        return notes
    }

    var emptyMessage: String {
        let text = normalisedQuery
        if !remoteSearchEnabled {
            return "Non ho trovato «\(text)» nella tua libreria. La ricerca negli addon è disattivata nelle impostazioni."
        }
        if let plan = plan, plan.entries.isEmpty {
            return "Non ho trovato «\(text)» nella tua libreria e nessun addon può cercare tra i contenuti scelti."
        }
        let count = results.count
        if count == 1 {
            return "Non ho trovato «\(text)» in 1 catalogo."
        }
        return "Non ho trovato «\(text)» in \(count) cataloghi."
    }

    func presentation() -> SearchPresentation {
        return SearchPresenter.present(results: results, library: localResults, filters: filters)
    }

    // MARK: Filters

    func select(type: String?) {
        filters.select(type: type, capabilities: capabilities)
    }

    func select(genre: String?) {
        filters.genre = genre
    }

    func select(year: YearFilter?) {
        filters.year = year
    }

    func resetFilters() {
        filters.reset()
    }

    // MARK: Loading

    /// Recomputes what the installed addons can serve. Called again whenever the addons (or the adult setting) change:
    /// the type and genre menus follow, a choice that no longer exists is dropped, and a search in progress is repeated.
    func prepare(env: AppEnvironment) async {
        let handles = await env.addons.handles()
        if Task.isCancelled { return }
        let content = env.settings.value.content
        let built = CatalogCapabilities.build(handles: handles, hideAdultCatalogs: content.hideAdultCatalogs)
        if capabilitiesStamp == 0 || built != capabilities {
            capabilities = built
            capabilitiesStamp += 1
            filters = filters.reconciled(with: built)
        }
        if !sortInitialised {
            sortInitialised = true
            filters.sort = content.searchSort
        }
    }

    func run(env: AppEnvironment) async {
        let normalised = normalisedQuery
        guard normalised.count >= 2 else {
            results = []
            localResults = []
            isSearching = false
            hasSearched = false
            plan = nil
            lastQuery = ""
            return
        }
        // The plan needs the capabilities; prepare() bumps the stamp, which restarts this task.
        guard capabilitiesStamp > 0 else { return }
        // Debounce typing only: a newer keystroke cancels this task (via `.task(id:)`) before any request is made.
        // Choosing a filter searches at once.
        if normalised != lastQuery {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
        }
        lastQuery = normalised

        let content = env.settings.value.content
        hasSearched = true
        isSearching = true
        results = []
        progress = (0, 0)
        remoteSearchEnabled = content.searchRemote

        var newPlan: SearchPlan?
        if content.searchRemote {
            newPlan = SearchPlan.make(query: normalised, type: filters.typeID, genre: filters.genre,
                                      capabilities: capabilities)
        }
        plan = newPlan

        if content.searchLocal {
            let found = await env.libraryStore.searchLocal(normalised)
            if Task.isCancelled { return }
            localResults = found
        } else {
            localResults = []
        }

        guard let runnable = newPlan, runnable.isRunnable else {
            isSearching = false
            return
        }
        var orderByCatalog: [String: Int] = [:]
        for (index, entry) in runnable.entries.enumerated() {
            orderByCatalog[entry.id] = index
        }
        progress = (0, runnable.entries.count)
        let search = PlannedSearch(service: env.service)
        for await update in search.run(runnable, perCatalogLimit: SearchPresenter.fetchLimit) {
            if Task.isCancelled { return }
            let order = orderByCatalog[update.row.ref.id] ?? runnable.entries.count
            results.append(SearchCatalogResult(update: update, order: order))
            progress = (update.completed, update.total)
        }
        if Task.isCancelled { return }
        isSearching = false
    }
}

// MARK: - View

struct SearchView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = SearchViewModel()

    /// Menu tag meaning "no choice" (a type id or a genre never looks like this).
    private static let anyValue = "__any__"

    private var prepareKey: String {
        return "\(addons.revision)-\(settings.value.content.hideAdultCatalogs)"
    }

    var body: some View {
        let presentation = model.presentation()
        NavigationStack {
            ZStack {
                AetherBackdrop()
                VStack(spacing: 0) {
                    if model.showsFilterBar { filterBar(presentation) }
                    if let notice = model.unsupportedTypeNotice {
                        InlineErrorView(message: notice)
                            .padding(.bottom, 6)
                            .accessibilityIdentifier("search.unsupported")
                    }
                    content(presentation)
                }
            }
            .navigationTitle("Cerca")
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: model.searchPrompt)
            .autocorrectionDisabled()
            .onSubmit(of: .search) {
                let text = model.query
                Task { await env.libraryStore.addSearch(text) }
            }
            .task(id: model.runKey) { await model.run(env: env) }
            .task(id: prepareKey) { await model.prepare(env: env) }
            .onChange(of: router.pendingSearch) { _, new in
                if let new = new { model.query = new; router.pendingSearch = nil }
            }
            .onChange(of: settings.value.content.searchSort) { _, newValue in
                model.filters.sort = newValue
            }
        }
    }

    // MARK: Filter bar

    private func filterBar(_ presentation: SearchPresentation) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if model.capabilities.types.count > 1 { typeMenu }
                if !model.genreOptions.isEmpty { genreMenu(model.genreOptions) }
                if !presentation.yearOptions.isEmpty || model.filters.year != nil {
                    yearMenu(presentation.yearOptions)
                }
                sortMenu
                if model.filters.hasActiveFilters { resetButton }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 8)
        }
    }

    private var typeMenu: some View {
        var selected: CatalogTypeCapability?
        if let id = model.filters.typeID {
            selected = model.capabilities.capability(forType: id)
        }
        return Menu {
            Picker("Tipo", selection: typeSelection) {
                Text("Tutti i tipi").tag(SearchView.anyValue)
                ForEach(model.capabilities.types) { type in
                    Label(type.title, systemImage: type.symbolName).tag(type.id)
                }
            }
        } label: {
            FilterMenuLabel(title: selected?.title ?? "Tipo", systemImage: selected?.symbolName ?? "square.grid.2x2")
        }
        .accessibilityLabel("Tipo")
        .accessibilityValue(selected?.title ?? "Tutti i tipi")
        .accessibilityIdentifier("search.type")
    }

    private func genreMenu(_ genres: [String]) -> some View {
        Menu {
            Picker("Genere", selection: genreSelection) {
                Text("Tutti i generi").tag(SearchView.anyValue)
                ForEach(genres, id: \.self) { genre in
                    Text(genre).tag(genre)
                }
            }
        } label: {
            FilterMenuLabel(title: model.filters.genre ?? "Genere", systemImage: "tag")
        }
        .accessibilityLabel("Genere")
        .accessibilityValue(model.filters.genre ?? "Tutti i generi")
        .accessibilityIdentifier("search.genre")
    }

    private func yearMenu(_ decades: [YearFilter]) -> some View {
        let options = YearBuckets.menuOptions(decades, selected: model.filters.year)
        return Menu {
            Picker("Anno", selection: yearSelection(options)) {
                Text("Tutti gli anni").tag(YearBuckets.allKey)
                ForEach(options, id: \.self) { option in
                    Text(option.label).tag(YearBuckets.key(option))
                }
            }
        } label: {
            FilterMenuLabel(title: model.filters.year?.label ?? "Anno", systemImage: "calendar")
        }
        .accessibilityLabel("Anno")
        .accessibilityValue(model.filters.year?.label ?? "Tutti gli anni")
        .accessibilityIdentifier("search.year")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Ordina", selection: $model.filters.sort) {
                ForEach(SearchSort.allCases, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
        } label: {
            FilterMenuLabel(title: model.filters.sort.title, systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Ordina i risultati")
        .accessibilityValue(model.filters.sort.title)
        .accessibilityIdentifier("search.sort")
    }

    private var resetButton: some View {
        Button {
            model.resetFilters()
        } label: {
            FilterMenuLabel(title: "Reimposta filtri", systemImage: "xmark.circle")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search.reset")
    }

    private var typeSelection: Binding<String> {
        return Binding<String>(
            get: { return model.filters.typeID ?? SearchView.anyValue },
            set: { (value: String) in
                model.select(type: value == SearchView.anyValue ? nil : value)
            })
    }

    private var genreSelection: Binding<String> {
        return Binding<String>(
            get: { return model.filters.genre ?? SearchView.anyValue },
            set: { (value: String) in
                model.select(genre: value == SearchView.anyValue ? nil : value)
            })
    }

    private func yearSelection(_ options: [YearFilter]) -> Binding<String> {
        return Binding<String>(
            get: { return YearBuckets.key(model.filters.year) },
            set: { (key: String) in
                model.select(year: YearBuckets.filter(forKey: key, in: options))
            })
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ presentation: SearchPresentation) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if model.capabilitiesStamp > 0 && model.searchableCatalogCount == 0 && settings.value.content.searchRemote {
                    InlineErrorView(message: "Nessun addon attivo dichiara la ricerca nei suoi cataloghi: posso cercare solo nella tua libreria.")
                        .padding(.top, 8)
                }
                if model.normalisedQuery.count < 2 {
                    idleContent
                } else {
                    resultsContent(presentation)
                }
                Color.clear.frame(height: 24)
            }
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func resultsContent(_ presentation: SearchPresentation) -> some View {
        if model.isSearching {
            HStack(spacing: 8) {
                ProgressView()
                Text("Cerco in \(model.progress.total > 0 ? "\(model.progress.done)/\(model.progress.total)" : "…") cataloghi")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            .padding(.horizontal, Theme.pageMargin)
            .accessibilityIdentifier("search.progress")
        }
        // Said before the results, not after the last row: this is what explains why there are fewer of them.
        if let summary = presentation.missingDataSummary {
            Text(summary)
                .font(.footnote)
                .foregroundStyle(Color.aetherSecondary)
                .padding(.horizontal, Theme.pageMargin)
                .accessibilityIdentifier("search.hidden")
        }
        if !presentation.library.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Nella tua libreria")
                PosterRowView(items: presentation.library, watchlistIDs: library.watchlistIDs)
            }
        }
        if !presentation.merged.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Migliori risultati")
                PosterRowView(items: presentation.merged, watchlistIDs: library.watchlistIDs)
            }
            .accessibilityIdentifier("search.merged")
            ForEach(presentation.rows) { row in
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: row.title, subtitle: row.subtitle)
                    PosterRowView(items: row.items, watchlistIDs: library.watchlistIDs)
                }
            }
        }
        if !model.isSearching && model.hasSearched && presentation.visibleCount == 0 {
            if presentation.filteredOutCount > 0 {
                EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                               title: "Nessun risultato con questi filtri",
                               message: presentation.filteredOutCount == 1 ? "I filtri scelti nascondono 1 risultato." : "I filtri scelti nascondono \(presentation.filteredOutCount) risultati.",
                               actionTitle: "Reimposta filtri", action: { model.resetFilters() })
                    .accessibilityIdentifier("search.filteredOut")
            } else {
                EmptyStateView(systemImage: "magnifyingglass", title: "Nessun risultato", message: model.emptyMessage)
                    .accessibilityIdentifier("search.empty")
            }
        }
        ForEach(model.failedResults) { result in
            InlineErrorView(message: "\(result.addonName) · \(result.title): \(result.error?.message ?? "errore")")
        }
        footnotes
    }

    /// How the filters were applied: what went to the addons and what only Aether checked.
    @ViewBuilder
    private var footnotes: some View {
        if model.hasSearched && !model.filterNotes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.filterNotes, id: \.self) { note in
                    Text(note).font(.footnote).foregroundStyle(Color.aetherSecondary)
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("search.filterNote")
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        if library.searchHistory.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass", title: "Cerca in tutti i tuoi addon",
                           message: "La ricerca interroga solo i cataloghi che dichiarano il supporto alla ricerca, più la tua libreria locale.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeader(title: "Ricerche recenti")
                    Button("Cancella") { Task { await env.libraryStore.clearSearchHistory() } }
                        .font(.subheadline).padding(.trailing, Theme.pageMargin)
                }
                ForEach(library.searchHistory) { item in
                    Button { model.query = item.query } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.aetherSecondary)
                            Text(item.query)
                            Spacer()
                        }
                        .padding(.horizontal, Theme.pageMargin).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { Task { await env.libraryStore.removeSearch(item.query) } } label: {
                            Label("Rimuovi", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}
