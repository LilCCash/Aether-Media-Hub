import Foundation

/// Which headers go to the real source and which go to the receiver. Both lists are built from scratch: nothing a receiver sends is
/// copied upstream, and nothing the real source answers is copied to the receiver.
public enum RelayHeaderPolicy {
    public static let userAgent = "Aether/1.0"

    /// Headers the relay sets itself; a session (addon) may not override them.
    private static let relayOwned: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "upgrade", "te", "trailer", "expect", "keep-alive",
        "range", "accept", "accept-encoding", "if-range", "if-match", "if-none-match", "if-modified-since", "if-unmodified-since"
    ]
    private static let maxSessionHeaders = 16
    private static let maxNameLength = 64
    private static let maxValueLength = 2048

    // MARK: Towards the real source

    /// Headers an addon asked for (`behaviorHints.proxyHeaders.request`), reduced to the ones that are safe to forward.
    public static func sanitizeSessionHeaders(_ headers: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for name in headers.keys.sorted() {
            guard kept.count < maxSessionHeaders, let value = headers[name] else { break }
            let lower = name.lowercased()
            guard !name.isEmpty, name.utf8.count <= maxNameLength, name.utf8.allSatisfy(RelayRequestParser.isTokenCharacter) else { continue }
            guard !relayOwned.contains(lower), !lower.hasPrefix("proxy-") else { continue }
            guard value.utf8.count <= maxValueLength, value.utf8.allSatisfy({ ($0 >= 0x20 && $0 < 0x7F) || $0 == 9 }) else { continue }
            kept[name] = value
        }
        return kept
    }

    /// The whole header set of one request to the real source.
    public static func upstreamRequestHeaders(session: [String: String], range: ClosedRange<Int64>?, includeSession: Bool) -> [String: String] {
        var result: [String: String] = [
            "User-Agent": userAgent,
            "Accept": "*/*",
            // Without this the real source may compress the body and `Content-Range` would no longer count bytes of the file.
            "Accept-Encoding": "identity"
        ]
        if includeSession {
            for (name, value) in sanitizeSessionHeaders(session) {
                if name.lowercased() == "user-agent" { result["User-Agent"] = value } else { result[name] = value }
            }
        }
        if let range = range, range.lowerBound >= 0 {
            result["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        }
        return result
    }

    /// True for an answer that may be a video. A web page, a JSON error or an XML document is never relayed (a source that answers with
    /// one has most likely rejected the request).
    public static func isAcceptableUpstreamContentType(_ value: String?) -> Bool {
        guard let value = value else { return true }
        let type = value.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if type.isEmpty { return true }
        if type.hasPrefix("text/") { return false }
        if type.hasSuffix("+json") || type.hasSuffix("+xml") { return false }
        let denied: Set<String> = ["application/json", "application/xml", "application/xhtml+xml", "application/javascript", "application/x-javascript"]
        return !denied.contains(type)
    }

    // MARK: Towards the receiver

    /// "Sun, 06 Nov 1994 08:49:37 GMT".
    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    public static func contentRange(_ range: ClosedRange<Int64>, total: Int64?) -> String {
        return "bytes \(range.lowerBound)-\(range.upperBound)/\(total.map(String.init) ?? "*")"
    }

    fileprivate static let security: [RelayHeaderField] = [
        RelayHeaderField("Cache-Control", "no-store"),
        RelayHeaderField("X-Content-Type-Options", "nosniff"),
        RelayHeaderField("Referrer-Policy", "no-referrer"),
        RelayHeaderField("Connection", "close")
    ]

    private static let cors: [RelayHeaderField] = [
        RelayHeaderField("Access-Control-Allow-Origin", "*"),
        RelayHeaderField("Access-Control-Allow-Headers", "Range"),
        RelayHeaderField("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS"),
        RelayHeaderField("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges"),
        RelayHeaderField("Access-Control-Max-Age", "600")
    ]

    /// The head of a 200 or 206 answer. `contentRange` is nil for a 200. An unknown `contentLength` omits the header: the body then ends
    /// when the connection closes.
    public static func receiverHead(status: Int, contentType: String, contentLength: Int64?, contentRange: String?, acceptsRanges: Bool,
                                    wantsDLNAFeatures: Bool, date: Date) -> RelayResponseHead {
        var headers: [RelayHeaderField] = [RelayHeaderField("Content-Type", contentType)]
        if let length = contentLength { headers.append(RelayHeaderField("Content-Length", String(length))) }
        if let contentRange = contentRange { headers.append(RelayHeaderField("Content-Range", contentRange)) }
        if acceptsRanges { headers.append(RelayHeaderField("Accept-Ranges", "bytes")) }
        headers.append(RelayHeaderField("Date", httpDate(date)))
        headers.append(contentsOf: security)
        headers.append(contentsOf: cors)
        headers.append(RelayHeaderField("transferMode.dlna.org", "Streaming"))
        if wantsDLNAFeatures {
            headers.append(RelayHeaderField("contentFeatures.dlna.org", "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"))
        }
        return RelayResponseHead(status: status, headers: headers)
    }

    /// The answer to an OPTIONS request (a browser-like receiver asking what it may do).
    public static func optionsHead() -> RelayResponseHead {
        var headers: [RelayHeaderField] = [RelayHeaderField("Content-Length", "0"), RelayHeaderField("Allow", "GET, HEAD, OPTIONS")]
        headers.append(contentsOf: security)
        headers.append(contentsOf: cors)
        return RelayResponseHead(status: 204, headers: headers)
    }

    /// An error answer with an empty body: 400, 405, 416, 431, 502, 503, 505. Nothing in it tells why beyond the status line.
    public static func errorHead(status: Int, total: Int64? = nil) -> RelayResponseHead {
        var headers: [RelayHeaderField] = [RelayHeaderField("Content-Length", "0")]
        if status == 405 { headers.append(RelayHeaderField("Allow", "GET, HEAD, OPTIONS")) }
        if status == 416 { headers.append(RelayHeaderField("Content-Range", "bytes */\(total.map(String.init) ?? "*")")) }
        headers.append(contentsOf: security)
        return RelayResponseHead(status: status, headers: headers)
    }

    /// The one answer for everything that is not a granted request: an unknown token, an expired or revoked session, a wrong file name, a
    /// wrong peer, a path of the wrong shape. The bytes are identical in every case and carry no Date, so a probe learns nothing.
    public static let notFoundBytes: Data = {
        let head = RelayResponseHead(status: 404, headers: [RelayHeaderField("Content-Length", "0")] + RelayHeaderPolicy.security)
        return head.serialized()
    }()
}
