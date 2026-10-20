import Foundation

// Computing `videoHash` / `videoSize` for a remote stream (docs/05-SUBTITLES-RESEARCH.md §5).
//
// Two small `Range` requests (first and last 64 KiB) are enough for the OpenSubtitles hash, so the whole file is never
// downloaded. The probe gives up (and the addon request then carries only `filename`) whenever the answer cannot be trusted:
// `200` instead of `206`, missing or inconsistent `Content-Range`, `416`, a body of the wrong length, compressed bodies,
// a file smaller than 128 KiB, HLS/DASH playlists, torrents and every other source that is not one plain file.

/// Hash and size of a remote file, ready to be sent as the `videoHash` / `videoSize` extras.
public struct SubtitleHashResult: Hashable, Sendable {
    /// 16 lowercase hexadecimal digits.
    public let hash: String
    /// Size in bytes (`Content-Range` total).
    public let size: Int64

    public init(hash: String, size: Int64) {
        self.hash = hash
        self.size = size
    }
}

/// Why no hash could be computed. Never shown as an error to the user: the player simply asks the addons without hash.
public enum SubtitleHashFailure: Error, Equatable, Sendable {
    /// Not one plain file: torrent, YouTube, external page, player frame, archive, unknown source.
    case notAFile
    /// HLS / DASH / Smooth Streaming: there is no single file to hash.
    case adaptiveStream
    /// `http://` to a public host. `URLSession` would be blocked by App Transport Security, so no request is made.
    case insecureTransport
    /// Not an http(s) URL.
    case invalidURL
    /// The server ignored `Range` (`200`), answered another range, omitted `Content-Range` or compressed the body.
    case rangeUnsupported
    /// `Content-Range` carries no total (`bytes 0-65535/*`).
    case unknownSize
    /// `416 Range Not Satisfiable`.
    case notSatisfiable
    /// Smaller than 131072 bytes: no valid hash exists.
    case tooSmall(size: Int64)
    /// The body is not as long as the range that was asked.
    case truncated(expected: Int, received: Int)
    /// The total reported by the second request differs from the first one: the file changed in between.
    case changedWhileReading
    /// Any other HTTP status (`401`, `403`, `404`, `5xx`...).
    case httpStatus(Int)
    /// The request itself failed (policy, TLS, timeout, offline...).
    case network(AddonError)
    case cancelled

    /// Italian description for diagnostic logs.
    public var message: String {
        switch self {
        case .notAFile: return "La sorgente non è un file unico: hash non calcolabile."
        case .adaptiveStream: return "Flusso HLS/DASH: hash non calcolabile."
        case .insecureTransport: return "Indirizzo http su Internet: hash non calcolato."
        case .invalidURL: return "Indirizzo della sorgente non valido."
        case .rangeUnsupported: return "Il server non supporta le richieste Range in modo affidabile."
        case .unknownSize: return "Il server non comunica la dimensione del file."
        case .notSatisfiable: return "Il server ha rifiutato l'intervallo richiesto (416)."
        case .tooSmall(let size): return "File troppo piccolo per l'hash (\(size) byte)."
        case .truncated(let expected, let received): return "Risposta incompleta (\(received) byte invece di \(expected))."
        case .changedWhileReading: return "La dimensione del file è cambiata durante la lettura."
        case .httpStatus(let status): return "Risposta HTTP \(status)."
        case .network(let error): return error.message
        case .cancelled: return "Operazione annullata."
        }
    }
}

/// Computes the OpenSubtitles hash of a remote file with two `Range` requests. Stateless: results are not cached here,
/// the caller keeps them for the session (debrid URLs expire, so a result must not outlive the playback session).
///
/// Requests use `Accept-Encoding: identity` and the stream's `proxyHeaders.request`; the `Range`, `Accept` and
/// `Accept-Encoding` headers of the stream are replaced. The response size is capped at 64 KiB, so a server that ignores
/// `Range` is cut off by the HTTP client instead of being downloaded.
///
/// Public hosts reached over plain `http://` are skipped on purpose: `NSAllowsArbitraryLoadsInMediaAndWebContent` applies
/// to AVFoundation, not to data tasks, so the probe would fail on device (and `NetworkPolicy` refuses it). Local-network
/// `http://` hosts and every `https://` host are probed.
public struct SubtitleHashProbe: Sendable {
    public let http: HTTPClient
    /// Used only to tell local-network hosts from public ones for `http://` URLs; the HTTP client enforces its own policy.
    public let policy: NetworkPolicy
    public let timeout: TimeInterval

