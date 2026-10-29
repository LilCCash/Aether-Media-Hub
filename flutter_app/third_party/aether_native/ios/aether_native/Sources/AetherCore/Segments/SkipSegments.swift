import Foundation

/// A stretch of an episode the viewer can jump over: the opening titles or the recap of the previous episode.
public struct SkipSegment: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case intro, recap }

    public var kind: Kind
    /// Seconds from the start of the file.
    public var start: Double
    public var end: Double

    public init(kind: Kind, start: Double, end: Double) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    public var duration: Double { return end - start }
}

/// What is known about the skippable parts of one episode.
public struct EpisodeSkipSegments: Equatable, Sendable {
    public var intro: SkipSegment?
    public var recap: SkipSegment?

    public static let none = EpisodeSkipSegments(intro: nil, recap: nil)

    public init(intro: SkipSegment? = nil, recap: SkipSegment? = nil) {
        self.intro = intro
        self.recap = recap
    }

    public var isEmpty: Bool { return intro == nil && recap == nil }

    /// A "skip" button is offered from this many seconds before a segment starts and until this many seconds before it ends.
    public static let lead: Double = 1
    public static let tail: Double = 1

    /// The segment the playhead is in, or nil. `duration` (when the player knows it) rejects data that cannot belong to this
    /// file: a segment that ends well after the end of the file is the timing of a different cut.
    public func active(at position: Double, duration: Double? = nil) -> SkipSegment? {
        guard position.isFinite, position >= 0 else { return nil }
        for segment in [recap, intro].compactMap({ $0 }) {
            if let duration = duration, duration > 0, segment.end > duration + 5 { continue }
            if position >= segment.start - EpisodeSkipSegments.lead, position < segment.end - EpisodeSkipSegments.tail {
                return segment
            }
        }
        return nil
    }
}

/// Why a lookup produced nothing. Never carries the request address.
public enum SkipSegmentsError: Error, Equatable, Sendable {
    case invalidRequest
    case untrustedHost
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable
    case malformed
}

/// Client of the public IntroDB read API (https://api.introdb.app, no key): `GET /segments?imdb_id=tt…&season=N&episode=M`.
/// It answers with `intro`, `recap`, `outro` and `post_credits` objects (`start_sec`, `end_sec`, `start_ms`, `end_ms`,
/// `confidence`, `submission_count`) or null where nothing is known. Only the intro and the recap are used here.
/// The data is contributed by volunteers for a particular cut of an episode: it can be a few seconds off for another one.
public struct IntroDBClient: Sendable {
    public static let productionBaseURL = URL(string: "https://api.introdb.app")!
    public static let productionHost = "api.introdb.app"

    private let http: HTTPClient
    private let baseURL: URL
    private let timeout: TimeInterval

    public init(http: HTTPClient, baseURL: URL = IntroDBClient.productionBaseURL, timeout: TimeInterval = 6) {
        self.http = http
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// "tt" and 6 to 10 digits.
    static func isValidIMDbID(_ id: String) -> Bool {
        guard id.hasPrefix("tt") else { return false }
        let digits = id.dropFirst(2)
        return (6...10).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public func segments(imdbID: String, season: Int, episode: Int) async throws -> EpisodeSkipSegments {
        guard IntroDBClient.isValidIMDbID(imdbID), (0...500).contains(season), (0...100_000).contains(episode) else {
            throw SkipSegmentsError.invalidRequest
        }
        guard MetadataHTTP.isTrusted(baseURL, productionHost: IntroDBClient.productionHost) else { throw SkipSegmentsError.untrustedHost }
        guard var components = URLComponents(string: baseURL.absoluteString + "/segments") else { throw SkipSegmentsError.invalidRequest }
        components.queryItems = [URLQueryItem(name: "imdb_id", value: imdbID),
                                 URLQueryItem(name: "season", value: String(season)),
                                 URLQueryItem(name: "episode", value: String(episode))]
        guard let url = components.url else { throw SkipSegmentsError.invalidRequest }

        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: timeout,
                                                       maxBytes: 64 * 1024, purpose: .addonRequest))
        } catch is CancellationError {
            throw CancellationError()
        } catch AddonError.cancelled {
            throw CancellationError()
        } catch {
            throw SkipSegmentsError.unavailable
        }
        guard response.isSuccess else {
            switch response.statusCode {
            case 404: throw SkipSegmentsError.notFound
            case 429: throw SkipSegmentsError.rateLimited(retryAfter: MetadataHTTP.retryAfter(response))
            case 500...599: throw SkipSegmentsError.unavailable
            default: throw SkipSegmentsError.malformed
            }
        }
        return try IntroDBClient.parse(response.data)
    }

    // MARK: Parsing

    private struct Reply: Decodable {
        var intro: Part?
        var recap: Part?
    }

    private struct Part: Decodable {
        var start_sec: Double?
        var end_sec: Double?
        var start_ms: Double?
        var end_ms: Double?

        var range: (start: Double, end: Double)? {
            let start = start_sec ?? start_ms.map { $0 / 1000 }
            let end = end_sec ?? end_ms.map { $0 / 1000 }
            guard let from = start, let to = end else { return nil }
            return (from, to)
        }
    }

    /// Longest stretch accepted as an intro or a recap, and the shortest: anything else is more likely a mistake in the data.
    static let longestSegment: Double = 600
    static let shortestSegment: Double = 3

    static func parse(_ data: Data) throws -> EpisodeSkipSegments {
        let reply: Reply
        do {
            reply = try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw SkipSegmentsError.malformed
        }
        func make(_ kind: SkipSegment.Kind, _ part: Part?) -> SkipSegment? {
            guard let range = part?.range, range.start.isFinite, range.end.isFinite, range.start >= 0 else { return nil }
            let length = range.end - range.start
            guard length >= IntroDBClient.shortestSegment, length <= IntroDBClient.longestSegment else { return nil }
            return SkipSegment(kind: kind, start: range.start, end: range.end)
        }
        return EpisodeSkipSegments(intro: make(.intro, reply.intro), recap: make(.recap, reply.recap))
    }
}

