import Foundation

struct TVDBEpisode: Decodable {
    var season: Int?
    var number: Int?
    var name: String?
    var overview: String?
    var image: String?
    private enum CodingKeys: String, CodingKey { case seasonNumber, number, name, overview, image }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        season = c.flexInt(.seasonNumber)
        number = c.flexInt(.number)
        name = c.flexString(.name).flatMap { $0.isEmpty ? nil : $0 }
        overview = c.flexString(.overview).flatMap { $0.isEmpty ? nil : $0 }
        image = c.flexString(.image).flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct TVDBEpisodesPage: Decodable {
    var episodes: [TVDBEpisode]
    var hasNext: Bool
    private enum Root: String, CodingKey { case data, links }
    private enum DataKeys: String, CodingKey { case episodes }
    private enum LinkKeys: String, CodingKey { case next }
    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Root.self)
        if let data = try? root.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
            episodes = data.lossyArray(TVDBEpisode.self, forKey: .episodes)
        } else {
            episodes = []
        }
        if let links = try? root.nestedContainer(keyedBy: LinkKeys.self, forKey: .links) {
            hasNext = (links.flexString(.next) ?? "").isEmpty == false
        } else {
            hasNext = false
        }
    }
}

struct TVDBRemoteSearch: Decodable {
    var seriesID: Int?
    private enum Root: String, CodingKey { case data }
    private struct Entry: Decodable {
        var seriesID: Int?
        private enum CodingKeys: String, CodingKey { case series }
        private enum SeriesKeys: String, CodingKey { case id }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let series = try? c.nestedContainer(keyedBy: SeriesKeys.self, forKey: .series) {
                seriesID = series.flexInt(.id)
            }
        }
    }
    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Root.self)
        let entries = root.lossyArray(Entry.self, forKey: .data)
        seriesID = entries.compactMap { $0.seriesID }.first
    }
}

private struct TVDBLoginResponse: Decodable {
    var token: String?
    private enum Root: String, CodingKey { case data }
    private enum DataKeys: String, CodingKey { case token }
    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Root.self)
        if let data = try? root.nestedContainer(keyedBy: DataKeys.self, forKey: .data) {
            token = data.flexString(.token)
        }
    }
}

/// Keeps the login token in memory for as long as the credentials stay the same. Never persisted.
actor TVDBTokenStore {
    private var token: String?
    private var fingerprint: String?

    func current(for fingerprint: String) -> String? {
        return self.fingerprint == fingerprint ? token : nil
    }

    func store(_ token: String, for fingerprint: String) {
        self.token = token
        self.fingerprint = fingerprint
    }

    func invalidate() {
        token = nil
        fingerprint = nil
    }
}

/// Client of TheTVDB v4 with the user's own project key (and subscriber PIN, if the key needs one).
/// What is verified (2026-10-20): `POST /v4/login` with `{"apikey","pin"}` answers `data.token` valid for a month, and
/// HTTP 401 `{"status":"failure","message":"InvalidAPIKey: …"}` for a wrong key. The data paths below follow the public
/// v4 documentation but were NOT confirmed by the probe; every decoding is tolerant and a failure only means "no extra data".
public struct TVDBClient: Sendable {
    public static let productionBaseURL = URL(string: "https://api4.thetvdb.com/v4")!
    public static let productionHost = "api4.thetvdb.com"

    public typealias CredentialProvider = @Sendable () -> String?

    private let http: HTTPClient
    private let apiKey: CredentialProvider
    private let pin: CredentialProvider
    private let baseURL: URL
    private let timeout: TimeInterval
    private let tokens = TVDBTokenStore()

    public init(http: HTTPClient, apiKey: @escaping CredentialProvider, pin: @escaping CredentialProvider = { nil },
                baseURL: URL = TVDBClient.productionBaseURL, timeout: TimeInterval = 15) {
        self.http = http
        self.apiKey = apiKey
        self.pin = pin
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// Whether a key is stored (does not say the service accepts it).
    public var isConfigured: Bool {
        return !(apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    // MARK: Authentication

    private func credentialFingerprint() throws -> (key: String, pin: String?, fingerprint: String) {
        guard MetadataHTTP.isTrusted(baseURL, productionHost: TVDBClient.productionHost) else { throw MetadataError.untrustedHost }
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { throw MetadataError.notConfigured }
        let pinValue = pin()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usablePin = (pinValue ?? "").isEmpty ? nil : pinValue
        return (key, usablePin, Hashing.sha256Hex("\(key)\n\(usablePin ?? "")"))
    }

    func login() async throws -> String {
        let credentials = try credentialFingerprint()
        var payload: [String: String] = ["apikey": credentials.key]
        if let pin = credentials.pin { payload["pin"] = pin }
        guard let body = try? JSONEncoder().encode(payload), let url = URL(string: baseURL.absoluteString + "/login") else {
            throw MetadataError.malformed
        }
        let request = HTTPRequest(url: url, method: "POST",
                                  headers: ["Content-Type": "application/json", "Accept": "application/json"],
                                  body: body, timeout: timeout)
        let response = try await MetadataHTTP.send(request, using: http)
        guard response.isSuccess else { throw MetadataHTTP.map(status: response.statusCode, response: response) }
        guard let token = (try? JSONDecoder().decode(TVDBLoginResponse.self, from: response.data))?.token, !token.isEmpty else {
            throw MetadataError.malformed
        }
        await tokens.store(token, for: credentials.fingerprint)
        return token
    }

    /// Settings screen: does the key (and PIN) log in?
    public func check() async -> MetadataCheckResult {
        do {
            _ = try await login()
            return .ok
        } catch let error as MetadataError {
            return .failed(error)
        } catch {
            return .failed(.unavailable("errore"))
        }
    }

    // MARK: Data

    /// Series id for an IMDb id, from `GET /search/remoteid/{id}`.
    func seriesID(forIMDbID imdb: String) async throws -> Int? {
        let result: TVDBRemoteSearch = try await get("/search/remoteid/\(imdb)")
        return result.seriesID
    }

    /// Episodes of a series with titles / overviews translated into `language` (ISO 639-2, for example "ita"), all pages (max 4).
    func episodes(seriesID: Int, language: String) async throws -> [TVDBEpisode] {
        var all: [TVDBEpisode] = []
        for page in 0..<4 {
            let result: TVDBEpisodesPage = try await get("/series/\(seriesID)/episodes/default/\(language)?page=\(page)")
            all.append(contentsOf: result.episodes)
            if !result.hasNext { break }
        }
        return all
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let credentials = try credentialFingerprint()
        var token = await tokens.current(for: credentials.fingerprint)
        if token == nil { token = try await login() }
        guard let url = URL(string: baseURL.absoluteString + path) else { throw MetadataError.malformed }
        for attempt in 0..<2 {
            guard let bearer = token else { throw MetadataError.invalidCredentials }
            let request = HTTPRequest(url: url, headers: ["Authorization": "Bearer \(bearer)", "Accept": "application/json"], timeout: timeout)
            let response = try await MetadataHTTP.send(request, using: http)
            if response.statusCode == 401 && attempt == 0 {
                // The token expired (they last a month) or was revoked: log in once more.
                await tokens.invalidate()
                token = try await login()
                continue
            }
            guard response.isSuccess else { throw MetadataHTTP.map(status: response.statusCode, response: response) }
            do {
                return try JSONDecoder().decode(T.self, from: response.data)
            } catch {
                throw MetadataError.malformed
            }
        }
        throw MetadataError.invalidCredentials
    }
}