    public init(http: HTTPClient, policy: NetworkPolicy = NetworkPolicy(), timeout: TimeInterval = 10) {
        self.http = http
        self.policy = policy
        self.timeout = timeout
    }

    // MARK: Entry points

    /// Hash of the stream's file. Values from `behaviorHints` (both `videoHash` and `videoSize`) are returned without any
    /// network traffic; otherwise a direct URL is probed. Every other kind of source fails with `.notAFile`.
    public func probe(stream: AddonStream) async -> Result<SubtitleHashResult, SubtitleHashFailure> {
        let hints = stream.behaviorHints
        if let hash = SubtitleVideoParams.normalisedHash(hints.videoHash), let size = hints.videoSize, size > 0 {
            return .success(SubtitleHashResult(hash: hash, size: size))
        }
        switch stream.source {
        case .url(let raw):
            guard let url = URL.lenient(raw) else { return .failure(.invalidURL) }
            return await probe(url: url, headers: hints.proxyRequestHeaders)
        case .youtube, .torrent, .external, .playerFrame, .archive, .unknown:
            return .failure(.notAFile)
        }
    }

    /// Hash of the file behind `url`. `headers` are the request headers the stream requires (cookies, referer...).
    public func probe(url: URL, headers: [String: String] = [:]) async -> Result<SubtitleHashResult, SubtitleHashFailure> {
        if Task.isCancelled { return .failure(.cancelled) }
        if let skipped = await precheck(url) { return .failure(skipped) }
        do {
            let result = try await run(url: url, headers: headers)
            return .success(result)
        } catch let failure as SubtitleHashFailure {
            return .failure(failure)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.network(.unreachable(url.host ?? url.absoluteString)))
        }
    }

    // MARK: Pre-checks

    /// Reasons not to send any request at all.
    private func precheck(_ url: URL) async -> SubtitleHashFailure? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .invalidURL
        }
        if SubtitleHashProbe.isAdaptive(url) { return .adaptiveStream }
        if scheme == "http" {
            let isLocal = await policy.isLocalNetwork(url)
            if !isLocal { return .insecureTransport }
        }
        return nil
    }

    /// HLS (`.m3u8`), DASH (`.mpd`) and Smooth Streaming (`.ism/manifest`) are recognised from the URL alone.
    static func isAdaptive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "m3u" || ext == "mpd" || ext == "ism" || ext == "isml" { return true }
        let text = url.absoluteString.lowercased()
        return text.contains(".m3u8") || text.contains(".mpd") || text.contains(".ism/manifest") || text.contains(".isml/manifest")
    }

    // MARK: Requests

    private struct Window {
        var data: Data
        var total: Int64
    }

    private func run(url: URL, headers: [String: String]) async throws -> SubtitleHashResult {
        let chunk = Int64(OpenSubtitlesHash.chunkSize)
        let head = try await fetchWindow(url: url, headers: headers, first: 0, expectedTotal: nil)
        try checkCancellation()
        let tail = try await fetchWindow(url: url, headers: headers, first: head.total - chunk, expectedTotal: head.total)
        guard let hash = OpenSubtitlesHash.compute(size: UInt64(head.total), head: head.data, tail: tail.data) else {
            throw SubtitleHashFailure.tooSmall(size: head.total)
        }
        return SubtitleHashResult(hash: hash, size: head.total)
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw SubtitleHashFailure.cancelled }
    }

    /// One `Range` request for `chunkSize` bytes starting at `first`, validated against the response headers.
    /// `expectedTotal` is nil for the first request (which also learns the total) and the known total for the second.
    private func fetchWindow(url: URL, headers: [String: String], first: Int64, expectedTotal: Int64?) async throws -> Window {
        let chunk = Int64(OpenSubtitlesHash.chunkSize)
        let last = first + chunk - 1
        var requestHeaders = SubtitleHashProbe.requestHeaders(base: headers)
        requestHeaders["Range"] = "bytes=\(first)-\(last)"
        let request = HTTPRequest(url: url, method: "GET", headers: requestHeaders, body: nil, timeout: timeout,
                                  maxBytes: OpenSubtitlesHash.chunkSize, purpose: .addonRequest)
        let response = try await send(request)

        switch response.statusCode {
        case 206:
            break
        case 200:
            // The server ignored Range and is sending the whole file.
            throw SubtitleHashFailure.rangeUnsupported
        case 416:
            throw SubtitleHashFailure.notSatisfiable
        default:
            throw SubtitleHashFailure.httpStatus(response.statusCode)
        }

        if let encoding = response.headers["content-encoding"]?.trimmingCharacters(in: .whitespaces).lowercased(),
           !encoding.isEmpty, encoding != "identity" {
            throw SubtitleHashFailure.rangeUnsupported
        }
        guard let headerValue = response.headers["content-range"],
              let range = SubtitleHashProbe.parseContentRange(headerValue) else {
            throw SubtitleHashFailure.rangeUnsupported
        }
        guard let total = range.total else { throw SubtitleHashFailure.unknownSize }
        if let expected = expectedTotal {
            if total != expected { throw SubtitleHashFailure.changedWhileReading }
        } else if total < Int64(OpenSubtitlesHash.minimumFileSize) {
            throw SubtitleHashFailure.tooSmall(size: total)
        }
        if range.first != first || range.last != last { throw SubtitleHashFailure.rangeUnsupported }
        if response.data.count != OpenSubtitlesHash.chunkSize {
            throw SubtitleHashFailure.truncated(expected: OpenSubtitlesHash.chunkSize, received: response.data.count)
        }
        return Window(data: response.data, total: total)
    }

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await http.send(request)
        } catch is CancellationError {
            throw SubtitleHashFailure.cancelled
        } catch let error as AddonError {
            if case .responseTooLarge = error { throw SubtitleHashFailure.rangeUnsupported }
            if case .cancelled = error { throw SubtitleHashFailure.cancelled }
            throw SubtitleHashFailure.network(error)
        } catch {
            throw SubtitleHashFailure.network(.unreachable(request.url.host ?? request.url.absoluteString))
        }
    }

    /// Stream headers without `Range` / `Accept` / `Accept-Encoding` (the probe owns those), plus the probe's own.
    static func requestHeaders(base: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in base {
            let lower = name.lowercased()
            if lower == "range" || lower == "accept" || lower == "accept-encoding" { continue }
            result[name] = value
        }
        result["Accept"] = "*/*"
        result["Accept-Encoding"] = "identity"
        return result
    }

    // MARK: Content-Range

    struct ContentRange: Equatable {
        var first: Int64
        var last: Int64
        /// nil for `bytes 0-9/*`.
        var total: Int64?
    }

    /// Parses `bytes 0-65535/12909756`. Returns nil for anything else, including the unsatisfied form `bytes */1234`.
    static func parseContentRange(_ value: String) -> ContentRange? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        var rest = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("=") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let halves = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let span = halves[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard span.count == 2 else { return nil }
        let firstText = span[0].trimmingCharacters(in: .whitespaces)
        let lastText = span[1].trimmingCharacters(in: .whitespaces)
        guard let first = Int64(firstText), let last = Int64(lastText), first >= 0, last >= first else { return nil }
        let totalText = halves[1].trimmingCharacters(in: .whitespaces)
        if totalText == "*" { return ContentRange(first: first, last: last, total: nil) }
        guard let total = Int64(totalText), total > last else { return nil }
        return ContentRange(first: first, last: last, total: total)
    }
}

