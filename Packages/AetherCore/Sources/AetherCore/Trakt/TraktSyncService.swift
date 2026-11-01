import Foundation

public struct TraktSyncReport: Equatable, Sendable {
    public var watchlistImported = 0
    public var watchlistPushed = 0
    public var watchedImported = 0
    public var watchedPushed = 0

    public init() {}

    public var summary: String {
        return "Watchlist: \(watchlistImported) da Trakt, \(watchlistPushed) verso Trakt. Visti: \(watchedImported) da Trakt, \(watchedPushed) verso Trakt."
    }
}

/// Mette d'accordo la libreria di Aether con l'account Trakt: watchlist e titoli visti, nei due sensi. Non cancella mai niente:
/// aggiunge a ciò che manca da una parte o dall'altra (le rimozioni passano dal pulsante, una alla volta).
public final class TraktSyncService: @unchecked Sendable {
    private let trakt: TraktClient
    private let library: LibraryStore
    private let catalog: TraktCatalogService

    /// Per non appesantire una sincronizzazione sola.
    private static let importCap = 150
    private static let pushCap = 300

    public init(trakt: TraktClient, library: LibraryStore, catalog: TraktCatalogService) {
        self.trakt = trakt
        self.library = library
        self.catalog = catalog
    }

    public func sync(settings: TraktSettings, language: String) async throws -> TraktSyncReport {
        var report = TraktSyncReport()
        if settings.syncWatchlist { try await syncWatchlist(&report, language: language) }
        if settings.syncWatched { try await syncWatched(&report, language: language) }
        return report
    }

    private func syncWatchlist(_ report: inout TraktSyncReport, language: String) async throws {
        let remote = try await trakt.titles(for: .watchlist, limit: 1000)
        let local = await library.watchlist()
        let localIDs = Set(local.map { $0.id })
        let remoteIDs = Set(remote.compactMap { $0.imdb })

        let missing = Array(remote.filter { ($0.imdb.map { !localIDs.contains($0) }) ?? false }.prefix(Self.importCap))
        if !missing.isEmpty {
            for item in await catalog.shelf(missing, language: language) {
                await library.setWatchlist(true, meta: item.meta)
                report.watchlistImported += 1
            }
        }

        let toPush = local.filter { $0.id.hasPrefix("tt") && !remoteIDs.contains($0.id) }.prefix(Self.pushCap)
        let movies = toPush.filter { $0.type == "movie" }.map { $0.id }
        let shows = toPush.filter { $0.type == "series" }.map { $0.id }
        if !movies.isEmpty || !shows.isEmpty {
            try await trakt.addToWatchlist(movies: movies, shows: shows)
            report.watchlistPushed = movies.count + shows.count
        }
    }

    private func syncWatched(_ report: inout TraktSyncReport, language: String) async throws {
        let history = await library.history(limit: 20_000).filter { $0.isCompleted }
        let localMovies = Set(history.filter { $0.type == "movie" }.map { $0.metaID })
        var localEpisodes = Set<String>()
        for entry in history where entry.type == "series" {
            if let season = entry.season, let episode = entry.episode { localEpisodes.insert("\(entry.metaID)|\(season)|\(episode)") }
        }

        // Da Trakt ad Aether.
        let remoteMovies = try await trakt.watchedMovies()
        let missingMovies = Array(remoteMovies.filter { ($0.imdb.map { !localMovies.contains($0) }) ?? false }.prefix(Self.importCap))
        if !missingMovies.isEmpty {
            for item in await catalog.shelf(missingMovies, language: language) {
                await library.markWatched(true, meta: item.meta, video: nil)
                report.watchedImported += 1
            }
        }
        let remoteShows = try await trakt.watchedShows()
        var remoteEpisodes = Set<String>()
        var budget = Self.importCap * 2
        for entry in remoteShows {
            guard let imdb = entry.show.imdb else { continue }
            var videos: [Video] = []
            for episode in entry.episodes {
                let key = "\(imdb)|\(episode.season)|\(episode.number)"
                remoteEpisodes.insert(key)
                if !localEpisodes.contains(key), budget > 0 {
                    videos.append(Video(id: "\(imdb):\(episode.season):\(episode.number)", title: "Episodio \(episode.number)", season: episode.season, episode: episode.number))
                    budget -= 1
                }
            }
            if !videos.isEmpty {
                let meta = MetaItem(id: imdb, type: "series", name: entry.show.title, releaseInfo: entry.show.year.map { String($0) },
                                    externalIDs: ExternalIDs(imdb: imdb, tmdb: entry.show.tmdb, tvdb: entry.show.tvdb))
                await library.markWatched(true, meta: meta, videos: videos)
                report.watchedImported += videos.count
            }
        }

        // Da Aether a Trakt.
        let remoteMovieIDs = Set(remoteMovies.compactMap { $0.imdb })
        let pushMovies = Array(localMovies.filter { $0.hasPrefix("tt") && !remoteMovieIDs.contains($0) }.prefix(Self.pushCap))
        var pushEpisodes: [(show: String, season: Int, number: Int)] = []
        for entry in history where entry.type == "series" && entry.metaID.hasPrefix("tt") {
            guard let season = entry.season, let episode = entry.episode, season > 0 else { continue }
            if !remoteEpisodes.contains("\(entry.metaID)|\(season)|\(episode)"), pushEpisodes.count < Self.pushCap {
                pushEpisodes.append((entry.metaID, season, episode))
            }
        }
        if !pushMovies.isEmpty || !pushEpisodes.isEmpty {
            try await trakt.addToHistory(movies: pushMovies, episodes: pushEpisodes)
            report.watchedPushed = pushMovies.count + pushEpisodes.count
        }
    }
}
