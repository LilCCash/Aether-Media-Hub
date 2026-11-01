import SwiftUI
import AetherCore

/// Altro ▸ Trakt: i cataloghi di Trakt (in tendenza, popolari, consigliati, la tua lista, le tue liste, da riprendere, calendario).
struct TraktCatalogView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var trakt: TraktService

    private var options: TraktSettings { settings.value.content.trakt }

    private var kinds: [TraktCatalogKind] {
        return TraktCatalogKind.allCases.filter { options.isCatalogVisible($0) && (!$0.needsLogin || trakt.isConnected) }
    }

    var body: some View {
        ZStack {
            AetherBackdrop()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if !options.enabled {
                        EmptyStateView(systemImage: "play.square.stack", title: "Trakt è spento",
                                       message: "Accendilo e collega il tuo account in Impostazioni ▸ Trakt.")
                    } else {
                        if !trakt.isConnected {
                            InlineErrorView(message: "Collega il tuo account (Impostazioni ▸ Trakt) per vedere watchlist, consigliati, liste e calendario. Intanto ci sono i cataloghi pubblici.")
                                .padding(.horizontal, Theme.pageMargin)
                        }
                        ForEach(kinds, id: \.self) { kind in
                            TraktShelfSection(title: kind.title, trakt: trakt, limit: options.itemsPerCatalog, source: .catalog(kind))
                        }
                        if trakt.isConnected && options.showLists {
                            TraktListsSection(trakt: trakt, limit: options.itemsPerCatalog)
                        }
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.top, 8)
            }
        }
        .navigationTitle("Trakt")
        .navigationDestination(for: MetaRoute.self) { DetailView(route: $0).zoomDestination(id: $0.id) }
    }
}

private enum TraktShelfSource: Hashable {
    case catalog(TraktCatalogKind)
    case list(Int)
}

/// Una riga di titoli, caricata quando compare.
private struct TraktShelfSection: View {
    let title: String
    @ObservedObject var trakt: TraktService
    let limit: Int
    let source: TraktShelfSource
    var list: TraktListInfo?

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @State private var items: [TraktShelfItem] = []
    @State private var state: LoadState = .loading

    private enum LoadState: Equatable {
        case loading, loaded
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            switch state {
            case .loading:
                ProgressView().padding(.horizontal, Theme.pageMargin)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(Color.aetherSecondary).padding(.horizontal, Theme.pageMargin)
            case .loaded:
                if items.isEmpty {
                    Text("Niente da mostrare.").font(.footnote).foregroundStyle(Color.aetherSecondary).padding(.horizontal, Theme.pageMargin)
                } else {
                    PosterRowView(items: items.map { $0.meta }, watchlistIDs: library.watchlistIDs)
                }
            }
        }
        .task(id: "\(source.hashValue)-\(limit)-\(trakt.isConnected)") { await load() }
    }

    private func load() async {
        state = .loading
        let language = SearchViewModel.tmdbLanguage(settings.value.content.preferredLanguage)
        do {
            switch source {
            case .catalog(let kind):
                items = try await trakt.catalog.items(for: kind, limit: limit, language: language)
            case .list:
                if let list = list { items = try await trakt.catalog.listItems(list, limit: limit, language: language) }
            }
            state = .loaded
        } catch let error as TraktError {
            state = .failed(error.message)
        } catch {
            state = .failed(TraktError.network.message)
        }
    }
}

/// Le liste personali dell'utente, ognuna con i suoi titoli.
private struct TraktListsSection: View {
    @ObservedObject var trakt: TraktService
    let limit: Int
    @State private var lists: [TraktListInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(lists) { list in
                TraktShelfSection(title: "\(list.name) (\(list.itemCount))", trakt: trakt, limit: limit, source: .list(list.id), list: list)
            }
        }
        .task(id: trakt.isConnected) {
            lists = (try? await trakt.catalog.lists()) ?? []
        }
    }
}
