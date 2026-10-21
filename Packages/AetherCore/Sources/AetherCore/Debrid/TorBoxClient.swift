import Foundation

// Low-level TorBox client: one method per endpoint, errors mapped to `DebridError`, nothing else.
// Policy (what to call and in which order) lives in `DebridResolver`.
//
// Safety rules implemented here (docs/research/torbox-api.md section 7):
//  * The API key comes from a provider closure on every call (the app backs it with the Keychain) and is never stored,
//    logged, or put into an error. Server text that echoes it is scrubbed before it is kept.
//  * Authorization: Bearer for every endpoint except `requestdl`, which takes the key in the `token` query parameter.
//    That URL is therefore never logged or returned in an error; only the endpoint path is.
//  * The base URL must be the production one (https://api.torbox.app) or, for UI-test fixtures, a loopback / private
//    network address. A response whose final URL has another host than the request is discarded: if the HTTP client
//    followed a redirect to a foreign host, nothing from that answer is used.
//  * No redirect and no `user_ip` on `requestdl`; `createtorrent` is never retried automatically.
//  * Automatic retries (max 3 attempts, exponential backoff with jitter, `Retry-After` honoured up to a short wait) only
//    for read requests and only on HTTP 429 / RATE_LIMIT_EXCEEDED / 5xx / non-JSON bodies.
//  * Nothing here can delete, pause or re-add a user's items: there is no such method.

public struct TorBoxClient: Sendable {
    public static let productionBaseURL: URL = URL(string: "https://api.torbox.app/v1/api")!
    public static let productionHost = "api.torbox.app"
    /// `checkcached` accepts about 100 hashes per request (official docs).
    public static let maxHashesPerCheck = 100

    public typealias KeyProvider = @Sendable () throws -> String?

    public struct RetryPolicy: Equatable, Sendable {
        public var maxAttempts: Int
        public var baseDelay: TimeInterval
        public var maxDelay: TimeInterval
        /// A longer `Retry-After` is not waited for inside the call: the rate-limit error is returned to the caller.
        public var maxAutomaticWait: TimeInterval
        /// Fraction of the delay added at random (0 disables jitter, used by tests).
        public var jitter: Double

        public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 8,
                    maxAutomaticWait: TimeInterval = 10, jitter: Double = 0.25) {
            self.maxAttempts = maxAttempts
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
            self.maxAutomaticWait = maxAutomaticWait
            self.jitter = jitter
        }

