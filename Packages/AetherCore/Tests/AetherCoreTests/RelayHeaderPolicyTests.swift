import XCTest
@testable import AetherCore

final class RelayHeaderPolicyTests: XCTestCase {
    private func lowercasedNames(_ head: RelayResponseHead) -> Set<String> {
        return Set(head.headers.map { $0.name.lowercased() })
    }

    // MARK: Towards the real source

    func testTheUpstreamRequestIsBuiltFromScratch() {
        let headers = RelayHeaderPolicy.upstreamRequestHeaders(session: [:], range: 100...199, includeSession: true)
        XCTAssertEqual(headers, ["User-Agent": "Aether/1.0", "Accept": "*/*", "Accept-Encoding": "identity", "Range": "bytes=100-199"])
    }

    func testNoRangeMeansNoRangeHeader() {
        let headers = RelayHeaderPolicy.upstreamRequestHeaders(session: [:], range: nil, includeSession: true)
        XCTAssertNil(headers["Range"])
    }

    func testSessionHeadersCannotOverrideWhatTheRelayOwns() {
        let session = ["Range": "bytes=0-", "accept-encoding": "gzip", "Accept": "text/html", "Host": "evil.example", "If-Range": "x",
                       "Referer": "https://addon.example/", "Authorization": "Bearer abc", "Cookie": "a=b"]
        let headers = RelayHeaderPolicy.upstreamRequestHeaders(session: session, range: 0...9, includeSession: true)
        XCTAssertEqual(headers["Range"], "bytes=0-9")
        XCTAssertEqual(headers["Accept-Encoding"], "identity")
        XCTAssertEqual(headers["Accept"], "*/*")
        XCTAssertNil(headers["Host"])
        XCTAssertNil(headers["If-Range"])
        XCTAssertEqual(headers["Referer"], "https://addon.example/")
        XCTAssertEqual(headers["Authorization"], "Bearer abc")
        XCTAssertEqual(headers["Cookie"], "a=b")
        XCTAssertEqual(Set(headers.keys.map { $0.lowercased() }).count, headers.count, "a name must not appear in two capitalisations")
    }

    func testASessionMayChooseItsUserAgent() {
        let headers = RelayHeaderPolicy.upstreamRequestHeaders(session: ["user-agent": "Custom/2"], range: nil, includeSession: true)
        XCTAssertEqual(headers["User-Agent"], "Custom/2")
        XCTAssertNil(headers["user-agent"])
    }

    func testSessionHeadersCanBeLeftOutEntirely() {
        let headers = RelayHeaderPolicy.upstreamRequestHeaders(session: ["Referer": "https://a.example/", "Cookie": "a=b"], range: 0...9, includeSession: false)
        XCTAssertEqual(Set(headers.keys), ["User-Agent", "Accept", "Accept-Encoding", "Range"])
    }

    func testSanitizingDropsTheDangerousHeadersAndKeepsTheUseful() {
        let dirty: [String: String] = [
            "Host": "x", "Content-Length": "5", "Transfer-Encoding": "chunked", "Connection": "keep-alive", "Upgrade": "h2c", "TE": "trailers",
            "Trailer": "x", "Expect": "100-continue", "Proxy-Authorization": "Basic x", "Proxy-Connection": "close",
            "Bad Name": "v", "Bad:Name": "v", "": "v",
            "X-CR": "a\rb", "X-LF": "a\nb", "X-NUL": "a\u{0}b", "X-Bell": "a\u{7}b", "X-Accent": "caf\u{E9}",
            "Referer": "https://addon.example/", "Authorization": "Bearer abc", "X-Tab": "a\tb"
        ]
        let clean = RelayHeaderPolicy.sanitizeSessionHeaders(dirty)
        XCTAssertEqual(Set(clean.keys), ["Referer", "Authorization", "X-Tab"])
    }

    func testSanitizingBoundsTheNumberAndSizeOfHeaders() {
        var many: [String: String] = [:]
        for index in 0..<40 { many["X-\(index)"] = "v" }
        XCTAssertEqual(RelayHeaderPolicy.sanitizeSessionHeaders(many).count, 16)
        XCTAssertTrue(RelayHeaderPolicy.sanitizeSessionHeaders(["X-Big": String(repeating: "a", count: 5000)]).isEmpty)
        XCTAssertTrue(RelayHeaderPolicy.sanitizeSessionHeaders([String(repeating: "N", count: 100): "v"]).isEmpty)
    }

    func testWhichUpstreamContentTypesCanBeRelayed() {
        for accepted in ["video/x-matroska", "video/mp4", "application/octet-stream", "binary/octet-stream", "video/mp4; codecs=avc1", "VIDEO/MP4", "", nil] as [String?] {
            XCTAssertTrue(RelayHeaderPolicy.isAcceptableUpstreamContentType(accepted), accepted ?? "nil")
        }
        for denied in ["text/html", "text/html; charset=utf-8", "TEXT/PLAIN", "application/json", "application/xml", "application/problem+json",
                       "application/xhtml+xml", "application/javascript"] {
            XCTAssertFalse(RelayHeaderPolicy.isAcceptableUpstreamContentType(denied), denied)
        }
    }

    // MARK: Towards the receiver

