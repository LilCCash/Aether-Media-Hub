import SwiftUI
import AetherCore

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var rows: [SearchRow] = []
    @Published private(set) var localResults: [MetaItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var searchableCatalogCount = 0
    @Published private(set) var hasSearched = false
    @Published var sort: SearchSort = .relevance

    var merged: [MetaItem] {
        let ordered = rows.sorted { lhs, rhs in lhs.ref.addonName < rhs.ref.addonName }
        return sort.apply(to: MetaDeduper.interleave(ordered.map { $0.items }))
    }

    var failedRows: [SearchRow] { rows.filter { $0.error != nil } }

    func prepare(env: AppEnvironment) async {
        searchableCatalogCount = await env.searchService.searchableCatalogs().count
        sort = env.settings.value.content.searchSort
    }

    func run(env: AppEnvironment) async {
        let normalised = SearchService.normalisedQuery(query)
        guard normalised.count >= 2 else {
            rows = []; localResults = []; isSearching = false; hasSearched = false
            return
        }
        // Debounce: a newer keystroke cancels this task (via `.task(id:)`) before any request is made.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        let content = env.settings.value.content
        hasSearched = true
        rows = []
        if content.searchLocal {
            localResults = await env.libraryStore.searchLocal(normalised)
        } else {
            localResults = []
        }
        guard content.searchRemote else { isSearching = false; return }
        isSearching = true
        progress = (0, 0)
        for await update in env.searchService.search(query: normalised) {
            if Task.isCancelled { return }
            rows.append(update.row)
            progress = (update.completed, update.total)
        }
        if Task.isCancelled { return }
        isSearching = false
    }
}

struct SearchView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = SearchViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                content
            }
            .navigationTitle("Cerca")
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Film, serie, canali…")
            .autocorrectionDisabled()
            .onSubmit(of: .search) {
                let text = model.query
                Task { await env.libraryStore.addSearch(text) }
            }
            .task(id: model.query) { await model.run(env: env) }
            .task(id: addons.revision) { await model.prepare(env: env) }
            .onChange(of: router.pendingSearch) { _, new in
                if let new = new { model.query = new; router.pendingSearch = nil }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if model.searchableCatalogCount == 0 && settings.value.content.searchRemote {
                    InlineErrorView(message: "Nessun addon attivo dichiara la ricerca nei suoi cataloghi: posso cercare solo nella tua libreria.")
                        .padding(.top, 8)
                }
                if model.query.trimmingCharacters(in: .whitespaces).count < 2 {
                    idleContent
                } else {
                    if model.isSearching {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Cerco in \(model.progress.total > 0 ? "\(model.progress.done)/\(model.progress.total)" : "…") cataloghi")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Theme.pageMargin)
                        .accessibilityIdentifier("search.progress")
                    }
                    if !model.localResults.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Nella tua libreria")
                            PosterRowView(items: model.localResults, watchlistIDs: library.watchlistIDs)
                        }
                    }
                    let merged = model.merged
                    if !merged.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                SectionHeader(title: "Migliori risultati")
                                Menu {
                                    Picker("Ordina", selection: $model.sort) {
                                        ForEach(SearchSort.allCases, id: \.self) { Text($0.title).tag($0) }
                                    }
                                } label: {
                                    Image(systemName: "arrow.up.arrow.down.circle").font(.title3)
                                }
                                .padding(.trailing, Theme.pageMargin)
                                .accessibilityLabel("Ordina i risultati")
                            }
                            PosterRowView(items: Array(merged.prefix(40)), watchlistIDs: library.watchlistIDs)
                        }
                        .accessibilityIdentifier("search.merged")
                        ForEach(model.rows.filter { !$0.items.isEmpty }) { row in
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: row.ref.title, subtitle: "\(row.ref.addonName) · \(RequestPlanner.friendlyTypeName(row.ref.type))")
                                PosterRowView(items: model.sort.apply(to: row.items), watchlistIDs: library.watchlistIDs)
                            }
                        }
                    }
                    if !model.isSearching && model.hasSearched && merged.isEmpty && model.localResults.isEmpty {
                        EmptyStateView(systemImage: "magnifyingglass", title: "Nessun risultato",
                                       message: "Non ho trovato «\(model.query)» in \(model.rows.count) cataloghi.")
                            .accessibilityIdentifier("search.empty")
                    }
                    ForEach(model.failedRows) { row in
                        InlineErrorView(message: "\(row.ref.addonName) · \(row.ref.title): \(row.error?.message ?? "errore")")
                    }
                }
                Color.clear.frame(height: 24)
            }
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
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
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
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
