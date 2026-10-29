import Foundation

/// One rating of a title, as MDBList reports it.
public struct MDBRating: Equatable, Sendable, Identifiable {
    /// The service, already in our spelling (`RatingSource.rawValue` for the known ones).
    public var source: String
    public var value: Double?
    /// The same rating on a 0–100 scale, when MDBList gives it.
    public var score: Double?
    public var votes: Int?

    public var id: String { return source }

    public var title: String { return RatingSource(rawValue: source)?.shortTitle ?? source.capitalized }

    /// "7.7", "92%" or "81", written the way each service writes its own scale.
    public var display: String? {
        switch source {
        case RatingSource.tomatoes.rawValue, RatingSource.tomatoesaudience.rawValue, RatingSource.trakt.rawValue:
            guard let number = score ?? value else { return nil }
            return "\(Int(number.rounded()))%"
        case RatingSource.metacritic.rawValue:
            guard let number = value ?? score else { return nil }
            return "\(Int(number.rounded()))"
        default:
            if let number = value { return number <= 10 ? String(format: "%.1f", number) : "\(Int(number.rounded()))" }
            if let number = score { return "\(Int(number.rounded()))" }
            return nil
        }
    }
}

/// Client of MDBList (api.mdblist.com) with the user's own API key: the ratings of a title from several services at once.
/// The key is read from a provider on every call, never stored here and never part of an error.
public struct MDBListClient: Sendable {
    public static let productionBaseURL = URL(string: "https://api.mdblist.com")!
    public static let productionHost = "api.mdblist.com"

    public typealias CredentialProvider = @Sendable () -> String?

    private let http: HTTPClient
    private let credentials: CredentialProvider
    private let baseURL: URL
    private let timeout: TimeInterval

    public init(http: HTTPClient, credentials: @escaping CredentialProvider,
                baseURL: URL = MDBListClient.productionBaseURL, timeout: TimeInterval = 10) {
        self.http = http
        self.credentials = credentials
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public var isConfigured: Bool {
        return !(credentials() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The ratings of a title known by its TMDB id. Empty without a key or on any failure.
    public func ratings(tmdbID: Int, isMovie: Bool) async -> [MDBRating] {
        guard let data = try? await get("/tmdb/\(isMovie ? "movie" : "show")/\(tmdbID)") else { return [] }
        return MDBListClient.parse(data)
    }

    /// Settings screen: is the key accepted?
    public func check() async -> MetadataCheckResult {
        do {
            _ = try await get("/user")
            return .ok
        } catch let error as MetadataError {
            return .failed(error)
        } catch {
            return .failed(.unavailable("errore"))
        }
    }

    private func get(_ path: String) async throws -> Data {
        guard MetadataHTTP.isTrusted(baseURL, productionHost: MDBListClient.productionHost) else { throw MetadataError.untrustedHost }
        let key = (credentials() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MetadataError.notConfigured }
        guard var components = URLComponents(string: baseURL.absoluteString + path) else { throw MetadataError.malformed }
        components.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = components.url else { throw MetadataError.malformed }
        let response = try await MetadataHTTP.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: timeout), using: http)
        guard response.isSuccess else { throw MetadataHTTP.map(status: response.statusCode, response: response) }
        return response.data
    }

    static func parse(_ data: Data) -> [MDBRating] {
        guard let body = try? JSONDecoder().decode(MDBListBody.self, from: data) else { return [] }
        var seen = Set<String>()
        var result: [MDBRating] = []
        for entry in body.ratings {
            guard let raw = entry.source, !raw.isEmpty else { continue }
            let source = RatingSource.canonical(raw)
            guard seen.insert(source).inserted else { continue }
            let rating = MDBRating(source: source, value: entry.value, score: entry.score, votes: entry.votes)
            if rating.display != nil { result.append(rating) }
        }
        return result
    }
}

struct MDBListRatingEntry: Decodable {
    var source: String?
    var value: Double?
    var score: Double?
    var votes: Int?
    private enum CodingKeys: String, CodingKey { case source, value, score, votes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = c.flexString(.source)
        value = c.flexString(.value).flatMap { Double($0) }
        score = c.flexString(.score).flatMap { Double($0) }
        votes = c.flexInt(.votes)
    }
}

struct MDBListBody: Decodable {
    var ratings: [MDBListRatingEntry]
    private enum CodingKeys: String, CodingKey { case ratings }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratings = c.lossyArray(MDBListRatingEntry.self, forKey: .ratings)
    }
}
