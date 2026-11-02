import Foundation

/// Client di Trakt (api.trakt.tv). Il collegamento usa il «device code»: nessun segreto nell'app, solo il Client ID pubblico.
/// I token restano dove li mette `sessionStore` (il Portachiavi, nell'app); qui non si scrivono mai nei log.
public actor TraktClient {
    /// Il Client ID dell'app Aether registrata su Trakt. Non è un segreto: compare in ogni richiesta.
    public static let clientID = "anVbgfu810H1J949IJQlyAlzT7klUdxZbGVb0kEpGfc"
    public static let baseURL = URL(string: "https://api.trakt.tv")!

    public struct SessionStore: Sendable {
        public var load: @Sendable () -> TraktSession?
        public var save: @Sendable (TraktSession?) -> Void

        public init(load: @escaping @Sendable () -> TraktSession?, save: @escaping @Sendable (TraktSession?) -> Void) {
            self.load = load
            self.save = save
        }
    }

    private let http: HTTPClient
    private let store: SessionStore
    private let base: URL
    private var session: TraktSession?
    private var refreshing: Task<TraktSession, Error>?

    public init(http: HTTPClient, store: SessionStore, base: URL = TraktClient.baseURL) {
        self.http = http
        self.store = store
        self.base = base
        self.session = store.load()
    }

    public var isConnected: Bool { return session != nil }

    // MARK: Collegamento (device code)

    public func startDeviceLogin() async throws -> TraktDeviceCode {
        let object = try await postJSON("/oauth/device/code", body: ["client_id": TraktClient.clientID], authorized: false)
        guard let dict = object as? [String: Any],
              let device = dict["device_code"] as? String, let user = dict["user_code"] as? String,
              let url = dict["verification_url"] as? String else { throw TraktError.malformed }
        let expires = (dict["expires_in"] as? Int) ?? 600
        let interval = (dict["interval"] as? Int) ?? 5
        return TraktDeviceCode(deviceCode: device, userCode: user, verificationURL: url, expiresIn: expires, interval: max(1, interval))
    }

    /// Una sola verifica: `.pending` finché l'utente non ha inserito il codice.
    public func pollDeviceLogin(_ code: TraktDeviceCode) async throws {
        let request = try makeRequest(path: "/oauth/device/token", method: "POST", body: ["code": code.deviceCode, "client_id": TraktClient.clientID], authorized: false)
        let response = try await send(request)
        switch response.statusCode {
        case 200:
            session = try Self.session(from: response.data)
            store.save(session)
        case 400: throw TraktError.pending
        case 429: throw TraktError.rateLimited
        case 418: throw TraktError.denied
        case 410, 404, 409: throw TraktError.expired
        default: throw TraktError.server(response.statusCode)
        }
    }

    public func logout() async {
        if let token = session?.accessToken {
            _ = try? await postJSON("/oauth/revoke", body: ["token": token, "client_id": TraktClient.clientID], authorized: false)
        }
        session = nil
        store.save(nil)
    }

    static func session(from data: Data) throws -> TraktSession {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = object["access_token"] as? String, let refresh = object["refresh_token"] as? String else { throw TraktError.malformed }
        let created = (object["created_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let expires = (object["expires_in"] as? Double) ?? 7 * 86_400
        return TraktSession(accessToken: access, refreshToken: refresh, createdAt: created, expiresIn: expires)
    }

    // MARK: Rinnovo (il token di rinnovo vale una sola volta: si salva subito quello nuovo)

    private func validSession() async throws -> TraktSession {
        guard let current = session else { throw TraktError.notConnected }
        guard current.needsRefresh() else { return current }
        return try await refresh()
    }

    private func refresh() async throws -> TraktSession {
        if let running = refreshing { return try await running.value }
        guard let current = session else { throw TraktError.notConnected }
        let task = Task<TraktSession, Error> { [self] in
            let request = try self.makeRequest(path: "/oauth/token", method: "POST", body: [
                "refresh_token": current.refreshToken, "client_id": TraktClient.clientID,
                "redirect_uri": "http://localhost", "grant_type": "refresh_token",
            ], authorized: false)
            let response = try await self.send(request)
            guard response.isSuccess else {
                if response.statusCode == 400 || response.statusCode == 401 { throw TraktError.unauthorized }
                throw TraktError.server(response.statusCode)
            }
            return try Self.session(from: response.data)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let renewed = try await task.value
            session = renewed
            store.save(renewed)
            return renewed
        } catch TraktError.unauthorized {
            // Il token di rinnovo non vale più: serve ricollegare.
            session = nil
            store.save(nil)
            throw TraktError.unauthorized
        }
    }

    // MARK: Utente

    public func user() async throws -> TraktUser {
        let object = try await getJSON("/users/settings", authorized: true)
        guard let dict = object as? [String: Any], let user = dict["user"] as? [String: Any],
              let name = user["username"] as? String else { throw TraktError.malformed }
        let limits = dict["limits"] as? [String: Any]
        let watchlist = (limits?["watchlist"] as? [String: Any])?["item_count"] as? Int
        let lists = (limits?["list"] as? [String: Any])?["count"] as? Int
        return TraktUser(username: name, vip: (user["vip"] as? Bool) ?? false, watchlistLimit: watchlist, listLimit: lists)
    }

    // MARK: Cataloghi

    public func titles(for kind: TraktCatalogKind, limit: Int) async throws -> [TraktTitle] {
        let query = "?limit=\(limit)"
        switch kind {
        case .trendingMovies: return Self.parseWrapped(try await getJSON("/movies/trending" + query, authorized: false), key: "movie", kind: .movie, note: Self.noteWatchers)
        case .trendingShows: return Self.parseWrapped(try await getJSON("/shows/trending" + query, authorized: false), key: "show", kind: .show, note: Self.noteWatchers)
        case .popularMovies: return Self.parsePlain(try await getJSON("/movies/popular" + query, authorized: false), kind: .movie)
        case .popularShows: return Self.parsePlain(try await getJSON("/shows/popular" + query, authorized: false), kind: .show)
        case .anticipatedMovies: return Self.parseWrapped(try await getJSON("/movies/anticipated" + query, authorized: false), key: "movie", kind: .movie, note: Self.noteLists)
        case .anticipatedShows: return Self.parseWrapped(try await getJSON("/shows/anticipated" + query, authorized: false), key: "show", kind: .show, note: Self.noteLists)
        case .boxOffice: return Self.parseWrapped(try await getJSON("/movies/boxoffice", authorized: false), key: "movie", kind: .movie, note: Self.noteRevenue)
        case .recommendedMovies: return Self.parsePlain(try await getJSON("/recommendations/movies" + query, authorized: true), kind: .movie)
        case .recommendedShows: return Self.parsePlain(try await getJSON("/recommendations/shows" + query, authorized: true), kind: .show)
        case .watchlist:
            let movies = try await getJSON("/sync/watchlist/movies?sort=added,desc", authorized: true)
            let shows = try await getJSON("/sync/watchlist/shows?sort=added,desc", authorized: true)
            let all = Self.parseWrapped(movies, key: "movie", kind: .movie, note: nil) + Self.parseWrapped(shows, key: "show", kind: .show, note: nil)
            return Array(all.prefix(max(limit, 50)))
        case .continueWatching:
            return Array(Self.parsePlayback(try await getJSON("/sync/playback?limit=\(limit)", authorized: true)).prefix(limit))
        case .calendar:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            let day = formatter.string(from: Date())
            return Array(Self.parseCalendar(try await getJSON("/calendars/my/shows/\(day)/14", authorized: true)).prefix(limit))
        }
    }

    public func lists() async throws -> [TraktListInfo] {
        let object = try await getJSON("/users/me/lists", authorized: true)
        return (object as? [[String: Any]] ?? []).compactMap { entry -> TraktListInfo? in
            guard let name = entry["name"] as? String, let ids = entry["ids"] as? [String: Any],
                  let id = ids["trakt"] as? Int, let slug = ids["slug"] as? String else { return nil }
            return TraktListInfo(id: id, slug: slug, name: name, itemCount: (entry["item_count"] as? Int) ?? 0)
        }
    }

    public func listItems(_ list: TraktListInfo, limit: Int) async throws -> [TraktTitle] {
        let object = try await getJSON("/users/me/lists/\(list.id)/items/movie,show?limit=\(limit)", authorized: true)
        var titles: [TraktTitle] = []
        for entry in object as? [[String: Any]] ?? [] {
            if let movie = entry["movie"] as? [String: Any], let title = Self.title(from: movie, kind: .movie) { titles.append(title) }
            if let show = entry["show"] as? [String: Any], let title = Self.title(from: show, kind: .show) { titles.append(title) }
        }
        return titles
    }

    // MARK: Sincronizzazione

    /// Quello che hai già visto: film e (per ogni serie) gli episodi.
    public func watchedMovies() async throws -> [TraktTitle] {
        return Self.parseWrapped(try await getJSON("/sync/watched/movies", authorized: true), key: "movie", kind: .movie, note: nil)
    }

    /// Per ogni serie, gli episodi visti come (stagione, numero).
    public func watchedShows() async throws -> [(show: TraktTitle, episodes: [(season: Int, number: Int)])] {
        let object = try await getJSON("/sync/watched/shows", authorized: true)
        var result: [(show: TraktTitle, episodes: [(season: Int, number: Int)])] = []
        for entry in object as? [[String: Any]] ?? [] {
            guard let show = entry["show"] as? [String: Any], let title = Self.title(from: show, kind: .show) else { continue }
            var episodes: [(season: Int, number: Int)] = []
            for season in entry["seasons"] as? [[String: Any]] ?? [] {
                guard let number = season["number"] as? Int else { continue }
                for episode in season["episodes"] as? [[String: Any]] ?? [] {
                    if let value = episode["number"] as? Int { episodes.append((number, value)) }
                }
            }
            result.append((title, episodes))
        }
        return result
    }

    public func addToWatchlist(movies: [String], shows: [String]) async throws {
        try await sync("/sync/watchlist", movies: movies, shows: shows)
    }

    public func removeFromWatchlist(movies: [String], shows: [String]) async throws {
        try await sync("/sync/watchlist/remove", movies: movies, shows: shows)
    }

    private func sync(_ path: String, movies: [String], shows: [String]) async throws {
        guard !movies.isEmpty || !shows.isEmpty else { return }
        var body: [String: Any] = [:]
        if !movies.isEmpty { body["movies"] = movies.map { ["ids": ["imdb": $0]] } }
        if !shows.isEmpty { body["shows"] = shows.map { ["ids": ["imdb": $0]] } }
        _ = try await postJSON(path, body: body, authorized: true)
    }

    /// Segna come visti film ed episodi (`episodes`: IMDb della serie, stagione, numero).
    public func addToHistory(movies: [String], episodes: [(show: String, season: Int, number: Int)], watchedAt: Date = Date()) async throws {
        guard !movies.isEmpty || !episodes.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: watchedAt)
        var body: [String: Any] = [:]
        if !movies.isEmpty { body["movies"] = movies.map { ["ids": ["imdb": $0], "watched_at": stamp] } }
        if !episodes.isEmpty {
            var grouped: [String: [Int: [Int]]] = [:]
            for entry in episodes { grouped[entry.show, default: [:]][entry.season, default: []].append(entry.number) }
            body["shows"] = grouped.map { (show, seasons) -> [String: Any] in
                ["ids": ["imdb": show], "seasons": seasons.map { (season, numbers) -> [String: Any] in
                    ["number": season, "episodes": numbers.map { ["number": $0, "watched_at": stamp] }]
                }]
            }
        }
        _ = try await postJSON("/sync/history", body: body, authorized: true)
    }

    // MARK: Scrobble

    public enum ScrobbleAction: String, Sendable { case start, pause, stop }

    /// `imdb`: del film o della serie. Per gli episodi servono stagione e numero. `progress`: 0-100.
    public func scrobble(_ action: ScrobbleAction, imdb: String, season: Int?, episode: Int?, progress: Double) async throws {
        var body: [String: Any] = ["progress": min(100, max(0, (progress * 100).rounded() / 100))]
        if let season = season, let episode = episode {
            body["show"] = ["ids": ["imdb": imdb]]
            body["episode"] = ["season": season, "number": episode]
        } else {
            body["movie"] = ["ids": ["imdb": imdb]]
        }
        do {
            _ = try await postJSON("/scrobble/\(action.rawValue)", body: body, authorized: true)
        } catch TraktError.server(409) {
            // «Già registrato da poco»: va bene così.
        }
    }

    // MARK: Trasporto

    private func getJSON(_ path: String, authorized: Bool) async throws -> Any {
        return try await json(try await request(path: path, method: "GET", body: nil, authorized: authorized), retryPath: nil)
    }

    private func postJSON(_ path: String, body: [String: Any], authorized: Bool) async throws -> Any {
        return try await json(try await request(path: path, method: "POST", body: body, authorized: authorized), retryPath: nil)
    }

    private func request(path: String, method: String, body: [String: Any]?, authorized: Bool) async throws -> HTTPRequest {
        var token: String?
        if authorized { token = try await validSession().accessToken }
        return try makeRequest(path: path, method: method, body: body, authorized: authorized, token: token)
    }

    private nonisolated func makeRequest(path: String, method: String, body: [String: Any]?, authorized: Bool, token: String? = nil) throws -> HTTPRequest {
        guard let url = URL(string: base.absoluteString + path) else { throw TraktError.malformed }
        var headers = ["Content-Type": "application/json", "Accept": "application/json",
                       "trakt-api-version": "2", "trakt-api-key": TraktClient.clientID]
        if let token = token { headers["Authorization"] = "Bearer " + token }
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return HTTPRequest(url: url, method: method, headers: headers, body: data, timeout: 20, maxBytes: HTTPLimits.resource)
    }

    private nonisolated func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        // A dropped connection (-1005) is often just a stale one: it is retried twice on a fresh connection before giving up.
        var attempt = 0
        while true {
            do {
                return try await http.send(request)
            } catch let error as AddonError {
                if case .unreachable = error, attempt < 2, !Task.isCancelled {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
                    continue
                }
                throw TraktError.transport(Self.describe(error))
            } catch is CancellationError {
                throw TraktError.transport("richiesta annullata")
            } catch {
                throw TraktError.network
            }
        }
    }

    /// Esegue la richiesta; con 401 rinnova il token una volta e riprova.
    private func json(_ request: HTTPRequest, retryPath: String?) async throws -> Any {
        var response = try await send(request)
        if response.statusCode == 429, let wait = response.headers["retry-after"].flatMap({ (text: String) -> Double? in Double(text) }), wait > 0, wait <= 5 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            response = try await send(request)
        }
        if response.statusCode == 401, request.headers["Authorization"] != nil, session != nil {
            let renewed = try await refresh()
            var again = request
            again.headers["Authorization"] = "Bearer " + renewed.accessToken
            response = try await send(again)
        }
        switch response.statusCode {
        case 200..<300:
            if response.data.isEmpty { return [:] as [String: Any] }
            guard let object = try? JSONSerialization.jsonObject(with: response.data) else { throw TraktError.malformed }
            return object
        case 401, 403: throw TraktError.unauthorized
        case 404: throw TraktError.notFound
        case 420: throw TraktError.accountLimit
        case 426: throw TraktError.vipRequired
        case 429: throw TraktError.rateLimited
        default: throw TraktError.server(response.statusCode)
        }
    }

    /// Il motivo per cui una richiesta non è partita, in poche parole (mai con indirizzi privati o chiavi).
    static func describe(_ error: AddonError) -> String {
        switch error {
        case .offline: return "nessuna connessione a Internet"
        case .timeout: return "tempo scaduto"
        case .tlsFailure: return "certificato del server non accettato"
        case .atsBlocked: return "connessione non sicura bloccata da iOS"
        case .unreachable(let host): return "il server \(host) non risponde"
        case .blockedURL: return "indirizzo bloccato dalle regole di rete di Aether: controlla DNS o VPN"
        case .insecureTransport: return "connessione non sicura rifiutata"
        case .tooManyRedirects, .redirectBlocked: return "troppi reindirizzamenti"
        case .responseTooLarge: return "risposta troppo grande"
        case .cancelled: return "richiesta annullata"
        default: return "errore di rete"
        }
    }

    // MARK: Lettura delle risposte

    static func title(from object: [String: Any], kind: TraktTitle.Kind) -> TraktTitle? {
        guard let name = object["title"] as? String else { return nil }
        let ids = object["ids"] as? [String: Any]
        return TraktTitle(kind: kind, title: name, year: object["year"] as? Int, imdb: ids?["imdb"] as? String,
                          tmdb: ids?["tmdb"] as? Int, tvdb: ids?["tvdb"] as? Int, note: nil, progress: nil,
                          season: nil, episode: nil, episodeTitle: nil)
    }

    static func noteWatchers(_ entry: [String: Any]) -> String? { return (entry["watchers"] as? Int).map { "\($0) spettatori ora" } }
    static func noteLists(_ entry: [String: Any]) -> String? { return (entry["list_count"] as? Int).map { "in \($0) liste" } }
    static func noteRevenue(_ entry: [String: Any]) -> String? {
        return (entry["revenue"] as? Int).map { "incasso " + ($0 >= 1_000_000 ? String(format: "%.1f M$", Double($0) / 1_000_000) : "\($0) $") }
    }

    static func parsePlain(_ object: Any, kind: TraktTitle.Kind) -> [TraktTitle] {
        return (object as? [[String: Any]] ?? []).compactMap { title(from: $0, kind: kind) }
    }

    static func parseWrapped(_ object: Any, key: String, kind: TraktTitle.Kind, note: (([String: Any]) -> String?)?) -> [TraktTitle] {
        return (object as? [[String: Any]] ?? []).compactMap { entry -> TraktTitle? in
            guard let inner = entry[key] as? [String: Any], var found = title(from: inner, kind: kind) else { return nil }
            found.note = note?(entry)
            return found
        }
    }

    static func parsePlayback(_ object: Any) -> [TraktTitle] {
        var result: [TraktTitle] = []
        for entry in object as? [[String: Any]] ?? [] {
            let progress = entry["progress"] as? Double
            if let movie = entry["movie"] as? [String: Any], var found = title(from: movie, kind: .movie) {
                found.progress = progress
                found.note = progress.map { "visto al \(Int($0))%" }
                result.append(found)
            } else if let show = entry["show"] as? [String: Any], var found = title(from: show, kind: .show) {
                let episode = entry["episode"] as? [String: Any]
                found.season = episode?["season"] as? Int
                found.episode = episode?["number"] as? Int
                found.episodeTitle = episode?["title"] as? String
                found.progress = progress
                let label = [found.season.map { "S\($0)" }, found.episode.map { "E\($0)" }].compactMap { $0 }.joined()
                found.note = [label, progress.map { "\(Int($0))%" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                result.append(found)
            }
        }
        // Una sola riga per titolo: la più recente (Trakt le dà già in ordine).
        var seen = Set<String>()
        return result.filter { seen.insert($0.imdb ?? $0.title).inserted }
    }

    static func parseCalendar(_ object: Any) -> [TraktTitle] {
        var result: [TraktTitle] = []
        for entry in object as? [[String: Any]] ?? [] {
            guard let show = entry["show"] as? [String: Any], var found = title(from: show, kind: .show) else { continue }
            let episode = entry["episode"] as? [String: Any]
            found.season = episode?["season"] as? Int
            found.episode = episode?["number"] as? Int
            found.episodeTitle = episode?["title"] as? String
            let day = (entry["first_aired"] as? String).map { String($0.prefix(10)) }
            found.note = ["S\(found.season ?? 0)E\(found.episode ?? 0)", day].compactMap { $0 }.joined(separator: " · ")
            result.append(found)
        }
        return result
    }
}
