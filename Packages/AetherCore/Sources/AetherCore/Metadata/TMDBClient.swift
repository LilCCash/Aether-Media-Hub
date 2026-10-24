import Foundation

/// Client of the TMDB v3 API with the user's own credential: either a v4 "API read access token" (a long JWT, sent as
/// `Authorization: Bearer`) or a v3 API key (32 hex characters, sent as `api_key`). The secret is read from a provider on
/// every call, is never stored here, and appears in no error value: errors are the typed `MetadataError`.
public struct TMDBClient: Sendable {
    public static let productionBaseURL = URL(string: "https://api.themoviedb.org/3")!
    public static let productionHost = "api.themoviedb.org"

    public typealias CredentialProvider = @Sendable () -> String?

    public enum Kind: String, Sendable { case movie, tv }

    enum Credential: Equatable {
        case bearer(String)
        case apiKey(String)
    }

    private let http: HTTPClient
    private let credentials: CredentialProvider
    private let baseURL: URL
    private let timeout: TimeInterval

    public init(http: HTTPClient, credentials: @escaping CredentialProvider,
                baseURL: URL = TMDBClient.productionBaseURL, timeout: TimeInterval = 15) {
        self.http = http
        self.credentials = credentials
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// Whether a usable key is stored (does not say the service accepts it).
    public var isConfigured: Bool {
        guard let secret = credentials() else { return false }
        return TMDBClient.classify(secret) != nil
    }

    /// v4 read tokens are JWTs ("eyJ…" with two dots); anything else is treated as a v3 API key.
    static func classify(_ raw: String) -> Credential? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 2048, key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        if key.hasPrefix("eyJ") && key.filter({ $0 == "." }).count == 2 { return .bearer(key) }
        return .apiKey(key)
    }

    // MARK: Endpoints

    func configuration() async throws -> TMDBImageConfiguration {
        let body: TMDBConfigurationResponse = try await get("/configuration", query: [])
        return body.images ?? TMDBImageConfiguration()
    }

    func find(externalID: String, source: String) async throws -> TMDBFindResponse {
        return try await get("/find/\(externalID)", query: [("external_source", source)])
    }

    func details(kind: Kind, id: Int, language: String) async throws -> TMDBDetails {
        let imageLanguages = [String(language.prefix(2)), "en", "null"].joined(separator: ",")
        return try await get("/\(kind.rawValue)/\(id)", query: [
            ("language", language),
            ("append_to_response", "credits,images,external_ids"),
            ("include_image_language", imageLanguages),
        ])
    }

    /// Everything the title page shows, in one request.
    func richDetails(kind: Kind, id: Int, language: String) async throws -> TMDBRichDetails {
        let videoLanguages = [String(language.prefix(2)), "en", "null"].joined(separator: ",")
        let ratings = kind == .movie ? "release_dates" : "content_ratings"
        return try await get("/\(kind.rawValue)/\(id)", query: [
            ("language", language),
            ("append_to_response", "credits,videos,similar,external_ids,\(ratings)"),
            ("include_video_language", videoLanguages),
        ])
    }

    func externalIDs(kind: Kind, id: Int) async throws -> TMDBExternalIDs {
        return try await get("/\(kind.rawValue)/\(id)/external_ids", query: [])
    }

    /// Every film and series the person acted in (`combined_credits`).
    func personCredits(id: Int, language: String) async throws -> TMDBPersonCredits {
        return try await get("/person/\(id)/combined_credits", query: [("language", language)])
    }

    func season(tvID: Int, number: Int, language: String) async throws -> TMDBSeason {
        return try await get("/tv/\(tvID)/season/\(number)", query: [("language", language)])
    }

    /// Settings screen: is the key accepted? One cheap authenticated request, `/configuration`.
    public func check() async -> MetadataCheckResult {
        do {
            _ = try await configuration()
            return .ok
        } catch let error as MetadataError {
            return .failed(error)
        } catch {
            return .failed(.unavailable("errore"))
        }
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [(String, String)]) async throws -> T {
        guard MetadataHTTP.isTrusted(baseURL, productionHost: TMDBClient.productionHost) else { throw MetadataError.untrustedHost }
        guard let secret = credentials(), let credential = TMDBClient.classify(secret) else { throw MetadataError.notConfigured }
        guard var components = URLComponents(string: baseURL.absoluteString + path) else { throw MetadataError.malformed }
        var items = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var headers = ["Accept": "application/json"]
        switch credential {
        case .bearer(let token): headers["Authorization"] = "Bearer \(token)"
        case .apiKey(let key): items.append(URLQueryItem(name: "api_key", value: key))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw MetadataError.malformed }
        let response = try await MetadataHTTP.send(HTTPRequest(url: url, headers: headers, timeout: timeout), using: http)
        guard response.isSuccess else {
            // TMDB error bodies carry a stable numeric code: 7 = invalid API key, 3 = authentication failed, 34 = not found.
            if let body = try? JSONDecoder().decode(TMDBErrorBody.self, from: response.data) {
                if body.statusCode == 7 || body.statusCode == 3 { throw MetadataError.invalidCredentials }
                if body.statusCode == 34 { throw MetadataError.notFound }
            }
            throw MetadataHTTP.map(status: response.statusCode, response: response)
        }
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw MetadataError.malformed
        }
    }
}