/// Looks segments up for the player: remembers answers (also "nothing known"), asks once for concurrent requests, and backs
/// off after an error or a rate limit so a failing service is not asked on every episode. Never throws: the player simply
/// shows no button when there is no answer.
public actor SkipSegmentsService {
    struct Key: Hashable { let imdb: String; let season: Int; let episode: Int }

    private let client: IntroDBClient
    private let now: @Sendable () -> Date
    private var known: [Key: (value: EpisodeSkipSegments, until: Date)] = [:]
    private var failedUntil: [Key: Date] = [:]
    private var pausedUntil: Date?
    private var inFlight: [Key: Task<EpisodeSkipSegments?, Never>] = [:]

    static let foundTTL: TimeInterval = 24 * 3600
    static let unknownTTL: TimeInterval = 6 * 3600
    static let failureBackoff: TimeInterval = 60
    static let outageBackoff: TimeInterval = 30
    static let defaultRateLimitPause: TimeInterval = 120

    public init(client: IntroDBClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    /// nil when nothing could be found out (offline, rate limited, bad id); `.none` when the service knows nothing.
    public func segments(imdbID: String, season: Int, episode: Int) async -> EpisodeSkipSegments? {
        let key = Key(imdb: imdbID, season: season, episode: episode)
        let current = now()
        if let entry = known[key], entry.until > current { return entry.value }
        if let until = failedUntil[key], until > current { return nil }
        if let until = pausedUntil, until > current { return nil }
        if let running = inFlight[key] { return await running.value }

        let client = self.client
        let task = Task<EpisodeSkipSegments?, Never> { [weak self] in
            do {
                let found = try await client.segments(imdbID: imdbID, season: season, episode: episode)
                await self?.remember(found, for: key)
                return found
            } catch let error as SkipSegmentsError {
                await self?.noteFailure(error, for: key)
                return error == .notFound ? EpisodeSkipSegments.none : nil
            } catch {
                return nil   // cancelled: nothing is remembered
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    public func reset() {
        known.removeAll()
        failedUntil.removeAll()
        pausedUntil = nil
    }

    private func remember(_ value: EpisodeSkipSegments, for key: Key) {
        known[key] = (value, now().addingTimeInterval(value.isEmpty ? SkipSegmentsService.unknownTTL : SkipSegmentsService.foundTTL))
        failedUntil[key] = nil
    }

    private func noteFailure(_ error: SkipSegmentsError, for key: Key) {
        let current = now()
        switch error {
        case .notFound:
            known[key] = (EpisodeSkipSegments.none, current.addingTimeInterval(SkipSegmentsService.unknownTTL))
        case .rateLimited(let retryAfter):
            pausedUntil = current.addingTimeInterval(min(3600, max(1, retryAfter ?? SkipSegmentsService.defaultRateLimitPause)))
        case .unavailable:
            pausedUntil = current.addingTimeInterval(SkipSegmentsService.outageBackoff)
            failedUntil[key] = current.addingTimeInterval(SkipSegmentsService.failureBackoff)
        case .invalidRequest, .untrustedHost, .malformed:
            failedUntil[key] = current.addingTimeInterval(SkipSegmentsService.failureBackoff)
        }
    }
}
