import SwiftUI
import AetherCore

/// Main-actor, observable snapshot of the library for SwiftUI. Refreshed whenever the store mutates.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var continueWatching: [PlaybackProgress] = []
    @Published private(set) var watchlist: [LibraryEntry] = []
    @Published private(set) var favorites: [LibraryEntry] = []
    @Published private(set) var history: [PlaybackProgress] = []
    @Published private(set) var nextUpSeeds: [PlaybackProgress] = []
    @Published private(set) var searchHistory: [SearchHistoryItem] = []
    @Published private(set) var watchlistIDs = Set<String>()
    @Published private(set) var favoriteIDs = Set<String>()

    let store: LibraryStore
    private var observer: Task<Void, Never>?

    init(store: LibraryStore) {
        self.store = store
    }

    deinit {
        observer?.cancel()
    }

    func start() {
        guard observer == nil else { return }
        let store = self.store
        observer = Task { [weak self] in
            let updates = await store.updates()
            for await _ in updates {
                // Coalesce bursts (the player writes progress every few seconds).
                try? await Task.sleep(nanoseconds: 250_000_000)
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        async let cont = store.continueWatching()
        async let wl = store.watchlist()
        async let fav = store.favorites()
        async let hist = store.history(limit: 300)
        async let seeds = store.nextUpSeeds()
        async let searches = store.searchHistory()
        let (c, w, f, h, s, q) = await (cont, wl, fav, hist, seeds, searches)
        continueWatching = c
        watchlist = w
        favorites = f
        history = h
        nextUpSeeds = s
        searchHistory = q
        watchlistIDs = Set(w.map { $0.id })
        favoriteIDs = Set(f.map { $0.id })
    }

    func toggleWatchlist(_ meta: MetaItem) {
        let enable = !watchlistIDs.contains(meta.id)
        // Optimistic: buttons react instantly.
        if enable { watchlistIDs.insert(meta.id) } else { watchlistIDs.remove(meta.id) }
        Task { await store.setWatchlist(enable, meta: meta) }
    }

    func toggleFavorite(_ meta: MetaItem) {
        let enable = !favoriteIDs.contains(meta.id)
        if enable { favoriteIDs.insert(meta.id) } else { favoriteIDs.remove(meta.id) }
        Task { await store.setFavorite(enable, meta: meta) }
    }

    func flush() {
        let store = self.store
        Task { await store.flush() }
    }
}
