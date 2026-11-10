import SwiftUI
import AetherCore

enum LibrarySection: String, CaseIterable, Identifiable {
    case continueWatching, watchlist, favorites, watched, abandoned, collections, history, downloads, cloud
    var id: String { rawValue }

    var title: String {
        switch self {
        case .continueWatching: return "Continua"
        case .watchlist: return "Watchlist"
        case .favorites: return "Preferiti"
        case .watched: return "Visti"
        case .abandoned: return "Abbandonati"
        case .collections: return "Collezioni"
        case .history: return "Cronologia"
        case .downloads: return "Download"
        case .cloud: return "Cloud"
        }
    }
}

struct LibraryView: View {
    @Namespace private var chipSpace
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var section: LibrarySection = .continueWatching
    @EnvironmentObject private var router: AppRouter
    @State private var filter = ""
    @State private var confirmClear = false

    /// With Trakt connected but its list not merged into the app's, the viewer chooses which of the two lists to see.
    private var choosesList: Bool {
        let trakt = settings.value.content.trakt
        return trakt.enabled && env.trakt.isConnected && !trakt.syncWatchlist
    }
    private var showsTrakt: Bool { return choosesList && settings.value.content.trakt.libraryList == "trakt" }

    var body: some View {
        page
            .onAppear { takeRequestedSection() }
            .onChange(of: router.librarySection) { _, _ in takeRequestedSection() }
    }

    private func takeRequestedSection() {
        guard let raw = router.librarySection else { return }
        router.librarySection = nil
        if let wanted = LibrarySection(rawValue: raw) { section = wanted }
    }

    private var page: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                if showsTrakt {
                    TraktCatalogView(trakt: env.trakt)
                } else {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(LibrarySection.allCases) { item in
                                FilterChip(title: item.title, isSelected: section == item, slide: chipSpace) {
                                    withAnimation(settings.animationsEnabled ? .snappy : nil) { section = item }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.pageMargin)
                        .padding(.vertical, 8)
                    }
                    .accessibilityIdentifier("library.picker")
                    content
                }
                }
            }
            .navigationTitle("Libreria")
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0).zoomDestination(id: $0.id) }
            .searchable(text: $filter, prompt: "Filtra nella sezione")
            .toolbar {
                if choosesList {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Lista", selection: Binding(get: { settings.value.content.trakt.libraryList == "trakt" ? "trakt" : "aether" },
                                                               set: { settings.value.content.trakt.libraryList = $0 })) {
                                Label("Lista Aether", systemImage: "books.vertical").tag("aether")
                                Label("Lista Trakt", systemImage: "play.square.stack").tag("trakt")
                            }
                        } label: {
                            Label(showsTrakt ? "Trakt" : "Aether", systemImage: "chevron.down.circle")
                        }
                        .accessibilityIdentifier("library.listMenu")
                    }
                }
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
                    // Three wide cards a row, sized by the grid itself: every column takes a third of the row, edge to edge.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 18) {
                        ForEach(items) { item in
                            ContinueCard(progress: item, width: nil, cardStyle: .landscape)
                        }
                    }
                    .padding(.horizontal, Theme.pageMargin)
                    .padding(.vertical, Theme.pageMargin)
                }
            }
        case .watchlist:
            posterGrid(library.watchlist.filter { matches($0.name) }, empty: ("bookmark", "Watchlist vuota", "Aggiungi titoli dalla loro scheda con il segnalibro."))
        case .favorites:
            posterGrid(library.favorites.filter { matches($0.name) }, empty: ("heart", "Nessun preferito", "Tocca il cuore nella scheda di un titolo per salvarlo qui."))
        case .watched:
            let diary = settings.value.content.diary.timeline
            let seen = Set(diary.map { $0.metaID })
            let fromPlayer = library.history.filter { $0.isCompleted && !seen.contains($0.metaID) }
            let entries = (diary.map { MetaItem(id: $0.metaID, type: $0.type, name: $0.name, poster: $0.poster) } + fromPlayer.map { $0.asMeta })
                .filter { matches($0.name) }
            if entries.isEmpty {
                emptyState("checkmark.circle", "Niente di visto", "I titoli che finisci o segni nel diario compaiono qui.")
            } else {
                ScrollView {
                    let width = CGFloat(settings.value.appearance.posterSize.rowWidth)
                    AdaptiveCardGrid(items: entries, minColumns: 3, preferredWidth: width, spacing: 12, rowSpacing: 20) { meta, cardWidth in
                        TitleLink(route: MetaRoute(meta: meta)) { PosterCard(meta: meta, width: cardWidth) }.buttonStyle(.plain)
                    }
                    .padding(.vertical, Theme.pageMargin)
                }
            }
        case .abandoned:
            // Started and not finished, untouched for a month: the viewer can pick them up again or let them go.
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            let items = library.history.filter { !$0.isCompleted && $0.updatedAt < cutoff && matches($0.title) }
            if items.isEmpty {
                emptyState("pause.circle", "Nessun titolo abbandonato", "Quello che inizi e lasci per più di un mese compare qui.")
            } else {
                ScrollView {
                    // Three wide cards a row, sized by the grid itself: every column takes a third of the row, edge to edge.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 18) {
                        ForEach(items) { item in
                            ContinueCard(progress: item, width: nil, cardStyle: .landscape)
                        }
                    }
                    .padding(.horizontal, Theme.pageMargin)
                    .padding(.vertical, Theme.pageMargin)
                }
            }
        case .collections:
            CollectionsView()
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
                        TitleLink(route: MetaRoute(meta: item.asMeta)) { HistoryRow(item: item) }
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
        case .cloud:
            CloudLibraryView(filter: filter)
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
                        TitleLink(route: MetaRoute(meta: entry.asMeta)) {
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
                .clipShape(RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
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
