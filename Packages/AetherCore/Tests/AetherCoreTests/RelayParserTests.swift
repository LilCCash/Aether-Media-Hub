import XCTest
@testable import AetherCore

final class RelayParserTests: XCTestCase {
    private let token = String(repeating: "a1", count: 32)      // 64 lowercase hex characters

    private func request(_ target: String? = nil, method: String = "GET", version: String = "HTTP/1.1",
                         headers: [String] = ["Host: 192.168.1.5:50000"]) -> Data {
        let path = target ?? "/r/\(token)/video.mkv"
        var text = "\(method) \(path) \(version)\r\n"
        for header in headers { text += header + "\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    private func parse(_ data: Data) -> RelayParseResult {
        return RelayRequestParser.parse(data, limits: .standard)
    }

    private func status(_ data: Data) -> Int? {
        if case .reject(let status) = parse(data) { return status }
        return nil
    }

    // MARK: Accepted

    func testAPlainRangedGetIsParsed() {
        let data = request(headers: ["Host: 192.168.1.5:50000", "Range: bytes=100-199"])
        guard case .request(let head, let consumed) = parse(data) else { return XCTFail("not parsed") }
        XCTAssertEqual(head.method, .get)
        XCTAssertEqual(head.token, token)
        XCTAssertEqual(head.leaf, "video.mkv")
        XCTAssertEqual(head.range, .single(.from(100, to: 199)))
        XCTAssertFalse(head.wantsDLNAFeatures)
        XCTAssertEqual(consumed, data.count)
    }

    func testBytesAfterTheHeadAreNotConsumed() {
        let head = request()
        guard case .request(_, let consumed) = parse(head + Data("EXTRA".utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(consumed, head.count)
    }

    func testHeadAndOptionsAndHttp10AreAccepted() {
        guard case .request(let head, _) = parse(request(method: "HEAD")) else { return XCTFail("HEAD") }
        XCTAssertEqual(head.method, .head)
        guard case .request(let options, _) = parse(request(method: "OPTIONS")) else { return XCTFail("OPTIONS") }
        XCTAssertEqual(options.method, .options)
        guard case .request = parse(request(version: "HTTP/1.0", headers: [])) else { return XCTFail("HTTP/1.0") }
    }

    func testTheDLNAFeaturesRequestIsRecognisedInAnyCase() {
        guard case .request(let head, _) = parse(request(headers: ["Host: x", "getcontentFeatures.dlna.org: 1"])) else { return XCTFail("not parsed") }
        XCTAssertTrue(head.wantsDLNAFeatures)
        guard case .request(let other, _) = parse(request(headers: ["Host: x", "getcontentFeatures.dlna.org: 0"])) else { return XCTFail("not parsed") }
        XCTAssertFalse(other.wantsDLNAFeatures)
    }

    func testContentLengthZeroAndExtraHeadersAreFine() {
        let headers = ["Host: x", "User-Agent: Chromecast", "Accept: */*", "Connection: keep-alive", "Content-Length: 0", "Icy-MetaData: 1"]
        guard case .request = parse(request(headers: headers)) else { return XCTFail("not parsed") }
    }

    func testOnlyTheFirstRangeHeaderCounts() {
        guard case .request(let head, _) = parse(request(headers: ["Range: bytes=0-9", "Range: bytes=50-"])) else { return XCTFail("not parsed") }
        XCTAssertEqual(head.range, .single(.from(0, to: 9)))
    }

    // MARK: Incomplete and oversized

    func testTheHeadIsIncompleteUntilTheBlankLineArrives() {
        let full = request(headers: ["Host: x", "Range: bytes=0-9"])
        for length in 0..<full.count {
            XCTAssertEqual(parse(full.prefix(length)), .needMoreData, "length \(length)")
        }
        guard case .request = parse(full) else { return XCTFail("the whole head was not parsed") }
    }

    func testAHeadWithoutTerminatorOverTheLimitIsRefused() {
        XCTAssertEqual(parse(Data(repeating: 0x41, count: 9000)), .reject(status: 431))
        XCTAssertEqual(parse(Data(repeating: 0x41, count: 8191)), .needMoreData)
    }

    func testATerminatedHeadOverTheLimitIsRefused() {
        let big = request(headers: ["X-Padding: " + String(repeating: "a", count: 9000)])
        XCTAssertEqual(status(big), 431)
    }

    func testTooManyHeadersAreRefused() {
        let many = (0..<49).map { "X-H\($0): 1" }
        XCTAssertEqual(status(request(headers: many)), 431)
        let fine = (0..<40).map { "X-H\($0): 1" }
        guard case .request = parse(request(headers: fine)) else { return XCTFail("40 headers should pass") }
    }

    // MARK: Refused

    func testAddressesOfTheWrongShapeAreAnswered404LikeAnUnknownToken() {
        let cases = [
            "/r/\(token)/video.mkv?a=1",
            "/r/\(token)/../video.mkv",
            "/r/\(token)/%2e%2e",
            "/r/\(token)//video.mkv",
            "/r/video.mkv",
            "/r/\(token)",
            "/x/\(token)/video.mkv",
            "/r/\(String(token.dropLast()))/video.mkv",
            "/r/\(token.uppercased())/video.mkv",
            "/r/\(token)/.hidden",
            "/r/\(token)/video.mkv/extra",
            "/r/\(token)/\(String(repeating: "a", count: 65))"
        ]
        for target in cases {
            XCTAssertEqual(status(request(target)), 404, target)
        }
    }

    func testATargetThatIsNotOriginFormIsABadRequest() {
        XCTAssertEqual(status(request("http://192.168.1.5/r/\(token)/video.mkv")), 400)
        XCTAssertEqual(status(request("*")), 400)
        XCTAssertEqual(status(request("/r/\(token)/vid eo.mkv")), 400)
        XCTAssertEqual(status(request("/r/\(token)/" + String(repeating: "a", count: 200))), 400)
    }

    func testOtherMethodsAreNotAllowed() {
        for method in ["POST", "PUT", "DELETE", "PATCH", "CONNECT", "TRACE"] {
            XCTAssertEqual(status(request(method: method)), 405, method)
        }
    }

    func testAMalformedMethodOrVersionIsRefused() {
        XCTAssertEqual(status(request(method: "get")), 400)
        XCTAssertEqual(status(request(version: "HTTP/2.0")), 505)
        XCTAssertEqual(status(request(version: "HTTP/0.9")), 505)
        XCTAssertEqual(status(request(version: "HTTX/1.1")), 400)
        XCTAssertEqual(status(request(version: "HTTP/x")), 400)
        XCTAssertEqual(status(Data("GET /r/x\r\n\r\n".utf8)), 400)
        XCTAssertEqual(status(Data("\r\n\r\n".utf8)), 400)
    }

    func testHeadersThatBreakTheFramingAreRefused() {
        XCTAssertEqual(status(request(headers: ["Host: a", "Host: b"])), 400)
        XCTAssertEqual(status(request(headers: ["Transfer-Encoding: chunked"])), 400)
        XCTAssertEqual(status(request(headers: ["Content-Length: 5"])), 400)
        XCTAssertEqual(status(request(headers: ["Content-Length: abc"])), 400)
        XCTAssertEqual(status(request(headers: ["Expect: 100-continue"])), 400)
        XCTAssertEqual(status(request(headers: ["Upgrade: websocket"])), 400)
        XCTAssertEqual(status(request(headers: ["Ho st: x"])), 400)
        XCTAssertEqual(status(request(headers: ["Host: x", " folded continuation"])), 400)
        XCTAssertEqual(status(request(headers: ["no colon here"])), 400)
        XCTAssertEqual(status(request(headers: [": empty name"])), 400)
    }

    func testControlAndNonAsciiBytesAreRefused() {
        XCTAssertEqual(status(request(headers: ["X-Test: a\u{0}b"])), 400)
        XCTAssertEqual(status(request(headers: ["X-Test: caf\u{E9}"])), 400)
        XCTAssertEqual(status(request(headers: ["X-Test: a\u{7}b"])), 400)
        XCTAssertEqual(status(Data("GET /r/\(token)/video.mkv HTTP/1.1\nHost: x\r\n\r\n".utf8)), 400)
        XCTAssertEqual(status(Data("GET /r/\(token)/video.mkv HTTP/1.1\r\nHost: x\rX: y\r\n\r\n".utf8)), 400)
    }
}

final class RelayRangeTests: XCTestCase {
    func testTheSupportedRangeForms() {
        XCTAssertEqual(RelayRangeHeader.parse(nil), .absent)
        XCTAssertEqual(RelayRangeHeader.parse("bytes=0-99"), .single(.from(0, to: 99)))
        XCTAssertEqual(RelayRangeHeader.parse("bytes=100-"), .single(.from(100, to: nil)))
        XCTAssertEqual(RelayRangeHeader.parse("bytes=-500"), .single(.suffix(500)))
        XCTAssertEqual(RelayRangeHeader.parse("  bytes=7-7  "), .single(.from(7, to: 7)))
    }

    func testEverythingElseIsIgnoredSoTheWholeBodyIsServed() {
        for value in ["bytes=5-2", "bytes=0-1,5-9", "items=0-1", "bytes=abc", "bytes=99999999999999999999-", "Bytes=0-",
                      "bytes=", "bytes=-", "bytes=--5", "bytes=1-2-3", "bytes=+1-2", "bytes=1 -2", ""] {
            XCTAssertEqual(RelayRangeHeader.parse(value), .ignored, value)
        }
    }

    func testResolvingAgainstTheTotalSize() {
        XCTAssertEqual(RelayByteRange.from(0, to: 99).resolve(total: 1000), 0...99)
        XCTAssertEqual(RelayByteRange.from(990, to: 5000).resolve(total: 1000), 990...999)
        XCTAssertEqual(RelayByteRange.from(100, to: nil).resolve(total: 1000), 100...999)
        XCTAssertEqual(RelayByteRange.from(999, to: 999).resolve(total: 1000), 999...999)
        XCTAssertEqual(RelayByteRange.suffix(500).resolve(total: 1000), 500...999)
        XCTAssertEqual(RelayByteRange.suffix(5000).resolve(total: 1000), 0...999)
    }

    func testRangesThatCannotBeSatisfied() {
        XCTAssertNil(RelayByteRange.from(1000, to: nil).resolve(total: 1000))
        XCTAssertNil(RelayByteRange.from(2000, to: 3000).resolve(total: 1000))
        XCTAssertNil(RelayByteRange.suffix(0).resolve(total: 1000))
        XCTAssertNil(RelayByteRange.from(0, to: nil).resolve(total: 0))
        XCTAssertNil(RelayByteRange.suffix(10).resolve(total: 0))
        XCTAssertNil(RelayByteRange.from(-1, to: 5).resolve(total: 1000))
    }
}

final class RelayResponseHeadTests: XCTestCase {
    private func text(_ head: RelayResponseHead) -> String {
        return String(decoding: head.serialized(), as: UTF8.self)
    }

    func testTheStatusLineAndHeadersAreSerialised() {
        let head = RelayResponseHead(status: 206, headers: [RelayHeaderField("Content-Length", "5"), RelayHeaderField("Content-Type", "video/mp4")])
        XCTAssertEqual(text(head), "HTTP/1.1 206 Partial Content\r\nContent-Length: 5\r\nContent-Type: video/mp4\r\n\r\n")
    }

    func testAHeaderThatCouldInjectAnotherIsLeftOut() {
        let head = RelayResponseHead(status: 200, headers: [
            RelayHeaderField("X", "a\r\nSet-Cookie: b"),
            RelayHeaderField("Y", "a\nb"),
            RelayHeaderField("Z", "a\u{0}b"),
            RelayHeaderField("Bad Name", "v"),
            RelayHeaderField("Bad:Name", "v"),
            RelayHeaderField("", "v"),
            RelayHeaderField("Fine", "yes")
        ])
        XCTAssertEqual(text(head), "HTTP/1.1 200 OK\r\nFine: yes\r\n\r\n")
        XCTAssertFalse(text(head).replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testMimeTypesByLeafName() {
        XCTAssertEqual(RelayMime.forFileName("video.mkv"), "video/x-matroska")
        XCTAssertEqual(RelayMime.forFileName("video.MP4"), "video/mp4")
        XCTAssertEqual(RelayMime.forFileName("video.m4v"), "video/mp4")
        XCTAssertEqual(RelayMime.forFileName("video.avi"), "video/x-msvideo")
        XCTAssertEqual(RelayMime.forFileName("video.ts"), "video/mp2t")
        XCTAssertNil(RelayMime.forFileName("video"))
        XCTAssertNil(RelayMime.forFileName("video.exe"))
        XCTAssertTrue(RelayMime.allowedExtensions.contains("mkv"))
        XCTAssertFalse(RelayMime.allowedExtensions.contains("html"))
    }
}
