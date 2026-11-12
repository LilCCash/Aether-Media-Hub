import Foundation
import AetherCore

/// Authenticated HLS/DASH relay. The receiver only sees random, session-local resource names;
/// origin URLs and request headers remain on the phone.
final class AdaptiveStreamRelaySource: RelaySource, @unchecked Sendable {
    private struct Route {
        let url: URL
        let contentType: String
    }
    private struct DynamicRoute {
        let localPrefix: String
        let rawTemplate: String
        let baseURL: URL
        let tokens: [(name: String, format: String?, placeholder: String)]
        let regex: NSRegularExpression
        let contentType: String
    }

    private let upstream: RelayUpstream
    private let guardian: UpstreamGuard
    private let rootLeaf: String
    private let rootType: String
    private let onUpstreamRejected: (@Sendable (Int) -> Void)?
    private let session: URLSession
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var routeNames: [String: String] = [:]
    private var dynamicRoutes: [DynamicRoute] = []
    private var pending: [String: Data] = [:]
    private var closed = false

    init(upstream: RelayUpstream, guardian: UpstreamGuard, extension ext: String,
         onUpstreamRejected: (@Sendable (Int) -> Void)? = nil) {
        self.upstream = upstream
        self.guardian = guardian
        self.onUpstreamRejected = onUpstreamRejected
        let normalized = ext.lowercased()
        rootLeaf = normalized == "mpd" ? "video.mpd" : "video.m3u8"
        rootType = normalized == "mpd" ? "application/dash+xml" : "application/vnd.apple.mpegurl"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: AdaptiveNoRedirectDelegate(), delegateQueue: nil)
    }

    func prepare() async throws -> RelayResource {
        let data = try await load(upstream.url, manifestType: rootType)
        store(data, for: rootLeaf)
        return RelayResource(contentType: rootType, length: Int64(data.count), acceptsRanges: true)
    }

    func resource(named leaf: String) async throws -> RelayResource {
        guard !isClosed else { throw RelayError.notFound }
        let data: Data
        if let cached = takePending(leaf, remove: false) {
            data = cached
        } else if leaf == rootLeaf {
            data = try await load(upstream.url, manifestType: rootType)
            store(data, for: leaf)
        } else {
            guard let route = resolve(leaf) else { throw RelayError.notFound }
            let isManifest = route.contentType == "application/vnd.apple.mpegurl" || route.contentType == "application/x-mpegURL"
                || route.contentType == "application/dash+xml"
            data = try await load(route.url, manifestType: isManifest ? route.contentType : nil)
            store(data, for: leaf)
        }
        let type = leaf == rootLeaf ? rootType : (resolve(leaf)?.contentType ?? mimeType(for: leaf))
        return RelayResource(contentType: type, length: Int64(data.count), acceptsRanges: true)
    }

    func open(_ leaf: String, range: ClosedRange<Int64>?) async throws -> RelayBodyReader {
        guard !isClosed else { throw RelayError.notFound }
        if takePending(leaf, remove: false) == nil { _ = try await resource(named: leaf) }
        guard let data = takePending(leaf, remove: true) else { throw RelayError.notFound }
        let selected: Data
        if let range = range {
            guard range.lowerBound >= 0, range.upperBound < Int64(data.count) else {
                throw RelayError.rangeNotSatisfiable(total: Int64(data.count))
            }
            selected = data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
        } else {
            selected = data
        }
        return AdaptiveDataReader(selected)
    }

    func close() {
        lock.lock()
        closed = true
        routes.removeAll()
        routeNames.removeAll()
        dynamicRoutes.removeAll()
        pending.removeAll()
        lock.unlock()
        session.invalidateAndCancel()
    }

    // MARK: Fetching

    private func load(_ url: URL, manifestType: String?) async throws -> Data {
        let maximum = manifestType == nil ? 48 * 1024 * 1024 : 4 * 1024 * 1024
        let data = try await fetch(url)
        guard data.count <= maximum else { throw RelayError.upstreamNotMedia }
        guard let manifestType = manifestType else { return data }
        guard let text = String(data: data, encoding: .utf8) else { throw RelayError.upstreamNotMedia }
        if manifestType == "application/vnd.apple.mpegurl" || manifestType == "application/x-mpegURL" {
            return Data(try rewriteHLS(text, baseURL: url).utf8)
        }
        return Data(try rewriteDASH(text, baseURL: url).utf8)
    }

    private func fetch(_ originalURL: URL) async throws -> Data {
        var current = originalURL
        var previous = originalURL
        for hop in 0...5 {
            do {
                if hop == 0 { try await guardian.validateOrigin(current) }
                else { try await guardian.validateRedirect(from: previous, to: current, hop: hop, origin: originalURL) }
            } catch { throw RelayError.blockedTarget }

            var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.allHTTPHeaderFields = RelayHeaderPolicy.upstreamRequestHeaders(
                session: upstream.headers, range: nil,
                includeSession: guardian.mayCarrySessionHeaders(to: current, origin: upstream.url))
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(for: request) }
            catch { throw RelayError.mapping(error) }
            guard let http = response as? HTTPURLResponse else { throw RelayError.upstreamUnreachable(code: -1) }
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard hop < 5, let value = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: value, relativeTo: current)?.absoluteURL else {
                    throw RelayError.upstreamRejected(status: http.statusCode)
                }
                previous = current
                current = next
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                if [401, 403, 404, 410].contains(http.statusCode) { onUpstreamRejected?(http.statusCode) }
                throw RelayError.upstreamRejected(status: http.statusCode)
            }
            return data
        }
        throw RelayError.upstreamUnreachable(code: -1)
    }

    // MARK: HLS

    private func rewriteHLS(_ input: String, baseURL: URL) throws -> String {
        let upper = input.uppercased()
        if upper.contains("METHOD=SAMPLE-AES") || upper.contains("KEYFORMAT=") && !upper.contains("KEYFORMAT=\"IDENTITY\"") {
            throw RelayError.upstreamNotMedia
        }
        var output: [String] = []
        for rawLine in input.components(separatedBy: .newlines) {
            var line = rawLine
            if line.hasPrefix("#") {
                line = try replacingURIAttributes(in: line, baseURL: baseURL)
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                line = try localReference(trimmed, baseURL: baseURL)
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private func replacingURIAttributes(in line: String, baseURL: URL) throws -> String {
        let pattern = #"URI="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let mutable = NSMutableString(string: line)
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).reversed()
        for match in matches where match.numberOfRanges > 1 {
            let value = (line as NSString).substring(with: match.range(at: 1))
            let local = try localReference(value, baseURL: baseURL)
            mutable.replaceCharacters(in: match.range(at: 1), with: local)
        }
        return mutable as String
    }

    // MARK: DASH

    private func rewriteDASH(_ input: String, baseURL: URL) throws -> String {
        var output = input
        // Root-level BaseURL is folded into the base used for every SegmentURL/SegmentTemplate below.
        if let regex = try? NSRegularExpression(pattern: #"<BaseURL[^>]*>\s*([^<]+?)\s*</BaseURL>"#),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let valueRange = Range(match.range(at: 1), in: output) {
            let raw = String(output[valueRange]).replacingOccurrences(of: "&amp;", with: "&")
            let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL ?? baseURL
            output.replaceSubrange(Range(match.range, in: output)!, with: "")
            return try rewriteDASHAttributes(output, baseURL: resolved)
        }
        return try rewriteDASHAttributes(output, baseURL: baseURL)
    }

    private func rewriteDASHAttributes(_ input: String, baseURL: URL) throws -> String {
        let pattern = #"(\b(?:media|initialization|sourceURL)\s*=\s*")([^"]+)(")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let mutable = NSMutableString(string: input)
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: (input as NSString).length)).reversed()
        for match in matches where match.numberOfRanges > 2 {
            let raw = (input as NSString).substring(with: match.range(at: 2)).replacingOccurrences(of: "&amp;", with: "&")
            let local: String
            if raw.contains("$") {
                guard let template = registerDynamicTemplate(raw, baseURL: baseURL) else { throw RelayError.upstreamNotMedia }
                local = template
            } else {
                local = try localReference(raw, baseURL: baseURL)
            }
            mutable.replaceCharacters(in: match.range(at: 2), with: local)
        }
        return mutable as String
    }

    // MARK: Local resource names

    private func localReference(_ reference: String, baseURL: URL) throws -> String {
        guard !reference.lowercased().hasPrefix("data:"),
              let url = URL(string: reference.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw RelayError.upstreamNotMedia }
        let key = url.absoluteString
        lock.lock()
        if let existing = routeNames[key] { lock.unlock(); return existing }
        let ext = url.pathExtension.lowercased()
        let safeExt = ext.range(of: #"^[a-z0-9]{1,8}$"#, options: .regularExpression) != nil ? ext : "bin"
        let leaf = randomLeaf(extension: safeExt)
        routes[leaf] = Route(url: url, contentType: mimeType(for: leaf))
        routeNames[key] = leaf
        lock.unlock()
        return leaf
    }

    private func registerDynamicTemplate(_ raw: String, baseURL: URL) -> String? {
        guard let tokenRegex = try? NSRegularExpression(pattern: #"(\$(Number|Time|RepresentationID|Bandwidth)(?:%0([1-9][0-9]?)d)?\$)"#) else { return nil }
        let ns = raw as NSString
        let matches = tokenRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var cursor = 0
        var localPattern = ""
        var tokens: [(name: String, format: String?, placeholder: String)] = []
        for (index, match) in matches.enumerated() {
            localPattern += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = ns.substring(with: match.range(at: 1))
            let name = ns.substring(with: match.range(at: 2))
            let format = match.range(at: 3).location == NSNotFound ? nil : ns.substring(with: match.range(at: 3))
            localPattern += "__DYN\(index)__"
            tokens.append((name, format, token))
            cursor = match.range.location + match.range.length
        }
        localPattern += ns.substring(from: cursor)
        guard !localPattern.contains("$") else { return nil }
        var validationURL = raw
        for token in tokens { validationURL = validationURL.replacingOccurrences(of: token.placeholder, with: "1") }
        guard URL(string: validationURL, relativeTo: baseURL) != nil else { return nil }
        let prefix = "r" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let ext = URL(fileURLWithPath: raw).pathExtension.lowercased()
        let safeExt = ext.range(of: #"^[a-z0-9]{1,8}$"#, options: .regularExpression) != nil ? ext : "bin"
        let local = prefix + "_" + tokens.map { $0.placeholder }.joined(separator: "_") + "." + safeExt
        var regexPattern = NSRegularExpression.escapedPattern(for: local)
        for token in tokens {
            let escaped = NSRegularExpression.escapedPattern(for: token.placeholder)
            let capture = token.name == "RepresentationID" ? "([A-Za-z0-9_.-]+)" : "([0-9]+)"
            regexPattern = regexPattern.replacingOccurrences(of: escaped, with: capture)
        }
        regexPattern = "^" + regexPattern + "$"
        guard let routeRegex = try? NSRegularExpression(pattern: regexPattern) else { return nil }
        lock.lock()
        dynamicRoutes.append(DynamicRoute(localPrefix: prefix, rawTemplate: raw, baseURL: baseURL, tokens: tokens,
                                          regex: routeRegex, contentType: mimeType(for: raw)))
        lock.unlock()
        return local
    }

    private func resolve(_ leaf: String) -> Route? {
        lock.lock()
        if let route = routes[leaf] { lock.unlock(); return route }
        let candidates = dynamicRoutes
        lock.unlock()
        for candidate in candidates {
            let ns = leaf as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = candidate.regex.firstMatch(in: leaf, range: range), match.range == range else { continue }
            var raw = candidate.rawTemplate
            for (index, token) in candidate.tokens.enumerated().reversed() {
                let capture = ns.substring(with: match.range(at: index + 1))
                let replacement: String
                if let format = token.format, let number = Int(capture) { replacement = String(format: "%0\(format)d", number) }
                else { replacement = capture }
                if let swiftRange = raw.range(of: token.placeholder) {
                    raw = raw.replacingOccurrences(of: token.placeholder, with: replacement)
                }
            }
            guard let url = URL(string: raw, relativeTo: candidate.baseURL)?.absoluteURL else { continue }
            return Route(url: url, contentType: candidate.contentType)
        }
        return nil
    }

    private func mimeType(for leaf: String) -> String {
        let ext = URL(fileURLWithPath: leaf).pathExtension.lowercased()
        switch ext {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mpd": return "application/dash+xml"
        case "ts": return "video/mp2t"
        case "m4s", "mp4", "m4v": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "vtt": return "text/vtt"
        case "key", "bin": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }

    private func randomLeaf(extension ext: String) -> String {
        "r" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)) + "." + ext
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func store(_ data: Data, for leaf: String) {
        lock.lock()
        pending[leaf] = data
        if pending.count > 8, let first = pending.keys.first { pending[first] = nil }
        lock.unlock()
    }

    private func takePending(_ leaf: String, remove: Bool) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let value = pending[leaf]
        if remove { pending[leaf] = nil }
        return value
    }
}

private final class AdaptiveNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class AdaptiveDataReader: RelayBodyReader, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var offset = 0
    private var cancelled = false

    init(_ data: Data) { self.data = data }

    func next() async throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, let data = data, offset < data.count else { self.data = nil; return nil }
        let end = min(offset + 64 * 1024, data.count)
        let chunk = data.subdata(in: offset..<end)
        offset = end
        if offset >= data.count { self.data = nil }
        return chunk
    }

    func cancel() {
        lock.lock()
        cancelled = true
        data = nil
        lock.unlock()
    }
}