/// The `videoHash` / `videoSize` / `filename` triple an addon request carries (`VideoParams` in stremio-core).
public struct SubtitleVideoParams: Hashable, Sendable {
    public var hash: String?
    public var size: Int64?
    public var filename: String?

    public init(hash: String? = nil, size: Int64? = nil, filename: String? = nil) {
        self.hash = hash
        self.size = size
        self.filename = filename
    }

    /// Nothing known: the addons are asked with the video id alone.
    public var isEmpty: Bool {
        return hash == nil && size == nil && filename == nil
    }

    /// The extras in the order the Stremio clients send them: `videoHash`, `videoSize`, `filename`.
    var extras: [ExtraValue] {
        var result: [ExtraValue] = []
        if let hash = hash, !hash.isEmpty { result.append(ExtraValue(name: "videoHash", value: hash)) }
        if let size = size { result.append(ExtraValue(name: "videoSize", value: String(size))) }
        if let filename = filename, !filename.isEmpty { result.append(ExtraValue(name: "filename", value: filename)) }
        return result
    }

    // MARK: Resolution

    /// Chooses the values to send, with the precedence of stremio-core:
    ///  1. a complete pair (`videoHash` and `videoSize`) from the stream's `behaviorHints`: no network needed;
    ///  2. otherwise the locally computed `local` pair (hash and size always travel together, they describe the same bytes);
    ///  3. otherwise whatever single value the hints carry.
    /// The file name is `behaviorHints.filename`, then `filename` (known to the caller, for example from a torrent file list),
    /// then the last path segment of the stream URL (see `derivedFilename(fromURL:)`).
    public static func resolve(stream: AddonStream?, local: SubtitleHashResult? = nil, filename: String? = nil) -> SubtitleVideoParams {
        var hintHash: String?
        var hintSize: Int64?
        var hintName: String?
        if let hints = stream?.behaviorHints {
            hintHash = normalisedHash(hints.videoHash)
            if let size = hints.videoSize, size > 0 { hintSize = size }
            hintName = cleanedName(hints.filename)
        }

        var hash: String?
        var size: Int64?
        if hintHash != nil && hintSize != nil {
            hash = hintHash
            size = hintSize
        } else if let local = local {
            hash = normalisedHash(local.hash)
            size = local.size > 0 ? local.size : nil
        } else {
            hash = hintHash
            size = hintSize
        }

        var name: String? = hintName
        if name == nil { name = cleanedName(filename) }
        if name == nil, let source = stream?.source, case .url(let raw) = source {
            name = SubtitleVideoParams.derivedFilename(fromURL: raw)
        }
        return SubtitleVideoParams(hash: hash, size: size, filename: name)
    }

