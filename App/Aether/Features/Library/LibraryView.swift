import SwiftUI
import AetherCore

enum LibrarySection: String, CaseIterable, Identifiable {
    case continueWatching, watchlist, favorites, history, downloads
    var id: String { rawValue }

    var title: String {
        switch self {
        case .continueWatching: return "Continua"
        case .watchlist: return "Watchlist"
        case .favorites: return "Preferiti"
        case .history: return "Cronologia"
        case .downloads: return "Download"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var section: LibrarySection = .continueWatching
    @State private var filter = ""
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                VStack(spacing: 0) {
                    Picker("Sezione", selection: $section) {
                        ForEach(LibrarySection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.pageMargin)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("library.picker")
                    content
                }
            }
            .navigationTitle("Libreria")
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
            .searchable(text: $filter, prompt: "Filtra nella sezione")
            .toolbar {
                if section == .history && !library.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Cancella la cronologia")
                    }
                }
            }
            .confirmationDialog("Cancellare tutta la cronologia?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Cancella cronologia e punti di ripresa", role: .destructive) {
                    Task { await env.libraryStore.clearHistory() }
                }
            } message: {
                Text("I punti di ripresa e gli episodi segnati come visti verranno rimossi. Watchlist e preferiti restano.")
            }
        }
    }

    private func matches(_ text: String) -> Bool {
        return filter.isEmpty || MetaDeduper.normalise(text).contains(MetaDeduper.normalise(filter))
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .continueWatching:
            let items = library.continueWatching.filter { matches($0.title) }
            if items.isEmpty {
                emptyState("play.circle", "Niente da riprendere", "Quando interrompi un film o un episodio lo trovi qui, con il punto esatto.")
            } else {
                ScrollView {
                    // At least two cards per row, sized to the columns so that both sides have the same margin.
                    AdaptiveCardGrid(items: items, minColumns: 2, preferredWidth: 240, spacing: 14, rowSpacing: 18) { item, cardWidth in
                        ContinueCard(progress: item, width: cardWidth)
                    }
                    .padding(.vertical, Theme.pageMargin)
                }
            }
        case .watchlist:
            posterGrid(library.watchlist.filter { matches($0.name) }, empty: ("bookmark", "Watchlist vuota", "Aggiungi titoli dalla loro scheda con il segnalibro."))
        case .favorites:
            posterGrid(library.favorites.filter { matches($0.name) }, empty: ("heart", "Nessun preferito", "Tocca il cuore nella scheda di un titolo per salvarlo qui."))
        case .history:
            let items = library.history.filter { matches($0.title) }
            if items.isEmpty {
                emptyState("clock.arrow.circlepath", "Cronologia vuota",
                           settings.value.privacy.recordHistory
                           ? "I titoli che guardi compariranno qui."
                           : "La registrazione della cronologia è disattivata in Impostazioni → Account e dati.")
            } else {
                List {
                    ForEach(items) { item in
                        NavigationLink(value: MetaRoute(meta: item.asMeta)) { HistoryRow(item: item) }
                            .swipeActions {
                                Button(role: .destructive) { Task { await env.libraryStore.removeHistory(id: item.id) } } label: {
                                    Label("Elimina", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("library.history")
            }
        case .downloads:
            DownloadsView(filter: filter)
        }
    }

    private func posterGrid(_ entries: [LibraryEntry], empty: (String, String, String)) -> some View {
        Group {
            if entries.isEmpty {
                emptyState(empty.0, empty.1, empty.2)
            } else {
                ScrollView {
                    let width = CGFloat(settings.value.appearance.posterSize.rowWidth)
                    AdaptiveCardGrid(items: entries, minColumns: 3, preferredWidth: width, spacing: 12, rowSpacing: 20) { entry, cardWidth in
                        NavigationLink(value: MetaRoute(meta: entry.asMeta)) {
                            PosterCard(meta: entry.asMeta, width: cardWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                library.toggleWatchlist(entry.asMeta)
                            } label: { Label("Rimuovi dalla watchlist", systemImage: "bookmark.slash") }
                            .disabled(!entry.inWatchlist)
                        }
                    }
                    .padding(.vertical, Theme.pageMargin)
                }
                .accessibilityIdentifier("library.grid")
            }
        }
    }

    private func emptyState(_ icon: String, _ title: String, _ message: String) -> some View {
        ScrollView {
            EmptyStateView(systemImage: icon, title: title, message: message).padding(.top, 60)
        }
        .accessibilityIdentifier("library.empty")
    }
}

struct HistoryRow: View {
    let item: PlaybackProgress

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(urlString: item.poster, width: 100, placeholderSeed: item.title)
                .frame(width: 44, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(.subheadline, design: AetherTypography.design).weight(.semibold)).lineLimit(1)
                if let label = item.episodeLabel {
                    Text([label, item.episodeTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(Format.relativeDate(item.updatedAt))
                    if item.isCompleted { Label("Visto", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else if item.duration > 0 { Text("· \(Int(item.fraction * 100))%") }
                }
                .font(.caption2).foregroundStyle(Color.aetherSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