    func testTheReceiverHeadHasWhatAPlayerNeedsAndNothingFromUpstream() {
        let head = RelayHeaderPolicy.receiverHead(status: 206, contentType: "video/x-matroska", contentLength: 100,
                                                  contentRange: RelayHeaderPolicy.contentRange(100...199, total: 1000),
                                                  acceptsRanges: true, wantsDLNAFeatures: false, date: Date(timeIntervalSince1970: 784_111_777))
        let names = lowercasedNames(head)
        for required in ["content-type", "content-length", "content-range", "accept-ranges", "cache-control", "x-content-type-options",
                         "referrer-policy", "connection", "date", "access-control-allow-origin", "transfermode.dlna.org"] {
            XCTAssertTrue(names.contains(required), required)
        }
        for forbidden in ["set-cookie", "location", "www-authenticate", "content-disposition", "link", "server", "via", "x-powered-by", "alt-svc",
                          "contentfeatures.dlna.org"] {
            XCTAssertFalse(names.contains(forbidden), forbidden)
        }
        let text = String(decoding: head.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        XCTAssertTrue(text.contains("Content-Range: bytes 100-199/1000\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("Access-Control-Allow-Origin: *\r\n"))
        XCTAssertTrue(text.contains("Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n"))
    }

    func testDLNAFeaturesAreOnlyAnsweredWhenAsked() {
        let asked = RelayHeaderPolicy.receiverHead(status: 200, contentType: "video/mp4", contentLength: 10, contentRange: nil, acceptsRanges: true,
                                                   wantsDLNAFeatures: true, date: Date())
        XCTAssertTrue(lowercasedNames(asked).contains("contentfeatures.dlna.org"))
        let notAsked = RelayHeaderPolicy.receiverHead(status: 200, contentType: "video/mp4", contentLength: 10, contentRange: nil, acceptsRanges: true,
                                                      wantsDLNAFeatures: false, date: Date())
        XCTAssertFalse(lowercasedNames(notAsked).contains("contentfeatures.dlna.org"))
    }

    func testAnUnknownLengthOmitsContentLengthAndRangesWhenNotAccepted() {
        let head = RelayHeaderPolicy.receiverHead(status: 200, contentType: "video/mp4", contentLength: nil, contentRange: nil, acceptsRanges: false,
                                                  wantsDLNAFeatures: false, date: Date())
        let names = lowercasedNames(head)
        XCTAssertFalse(names.contains("content-length"))
        XCTAssertFalse(names.contains("accept-ranges"))
    }

    func testContentRangeText() {
        XCTAssertEqual(RelayHeaderPolicy.contentRange(0...0, total: 1), "bytes 0-0/1")
        XCTAssertEqual(RelayHeaderPolicy.contentRange(5...9, total: nil), "bytes 5-9/*")
    }

    func testTheHttpDateIsInTheStandardFormat() {
        XCTAssertEqual(RelayHeaderPolicy.httpDate(Date(timeIntervalSince1970: 784_111_777)), "Sun, 06 Nov 1994 08:49:37 GMT")
    }

    func testErrorAnswersCarryNoBodyAndTheRightExtras() {
        let notAllowed = String(decoding: RelayHeaderPolicy.errorHead(status: 405).serialized(), as: UTF8.self)
        XCTAssertTrue(notAllowed.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
        XCTAssertTrue(notAllowed.contains("Allow: GET, HEAD, OPTIONS\r\n"))
        XCTAssertTrue(notAllowed.contains("Content-Length: 0\r\n"))
        let unsatisfiable = String(decoding: RelayHeaderPolicy.errorHead(status: 416, total: 1000).serialized(), as: UTF8.self)
        XCTAssertTrue(unsatisfiable.hasPrefix("HTTP/1.1 416 Range Not Satisfiable\r\n"))
        XCTAssertTrue(unsatisfiable.contains("Content-Range: bytes */1000\r\n"))
        for status in [400, 431, 502, 503, 505] {
            XCTAssertTrue(String(decoding: RelayHeaderPolicy.errorHead(status: status).serialized(), as: UTF8.self).contains("Connection: close\r\n"))
        }
    }

    func testOptionsAnswersWithoutABody() {
        let text = String(decoding: RelayHeaderPolicy.optionsHead().serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        XCTAssertTrue(text.contains("Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"))
    }

    func testTheNotFoundAnswerIsFixedAndRevealsNothing() {
        let bytes = RelayHeaderPolicy.notFoundBytes
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(text.lowercased().contains("date:"))
        XCTAssertFalse(text.lowercased().contains("server:"))
        XCTAssertEqual(bytes, RelayHeaderPolicy.notFoundBytes)
    }
}

final class RelayUpstreamTests: XCTestCase {
    private let upstream = RelayUpstream(url: URL(string: "https://secret-host.example/dl/SECRET123?token=SECRET123")!,
                                         headers: ["Authorization": "Bearer SECRET123"])

    func testNothingPrintsTheRealAddressOrHeaders() {
        var dumped = ""
        dump(upstream, to: &dumped)
        let everything = [upstream.description, upstream.debugDescription, String(describing: upstream), String(reflecting: upstream),
                          "\(upstream)", dumped, "\(Mirror(reflecting: upstream).children.map { "\($0.value)" })"]
        for text in everything {
            XCTAssertFalse(text.contains("SECRET123"), text)
            XCTAssertFalse(text.contains("secret-host"), text)
            XCTAssertFalse(text.contains("Bearer"), text)
        }
    }

    func testTheRealValuesAreStillThereForTheFetcher() {
        XCTAssertEqual(upstream.url.host, "secret-host.example")
        XCTAssertEqual(upstream.headers["Authorization"], "Bearer SECRET123")
    }
}