    /// File name for an addon request derived from a stream URL: the last path segment, without query string or fragment,
    /// percent-decoded. Returns nil when the URL does not end in something that looks like a file name (no extension, a
    /// playlist such as `index.m3u8` or `manifest.mpd`).
    public static func derivedFilename(fromURL raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return nil }
        // Cut on the raw text so strings Foundation refuses to parse (spaces, non-ASCII) work as well.
        if let fragment = path.firstIndex(of: "#") { path = String(path[path.startIndex..<fragment]) }
        if let query = path.firstIndex(of: "?") { path = String(path[path.startIndex..<query]) }
        if let schemeEnd = path.range(of: "://") {
            let afterScheme = path[schemeEnd.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            path = String(afterScheme[slash...])
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let lastSegment = segments.last else { return nil }
        let encoded = String(lastSegment)
        let decoded = encoded.removingPercentEncoding ?? encoded
        guard let name = cleanedName(decoded) else { return nil }
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        if ext.isEmpty || ext.count > 5 || !ext.allSatisfy({ $0.isLetter || $0.isNumber }) { return nil }
        if ext == "m3u8" || ext == "m3u" || ext == "mpd" || ext == "ism" || ext == "isml" { return nil }
        if !name.contains(where: { $0.isLetter }) { return nil }
        return name
    }

    /// Trimmed, no control characters, no directory part, at most 255 characters; nil when nothing is left.
    static func cleanedName(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar)
        }
        var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 255 { cleaned = String(cleaned.prefix(255)) }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Trimmed; 16 hexadecimal digits are lowercased (the canonical spelling); anything else is passed through unchanged
    /// (the addon decides what to do with it). nil for missing or blank values.
    static func normalisedHash(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let isHex = trimmed.count == 16 && trimmed.allSatisfy { $0.isHexDigit }
        return isHex ? trimmed.lowercased() : trimmed
    }
}
