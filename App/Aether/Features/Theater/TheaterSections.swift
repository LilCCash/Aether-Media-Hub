import SwiftUI
import AetherCore

/// A vertical stack of rows on the Theater backdrop with a title: the shape of every Theater screen.
struct TheaterPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            TheaterBackground()
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text(title).font(.system(size: 30, weight: .bold, design: .serif)).foregroundStyle(.white).padding(.leading, 24)
                    content()
                    Color.clear.frame(height: 24)
                }
                .padding(.top, 14)
            }
        }
    }
}

/// Library in Theater style: the watchlist, the favourites and what was watched.
struct TheaterLibrary: View {
    @EnvironmentObject private var library: LibraryModel
    let open: (MetaItem) -> Void

    var body: some View {
        TheaterPage(title: "Libreria") {
            if library.watchlist.isEmpty && library.favorites.isEmpty && library.history.isEmpty {
                Text("Qui compaiono la tua watchlist, i preferiti e ciò che hai guardato.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6)).padding(.leading, 24)
            }
            if !library.watchlist.isEmpty { TheaterRow(title: "La mia watchlist", items: library.watchlist.map { $0.asMeta }, open: open) }
            if !library.favorites.isEmpty { TheaterRow(title: "Preferiti", items: library.favorites.map { $0.asMeta }, open: open) }
            if !library.history.isEmpty { TheaterRow(title: "Visti di recente", items: library.history.prefix(30).map { $0.asMeta }, open: open) }
        }
    }
}

/// Every catalogue of the addons, with a filter by kind of content.
struct TheaterDiscover: View {
    let refs: [CatalogRef]
    let open: (MetaItem) -> Void
    @State private var filter: String?

    private var types: [String] { Array(Set(refs.map { $0.type })).sorted() }

    var body: some View {
        TheaterPage(title: "Scopri") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Tutti", nil)
                    ForEach(types, id: \.self) { chip(RequestPlanner.friendlyTypeName($0), $0) }
                }
                .padding(.horizontal, 24)
            }
            ForEach(refs.filter { filter == nil || $0.type == filter }) { ref in
                TheaterCatalogRow(ref: ref, open: open).id(ref.id)
            }
        }
    }

    private func chip(_ title: String, _ value: String?) -> some View {
        Button { filter = value } label: {
            Text(title).font(.footnote.weight(.semibold)).padding(.horizontal, 14).frame(height: 32)
                .background(filter == value ? Color.white : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(filter == value ? Color.black : .white)
        }
    }
}

/// Search in Theater style: a field and the results of all the addons as one row per catalogue.
struct TheaterSearch: View {
    @EnvironmentObject private var env: AppEnvironment
    let open: (MetaItem) -> Void
    @State private var query = ""
    @State private var rows: [SearchRow] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        TheaterPage(title: "Cerca") {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("Cerca film e serie", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { run() }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("theater.search.field")
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 24)
            ForEach(rows.filter { !$0.items.isEmpty }) { row in
                TheaterRow(title: row.ref.title, items: row.items, open: open)
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func run() {
        task?.cancel()
        rows = []
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task = Task {
            for await update in env.searchService.search(query: text) {
                if Task.isCancelled { return }
                rows.removeAll { $0.id == update.row.id }
                rows.append(update.row)
            }
        }
    }
}