        public static let standard = RetryPolicy()
        public static let noRetry = RetryPolicy(maxAttempts: 1)
    }

    private enum Auth {
        case bearer
        case queryToken
    }

    private let http: HTTPClient
    private let keyProvider: KeyProvider
    private let baseURL: URL
    private let pinnedHost: String
    private let retry: RetryPolicy
    private let clock: DebridClock
    private let timeout: TimeInterval
    private let log: DiagnosticLog?

    public init(http: HTTPClient,
                keyProvider: @escaping KeyProvider,
                baseURL: URL = TorBoxClient.productionBaseURL,
                retry: RetryPolicy = RetryPolicy.standard,
                clock: DebridClock = DebridClock.system,
                timeout: TimeInterval = 15,
                log: DiagnosticLog? = nil) {
        self.http = http
        self.keyProvider = keyProvider
        self.baseURL = baseURL
        self.pinnedHost = baseURL.host?.lowercased() ?? ""
        self.retry = retry
        self.clock = clock
        self.timeout = timeout
        self.log = log
    }

    // MARK: Base URL trust

    /// True for the production API (https only) and for loopback / private-network addresses used by UI-test fixtures.
    /// Any other host is refused so that the key can never be sent to an unexpected server.
    public static func isTrustedBaseURL(_ url: URL) -> Bool {
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty, let scheme = url.scheme?.lowercased() else {
            return false
        }
        if rawHost == productionHost { return scheme == "https" }
        guard scheme == "http" || scheme == "https" else { return false }
        if rawHost == "localhost" || rawHost.hasSuffix(".localhost") { return true }
        var bare = rawHost
        if bare.hasPrefix("[") && bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        guard let address = IPAddress.parse(bare) else { return false }
        switch address.addressClass {
        case .loopback, .privateNetwork, .linkLocal:
            return true
        case .publicInternet, .multicast, .unspecified, .reserved:
            return false
        }
    }

    /// Keys are UUID-like. Anything with spaces, control characters or non-ASCII is refused before it can reach a header.
    static func isWellFormedKey(_ key: String) -> Bool {
        if key.isEmpty || key.count > 256 { return false }
        for scalar in key.unicodeScalars {
            if scalar.value < 0x21 || scalar.value > 0x7E { return false }
        }
        return true
    }

    // MARK: Endpoints

    /// `GET user/me`. Only plan facts are kept; the e-mail address in the response is not modelled at all.
    public func fetchUser() async throws -> TorBoxUser {
        let envelope = try await call(TorBoxUser.self, method: "GET", path: "/user/me",
                                      query: [("settings", "false")], auth: .bearer, idempotent: true)
        guard let user = envelope.data else { throw DebridError.invalidResponse("manca l'oggetto utente") }
        return user
    }

    /// `POST torrents/checkcached?format=list&list_files=true` with `{"hashes":[…]}` for at most 100 canonical hashes.
    /// Returns the cached ones keyed by canonical hash; a hash that is absent from the answer is not cached.
    public func checkCachedChunk(_ hashes: [String]) async throws -> [String: TorBoxCachedItem] {
        if hashes.isEmpty { return [:] }
        if hashes.count > TorBoxClient.maxHashesPerCheck {
            throw DebridError.api(code: "TOO_MANY_OPTIONS", detail: nil)
        }
        for hash in hashes where !DebridHash.isCanonical(hash) {
            throw DebridError.invalidInfoHash(String(hash.prefix(64)))
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(["hashes": hashes])
        } catch {
            throw DebridError.invalidResponse("richiesta non codificabile")
        }
        let query: [(String, String)] = [("format", "list"), ("list_files", "true")]
        let envelope = try await call(TorBoxCachedPayload.self, method: "POST", path: "/torrents/checkcached",
                                      query: query, body: body, contentType: "application/json",
                                      auth: .bearer, idempotent: true)
        if envelope.dataUnreadable { throw DebridError.invalidResponse("formato di checkcached inatteso") }
        let wanted = Set(hashes)
        let items: [TorBoxCachedItem] = envelope.data?.items ?? []
        var result: [String: TorBoxCachedItem] = [:]
        for item in items {
            guard let raw = item.hash, let canonical = DebridHash.normalize(raw), wanted.contains(canonical) else {
                continue
            }
            result[canonical] = item
        }
        return result
    }

    /// `POST torrents/createtorrent` (form: `magnet`, `allow_zip=false`). Not retried automatically.
    ///
    /// With `onlyIfCached` the form also carries `add_only_if_cached=true`: TorBox then adds the torrent only when it already
    /// has it, never starts a download, and refuses with HTTP 409 otherwise (`DebridError.notCached`). This is how the
    /// Nuvio app talks to TorBox (its source was read as a reference; nothing was copied), and it is what lets cached
    /// content play while the account is in a cool-down for new downloads.
    public func createTorrent(magnet: String, onlyIfCached: Bool = false) async throws -> TorBoxCreateResult {
        var form = "magnet=" + URIComponent.encode(magnet)
        if onlyIfCached { form += "&add_only_if_cached=true" }
        form += "&allow_zip=false"
        let envelope: TorBoxEnvelope<TorBoxCreateResult>
        do {
            envelope = try await call(TorBoxCreateResult.self, method: "POST", path: "/torrents/createtorrent",
                                      body: Data(form.utf8), contentType: "application/x-www-form-urlencoded",
                                      auth: .bearer, idempotent: false)
        } catch DebridError.api(let code, _) where onlyIfCached && TorBoxClient.meansNotCached(code) {
            throw DebridError.notCached
        }
        guard var result = envelope.data, result.torrentID != nil || result.queuedID != nil else {
            throw DebridError.invalidResponse("manca torrent_id nella risposta")
        }
        let detail = envelope.detail?.lowercased() ?? ""
        result.usedCachedCopy = detail.contains("found cached")
        return result
    }

    /// `GET torrents/mylist?bypass_cache=true`, either one item (`id`) or a page of the list. The provider returns one
    /// extra item when `limit` is given: the page is cut back to `limit`.
    public func myList(id: Int? = nil, offset: Int = 0, limit: Int = 1000) async throws -> [TorBoxTorrent] {
        var query: [(String, String)] = [("bypass_cache", "true")]
        if let id = id {
            query.append(("id", String(id)))
        } else {
            query.append(("offset", String(max(0, offset))))
            query.append(("limit", String(max(1, limit))))
        }
        let envelope = try await call(TorBoxTorrentPayload.self, method: "GET", path: "/torrents/mylist",
                                      query: query, auth: .bearer, idempotent: true, maxBytes: 16 * 1024 * 1024)
        if envelope.dataUnreadable { throw DebridError.invalidResponse("formato di mylist inatteso") }
        var torrents: [TorBoxTorrent] = envelope.data?.torrents ?? []
        if id == nil && torrents.count > limit {
            torrents = Array(torrents.prefix(max(1, limit)))
        }
        return torrents
    }

    /// `GET torrents/requestdl?token=…&torrent_id=…&file_id=…` without `redirect` and without `user_ip`. The key travels
    /// in the query string, so this URL is never logged. Returns the CDN URL from `data`.
    public func requestDownloadLink(torrentID: Int, fileID: Int) async throws -> URL {
        let query: [(String, String)] = [("torrent_id", String(torrentID)), ("file_id", String(fileID))]
        let envelope = try await call(TorBoxLinkPayload.self, method: "GET", path: "/torrents/requestdl",
                                      query: query, auth: .queryToken, idempotent: true)
        let key = try currentKey()
        guard let raw = envelope.data?.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL.lenient(raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else {
            throw DebridError.invalidResponse("manca il link di download")
        }
        // A link that contains the account key (a permalink) must never be handed to a player or a Cast receiver.
        if raw.contains(key) || url.absoluteString.contains(key) {
            throw DebridError.invalidResponse("il link restituito contiene credenziali")
        }
        return url
    }

    // MARK: Request pipeline

    private func currentKey() throws -> String {
        let raw: String?
        do {
            raw = try keyProvider()
        } catch {
            throw DebridError.notConfigured
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            throw DebridError.notConfigured
        }
        guard TorBoxClient.isWellFormedKey(trimmed) else { throw DebridError.authFailed }
        return trimmed
    }

    private func makeURL(path: String, query: [(String, String)]) throws -> URL {
        guard TorBoxClient.isTrustedBaseURL(baseURL) else {
            throw DebridError.refusedHost(baseURL.host ?? "")
        }
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        text += path
        if !query.isEmpty {
            var pairs: [String] = []
            for (name, value) in query {
                pairs.append(URIComponent.encode(name) + "=" + URIComponent.encode(value))
            }
            text += "?" + pairs.joined(separator: "&")
        }
        guard let url = URL(string: text), url.host?.lowercased() == pinnedHost else {
            throw DebridError.refusedHost(baseURL.host ?? "")
        }
        return url
    }

    private func call<Payload: Decodable>(_ payload: Payload.Type,
                                          method: String,
                                          path: String,
                                          query: [(String, String)] = [],
                                          body: Data? = nil,
                                          contentType: String? = nil,
                                          auth: Auth,
                                          idempotent: Bool,
                                          maxBytes: Int = HTTPLimits.resource) async throws -> TorBoxEnvelope<Payload> {
        let key = try currentKey()
        var queryItems = query
        if auth == .queryToken {
            queryItems.insert(("token", key), at: 0)
        }
        let url = try makeURL(path: path, query: queryItems)
        var headers: [String: String] = ["Accept": "application/json"]
        if auth == .bearer {
            headers["Authorization"] = "Bearer " + key
        }
        if let contentType = contentType {
            headers["Content-Type"] = contentType
        }
        let request = HTTPRequest(url: url, method: method, headers: headers, body: body, timeout: timeout,
                                  maxBytes: maxBytes, purpose: .addonRequest)
        let attempts = idempotent ? max(1, retry.maxAttempts) : 1
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await attemptOnce(request, payload: payload, path: path, key: key)
            } catch let error as DebridError {
                guard attempt < attempts, let delay = retryDelay(for: error, attempt: attempt) else {
                    await log?.log(.warning, "torbox", "\(method) \(path): \(error.message)")
                    throw error
                }
                await log?.log(.debug, "torbox", "\(method) \(path): nuovo tentativo (\(attempt + 1)/\(attempts))")
                try await clock.sleep(delay)
            }
        }
    }

    private func attemptOnce<Payload: Decodable>(_ request: HTTPRequest, payload: Payload.Type, path: String,
                                                 key: String) async throws -> TorBoxEnvelope<Payload> {
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AddonError {
            if case .cancelled = error { throw CancellationError() }
            throw TorBoxClient.map(transport: error)
        } catch {
            throw DebridError.network("Errore di rete verso TorBox.")
        }
        let finalHost = response.url.host?.lowercased() ?? ""
        if finalHost != pinnedHost {
            // The HTTP client followed a redirect to another host: nothing from that answer is trusted or parsed.
            throw DebridError.refusedHost(finalHost)
        }
        await log?.log(.debug, "torbox", "\(request.method) \(path) -> HTTP \(response.statusCode)")
        return try parse(response, payload: payload, key: key)
    }

    private func parse<Payload: Decodable>(_ response: HTTPResponse, payload: Payload.Type,
                                           key: String) throws -> TorBoxEnvelope<Payload> {
        let status = response.statusCode
        if status == 429 {
            throw DebridError.rateLimited(retryAfter: retryAfterSeconds(response))
        }
        guard let envelope = try? JSONDecoder().decode(TorBoxEnvelope<Payload>.self, from: response.data) else {
            // HTML from Cloudflare / a gateway, plain text, an empty body: the service is not answering properly.
            throw DebridError.serviceUnavailable(statusCode: status >= 400 ? status : nil)
        }
        if let rawCode = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCode.isEmpty {
            throw mapError(code: rawCode, detail: envelope.detail, status: status, response: response, key: key)
        }
        if status == 401 || status == 403 {
            // `{"detail":"Not authenticated"}` (no Authorization header) carries no error code at all.
            throw DebridError.authFailed
        }
        if status >= 500 {
            throw DebridError.serviceUnavailable(statusCode: status)
        }
        if !(200..<300).contains(status) {
            throw DebridError.api(code: "HTTP_\(status)", detail: sanitize(envelope.detail, key: key))
        }
        if envelope.success == false {
            throw DebridError.api(code: "UNKNOWN", detail: sanitize(envelope.detail, key: key))
        }
        return envelope
    }

    /// The `error` code decides, not the HTTP status (the status/code mapping is not verified).
    private func mapError(code rawCode: String, detail: String?, status: Int, response: HTTPResponse,
                          key: String) -> DebridError {
        let code = rawCode.uppercased()
        switch code {
        case "BAD_TOKEN", "AUTH_ERROR", "NO_AUTH", "OAUTH_VERIFICATION_ERROR":
            return DebridError.authFailed
        case "PLAN_RESTRICTED_FEATURE":
            return DebridError.planRestricted
        case "ACTIVE_LIMIT":
            return DebridError.limitReached(.activeDownloads)
        case "MONTHLY_LIMIT":
            return DebridError.limitReached(.monthly)
        case "COOLDOWN_LIMIT":
            return DebridError.limitReached(.cooldown)
        case "DOWNLOAD_TOO_LARGE":
            return DebridError.limitReached(.downloadTooLarge)
        case "RATE_LIMIT_EXCEEDED":
            return DebridError.rateLimited(retryAfter: retryAfterSeconds(response))
        case "DIFF_ISSUE":
            // Torrentio sees "already queued" and "maximum queued" under this code: a full queue is a limit, not a duplicate.
            let lowered = detail?.lowercased() ?? ""
            if lowered.contains("maximum") { return DebridError.limitReached(.activeDownloads) }
            return DebridError.alreadyInAccount
        case "DUPLICATE_ITEM":
            return DebridError.alreadyInAccount
        case "ITEM_NOT_FOUND":
            return DebridError.itemNotFound
        case "DATABASE_ERROR", "UNKNOWN_ERROR", "REDIRECT_ERROR", "SELLIX_ERROR", "DOWNLOAD_SERVER_ERROR",
             "NO_SERVERS_AVAILABLE_ERROR", "SEARCH_ERROR", "VENDOR_DISABLED", "DOWNSTREAM_ERROR", "REQUEST_FAILED":
            return DebridError.serviceUnavailable(statusCode: status >= 400 ? status : nil)
        default:
            return DebridError.api(code: TorBoxClient.safeCode(code), detail: sanitize(detail, key: key))
        }
    }

    /// The refusal of a cached-only add: HTTP 409 (reported as `HTTP_409` when it has no code) or a code that names the cache.
    static func meansNotCached(_ code: String) -> Bool {
        let upper = code.uppercased()
        return upper == "HTTP_409" || upper.contains("CACHE")
    }

    static func safeCode(_ code: String) -> String {
        if code.isEmpty || code.count > 48 { return "UNKNOWN" }
        for scalar in code.unicodeScalars {
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            let isUpper = scalar.value >= 0x41 && scalar.value <= 0x5A
            if !isDigit && !isUpper && scalar != "_" { return "UNKNOWN" }
        }
        return code
    }

    // MARK: Retry

    private func retryDelay(for error: DebridError, attempt: Int) -> TimeInterval? {
        switch error {
        case .rateLimited(let retryAfter):
            let wait = retryAfter ?? backoff(attempt: attempt)
            return wait <= retry.maxAutomaticWait ? wait : nil
        case .serviceUnavailable:
            return backoff(attempt: attempt)
        default:
            return nil
        }
    }

    private func backoff(attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 10)
        var delay = retry.baseDelay * pow(2.0, Double(exponent))
        delay = min(delay, retry.maxDelay)
        if retry.jitter > 0 {
            delay += delay * retry.jitter * Double.random(in: 0...1)
        }
        return max(0, delay)
    }

    /// `Retry-After` (seconds or an HTTP date), else the epoch in `x-ratelimit-reset`. The probe saw `retry-after: 60`
    /// even on 403 answers, so this is consulted for rate-limit errors only.
    private func retryAfterSeconds(_ response: HTTPResponse) -> TimeInterval? {
        if let raw = response.headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
                return min(seconds, 3600)
            }
            if let date = TorBoxClient.parseHTTPDate(raw) {
                let delta = date.timeIntervalSince(clock.now())
                return min(max(0, delta), 3600)
            }
        }
        if let raw = response.headers["x-ratelimit-reset"]?.trimmingCharacters(in: .whitespaces),
           let value = Double(raw), value.isFinite, value > 0 {
            let delta = value > 1_000_000_000 ? value - clock.now().timeIntervalSince1970 : value
            if delta > 0 { return min(delta, 3600) }
        }
        return nil
    }

    static func parseHTTPDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    // MARK: Mapping and scrubbing

    /// Transport errors become constant Italian texts: nothing from the underlying error (which may contain a URL, and for
    /// `requestdl` the key) is carried over.
    static func map(transport error: AddonError) -> DebridError {
        switch error {
        case .timeout:
            return DebridError.timeout
        case .offline:
            return DebridError.offline
        case .unreachable:
            return DebridError.unreachable
        case .tlsFailure:
            return DebridError.network("Connessione sicura a TorBox non riuscita (certificato non valido).")
        case .atsBlocked, .insecureTransport:
            return DebridError.network("iOS ha bloccato una connessione non cifrata verso TorBox.")
        case .blockedURL, .redirectBlocked:
            return DebridError.network("Connessione a TorBox bloccata dai criteri di rete dell'app.")
        case .tooManyRedirects:
            return DebridError.network("Troppi reindirizzamenti dalla rete di TorBox.")
        case .responseTooLarge:
            return DebridError.invalidResponse("risposta troppo grande")
        case .http(let status):
            return DebridError.serviceUnavailable(statusCode: status)
        default:
            return DebridError.network("Errore di rete verso TorBox.")
        }
    }

    /// Removes the key (also in its percent-encoded form) and everything `Redactor` knows how to hide.
    static func scrub(_ text: String, key: String) -> String {
        var value = text
        if !key.isEmpty {
            value = value.replacingOccurrences(of: key, with: "«chiave»")
            let encoded = URIComponent.encode(key)
            if encoded != key {
                value = value.replacingOccurrences(of: encoded, with: "«chiave»")
            }
        }
        return Redactor.redact(value)
    }

    private func sanitize(_ text: String?, key: String) -> String? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let cleaned = TorBoxClient.scrub(raw, key: key)
        return String(cleaned.prefix(240))
    }
}
