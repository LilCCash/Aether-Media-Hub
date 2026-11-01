import Foundation
import SwiftUI
import AetherCore

private let traktSessionKey = "trakt.session.v1"

/// Trakt nell'app: collegamento con il codice, sincronizzazione, scrobble e cataloghi. Tutto spento finché non lo accendi
/// (Impostazioni ▸ Trakt) e non colleghi l'account.
@MainActor
final class TraktService: ObservableObject {
    enum State: Equatable {
        case disconnected
        case waiting(code: String, url: String, expires: Date)
        case connected
    }

    @Published private(set) var state: State
    @Published private(set) var user: TraktUser?
    @Published private(set) var message: String?
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastReport: String?

    let client: TraktClient
    let catalog: TraktCatalogService
    private let syncer: TraktSyncService
    private let settings: SettingsStore
    private var pollTask: Task<Void, Never>?
    private var lastScrobble: (action: TraktClient.ScrobbleAction, id: String)?

    init(http: HTTPClient, secrets: SecretStore, tmdb: TMDBClient, library: LibraryStore, settings: SettingsStore) {
        let store = TraktClient.SessionStore(
            load: {
                guard let text = (try? secrets.get(traktSessionKey)) ?? nil, let data = text.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(TraktSession.self, from: data)
            },
            save: { session in
                if let session = session, let data = try? JSONEncoder().encode(session), let text = String(data: data, encoding: .utf8) {
                    try? secrets.set(text, for: traktSessionKey)
                } else {
                    try? secrets.remove(traktSessionKey)
                }
            })
        let trakt = TraktClient(http: http, store: store)
        let shelves = TraktCatalogService(trakt: trakt, tmdb: tmdb)
        client = trakt
        catalog = shelves
        syncer = TraktSyncService(trakt: trakt, library: library, catalog: shelves)
        self.settings = settings
        state = store.load() != nil ? .connected : .disconnected
    }

    var options: TraktSettings { return settings.value.content.trakt }
    var isConnected: Bool { return state == .connected }
    /// Trakt è acceso e collegato.
    var isActive: Bool { return options.enabled && isConnected }

    /// Alla partenza dell'app: legge l'utente e, se richiesto, sincronizza.
    func bootstrap() async {
        guard isConnected else { return }
        await refreshUser()
        if options.enabled && options.syncOnLaunch { await syncNow() }
    }

    // MARK: Collegamento

    func connect() async {
        message = nil
        pollTask?.cancel()
        do {
            let code = try await client.startDeviceLogin()
            state = .waiting(code: code.userCode, url: code.verificationURL, expires: Date().addingTimeInterval(Double(code.expiresIn)))
            pollTask = Task { [weak self] in await self?.poll(code) }
        } catch let error as TraktError {
            message = error.message
        } catch {
            message = TraktError.network.message
        }
    }

    func cancelConnect() {
        pollTask?.cancel()
        pollTask = nil
        if case .waiting = state { state = .disconnected }
    }

    private func poll(_ code: TraktDeviceCode) async {
        var interval = code.interval
        let deadline = Date().addingTimeInterval(Double(code.expiresIn))
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            if Task.isCancelled { return }
            do {
                try await client.pollDeviceLogin(code)
                state = .connected
                message = nil
                await refreshUser()
                if options.enabled { await syncNow() }
                return
            } catch TraktError.pending {
                continue
            } catch TraktError.rateLimited {
                interval += 1
            } catch let error as TraktError {
                state = .disconnected
                message = error.message
                return
            } catch {
                state = .disconnected
                message = TraktError.network.message
                return
            }
        }
        if !Task.isCancelled {
            state = .disconnected
            message = TraktError.expired.message
        }
    }

    func disconnect() async {
        pollTask?.cancel()
        await client.logout()
        state = .disconnected
        user = nil
        lastReport = nil
        message = nil
    }

    func refreshUser() async {
        do {
            user = try await client.user()
        } catch TraktError.unauthorized {
            state = .disconnected
            message = TraktError.unauthorized.message
        } catch {
            // Senza rete si riprova più tardi: il collegamento resta.
        }
    }

    // MARK: Sincronizzazione

    func syncNow() async {
        guard isConnected, !syncing else { return }
        syncing = true
        message = nil
        defer { syncing = false }
        let language = SearchViewModel.tmdbLanguage(settings.value.content.preferredLanguage)
        do {
            let report = try await syncer.sync(settings: options, language: language)
            lastReport = report.summary
            lastSync = Date()
        } catch let error as TraktError {
            message = error.message
            if error == .unauthorized { state = .disconnected }
        } catch {
            message = TraktError.network.message
        }
    }

    /// Aggiunta o rimozione dalla lista di Aether: la ripete su Trakt.
    func watchlistChanged(_ meta: MetaItem, enabled: Bool) {
        guard isActive, options.syncWatchlist, meta.id.hasPrefix("tt") else { return }
        let client = self.client
        let isMovie = meta.type == "movie"
        let id = meta.id
        Task {
            if enabled {
                try? await client.addToWatchlist(movies: isMovie ? [id] : [], shows: isMovie ? [] : [id])
            } else {
                try? await client.removeFromWatchlist(movies: isMovie ? [id] : [], shows: isMovie ? [] : [id])
            }
        }
    }

    // MARK: Scrobble

    /// Dice a Trakt cosa sta succedendo nel lettore. Gli errori non disturbano la visione.
    func scrobble(_ action: TraktClient.ScrobbleAction, meta: MetaItem, video: Video?, position: Double, duration: Double) {
        guard isActive, options.scrobble else { return }
        let imdb = meta.id.hasPrefix("tt") ? meta.id.split(separator: ":").first.map(String.init) ?? meta.id : meta.externalIDs.imdb
        guard let code = imdb, code.hasPrefix("tt") else { return }
        var season: Int?
        var episode: Int?
        if meta.type == "series" {
            guard let video = video, let s = video.season, let e = video.episode, s > 0 else { return }
            season = s
            episode = e
        }
        let identifier = "\(code)|\(season ?? 0)|\(episode ?? 0)"
        if let last = lastScrobble, last.action == action, last.id == identifier, action != .pause { return }
        lastScrobble = (action, identifier)
        let progress = duration > 0 ? min(100, max(0, position / duration * 100)) : 0
        let client = self.client
        Task { try? await client.scrobble(action, imdb: code, season: season, episode: episode, progress: progress) }
    }
}
