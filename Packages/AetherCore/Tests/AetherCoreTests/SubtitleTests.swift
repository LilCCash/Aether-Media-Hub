import XCTest
@testable import AetherCore

// MARK: - Test doubles

/// The Mersenne Twister Python's `random` module uses, seeded the way `random.seed(<int>)` does (`init_by_array([seed])`),
/// so the byte streams of `random.getrandbits(8)` used by the reference files of `opensubtitles/oshash` can be rebuilt here.
fileprivate struct PythonMersenneTwister {
    private var state = [UInt32](repeating: 0, count: 624)
    private var index = 624

    init(seed: UInt32) {
        initGenrand(19_650_218)
        let key: [UInt32] = [seed]
        var i = 1
        var j = 0
        var k = max(624, key.count)
        while k > 0 {
            let previous = state[i - 1]
            let spread = previous ^ (previous >> 30)
            let mixed = spread &* 1_664_525
            let combined = state[i] ^ mixed
            state[i] = combined &+ key[j] &+ UInt32(j)
            i += 1
            j += 1
            if i >= 624 {
                state[0] = state[623]
                i = 1
            }
            if j >= key.count { j = 0 }
            k -= 1
        }
        k = 623
        while k > 0 {
            let previous = state[i - 1]
            let spread = previous ^ (previous >> 30)
            let mixed = spread &* 1_566_083_941
            let combined = state[i] ^ mixed
            state[i] = combined &- UInt32(i)
            i += 1
            if i >= 624 {
                state[0] = state[623]
                i = 1
            }
            k -= 1
        }
        state[0] = 0x8000_0000
        index = 624
    }

    private mutating func initGenrand(_ seed: UInt32) {
        state[0] = seed
        for i in 1..<624 {
            let previous = state[i - 1]
            let mixed = previous ^ (previous >> 30)
            state[i] = 1_812_433_253 &* mixed &+ UInt32(i)
        }
    }

    private mutating func twist() {
        for i in 0..<624 {
            let upper = state[i] & 0x8000_0000
            let lower = state[(i + 1) % 624] & 0x7FFF_FFFF
            let y = upper | lower
            var value = state[(i + 397) % 624] ^ (y >> 1)
            if y & 1 != 0 { value ^= 0x9908_B0DF }
            state[i] = value
        }
        index = 0
    }

    private mutating func next32() -> UInt32 {
        if index >= 624 { twist() }
        var y = state[index]
        index += 1
        y ^= y >> 11
        let shiftedSeven: UInt32 = y << 7
        y ^= shiftedSeven & 0x9D2C_5680
        let shiftedFifteen: UInt32 = y << 15
        y ^= shiftedFifteen & 0xEFC6_0000
        y ^= y >> 18
        return y
    }

    /// `random.getrandbits(8)`: the top 8 bits of the next 32-bit output.
    mutating func nextByte() -> UInt8 {
        return UInt8(truncatingIfNeeded: next32() >> 24)
    }
}

fileprivate struct ProbeTransportFailure: Error {}

/// A virtual file of `size` bytes (the byte at offset `n` is `(n * 7 + 3) & 0xFF`, so a 4 GiB file costs nothing) served
/// with the semantics of an HTTP server that honours `Range`, plus the misbehaviours the probe must survive.
/// Like the real client it refuses bodies larger than `HTTPRequest.maxBytes`.
fileprivate final class RangeFileServer: HTTPClient, @unchecked Sendable {
    enum Behaviour {
        case honourRange
        /// `200` with the whole file.
        case ignoreRange
        /// `206` without `Content-Range`.
        case withoutContentRange
        /// `Content-Range: bytes a-b/*`.
        case unknownTotal
        /// `Content-Encoding: gzip` on the `206`.
        case compressed
        /// `206` whose body is 10 bytes shorter than the range it announces.
        case shortBody
        /// `206` for a range that starts 8 bytes after the requested one.
        case wrongOffset
        /// From the second request on, `Content-Range` reports one more byte.
        case totalGrows
        /// Any status with an empty body.
        case status(Int)
        /// The transport fails.
        case failure(Error)
    }

    let size: Int64
    let behaviour: Behaviour
    private let lock = NSLock()
    private var log: [HTTPRequest] = []

    init(size: Int64, behaviour: Behaviour = .honourRange) {
        self.size = size
        self.behaviour = behaviour
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    static func byte(at offset: Int64) -> UInt8 {
        return UInt8(truncatingIfNeeded: offset &* 7 &+ 3)
    }

    static func bytes(from first: Int64, count: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        for position in 0..<count {
            buffer[position] = byte(at: first + Int64(position))
        }
        return Data(buffer)
    }

    static func parseRange(_ header: String?) -> (Int64, Int64)? {
        guard let header = header, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = Int64(parts[0]), let last = Int64(parts[1]) else { return nil }
        return (first, last)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        log.append(request)
        let callNumber = log.count
        lock.unlock()

        if case .failure(let error) = behaviour { throw error }
        if case .status(let code) = behaviour {
            return HTTPResponse(data: Data(), statusCode: code, headers: [:], url: request.url)
        }
        guard let (first, requestedLast) = RangeFileServer.parseRange(request.headers["Range"]) else {
            return try whole(request)
        }
        if case .ignoreRange = behaviour { return try whole(request) }
        if first >= size {
            return HTTPResponse(data: Data(), statusCode: 416, headers: ["content-range": "bytes */\(size)"], url: request.url)
        }

        let last = min(requestedLast, size - 1)
        var servedFirst = first
        if case .wrongOffset = behaviour { servedFirst = first + 8 }
        let count = Int(last - servedFirst + 1)
        var data = RangeFileServer.bytes(from: servedFirst, count: count)
        if case .shortBody = behaviour { data = Data(data.dropLast(10)) }

        var totalText = String(size)
        if case .unknownTotal = behaviour { totalText = "*" }
        if case .totalGrows = behaviour, callNumber >= 2 { totalText = String(size + 1) }

        var headers: [String: String] = ["accept-ranges": "bytes", "content-type": "video/x-matroska"]
        var announcesRange = true
        if case .withoutContentRange = behaviour { announcesRange = false }
        if announcesRange { headers["content-range"] = "bytes \(servedFirst)-\(last)/\(totalText)" }
        if case .compressed = behaviour { headers["content-encoding"] = "gzip" }
        return HTTPResponse(data: data, statusCode: 206, headers: headers, url: request.url)
    }

    private func whole(_ request: HTTPRequest) throws -> HTTPResponse {
        if size > Int64(request.maxBytes) { throw AddonError.responseTooLarge(limit: request.maxBytes) }
        return HTTPResponse(data: RangeFileServer.bytes(from: 0, count: Int(size)), statusCode: 200,
                            headers: ["content-length": String(size)], url: request.url)
    }
}

/// Builds `AddonSubtitle`s with unique URLs.
fileprivate func subtitleFixture(_ id: String, _ lang: String, label: String? = nil, url: String? = nil,
                              addon: String? = nil) -> AddonSubtitle {
    return AddonSubtitle(id: id, url: url ?? "https://subs.test/\(id).srt", lang: lang, label: label, addonName: addon)
}

// MARK: - Hash

final class OpenSubtitlesHashTests: XCTestCase {
    private func filled(_ count: Int, _ byte: (Int) -> UInt8) -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        for position in 0..<count {
            buffer[position] = byte(position)
        }
        return Data(buffer)
    }

    func testSyntheticVectorsFromTheResearchNotes() {
        XCTAssertEqual(OpenSubtitlesHash.compute(data: Data(count: 131_072)), "0000000000020000",
                       "all zero: the hash is the size, padded to 16 digits")
        let ramp = filled(131_072) { UInt8(truncatingIfNeeded: $0) }
        XCTAssertEqual(OpenSubtitlesHash.compute(data: ramp), "a0601fdf9f610000")
        let affine = filled(200_000) { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        XCTAssertEqual(OpenSubtitlesHash.compute(data: affine), "60a0df1f5fa2cd40")
        XCTAssertEqual(OpenSubtitlesHash.compute(data: Data(repeating: 0xFF, count: 131_072)), "000000000001c000",
                       "64-bit wrap-around")
        let withGap = filled(131_080) { UInt8(truncatingIfNeeded: $0) }
        XCTAssertEqual(OpenSubtitlesHash.compute(data: withGap), "a0601fdf9f610008",
                       "same sum as the 131072 case plus the 8 bytes of size; the 8 middle bytes are not read")
    }

    func testOnlyTheTwoWindowsInfluenceTheHash() {
        let affine = filled(200_000) { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        var middleEdited = affine
        middleEdited[100_000] ^= 0xFF
        XCTAssertEqual(OpenSubtitlesHash.compute(data: middleEdited), "60a0df1f5fa2cd40", "a byte between the windows is ignored")
        var headEdited = affine
        headEdited[10] ^= 0xFF
        XCTAssertNotEqual(OpenSubtitlesHash.compute(data: headEdited), "60a0df1f5fa2cd40")
        var tailEdited = affine
        tailEdited[199_999] ^= 0x01
        XCTAssertNotEqual(OpenSubtitlesHash.compute(data: tailEdited), "60a0df1f5fa2cd40")
    }

    func testDeclaredSizesAbove4GiBAndAboveInt64() {
        let affine = filled(200_000) { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        let head = affine.prefix(65_536)
        let tail = affine.suffix(65_536)
        XCTAssertEqual(OpenSubtitlesHash.compute(size: 4_295_033_890, head: head, tail: tail), "60a0df205fa0c422")
        let zeros = Data(count: 65_536)
        XCTAssertEqual(OpenSubtitlesHash.compute(size: 9_223_372_036_854_775_813, head: zeros, tail: zeros), "8000000000000005",
                       "sizes above Int64.max are legal input of the algorithm")
    }

    func testReferenceFilesOfTheOpenSubtitlesSuite() {
        // test-data/testfile.bin: 1 MiB from random.seed(42) / getrandbits(8).
        var big = PythonMersenneTwister(seed: 42)
        var bigBytes = [UInt8](repeating: 0, count: 1_048_576)
        for position in 0..<bigBytes.count {
            bigBytes[position] = big.nextByte()
        }
        XCTAssertEqual(OpenSubtitlesHash.compute(data: Data(bigBytes)), "e7e2e71e035b137f")

        // test-data/testfile_small.bin: 131080 bytes from random.seed(123): the windows are 8 bytes apart.
        var small = PythonMersenneTwister(seed: 123)
        var smallBytes = [UInt8](repeating: 0, count: 131_080)
        for position in 0..<smallBytes.count {
            smallBytes[position] = small.nextByte()
        }
        XCTAssertEqual(OpenSubtitlesHash.compute(data: Data(smallBytes)), "6e4ae67790577f76")

        // test-data/zerohash.bin: (i * 1103515245 + 12345) & 0xFF, first 64-bit word solved so the hash starts with 0000.
        // The low byte of that expression only depends on i mod 256: it is (109 * i + 57) & 0xFF.
        var zeroHash = filled(131_072) { UInt8(truncatingIfNeeded: $0 &* 109 &+ 57) }
        let solvedFirstWord: [UInt8] = [0x39, 0xA6, 0x13, 0x80, 0xED, 0x5A, 0x27, 0x55]
        for position in 0..<8 {
            zeroHash[position] = solvedFirstWord[position]
        }
        let hash = OpenSubtitlesHash.compute(data: zeroHash)
        XCTAssertEqual(hash, "00005f1fe0a14000", "leading zeros must be kept: 16 digits, always")
        XCTAssertEqual(hash?.count, 16)
    }

    func testNoHashBelowTheMinimumSizeOrWithWrongWindows() {
        XCTAssertNil(OpenSubtitlesHash.compute(data: Data()))
        XCTAssertNil(OpenSubtitlesHash.compute(data: Data(count: 131_071)))
        XCTAssertNotNil(OpenSubtitlesHash.compute(data: Data(count: 131_072)))
        let window = Data(count: 65_536)
        XCTAssertNil(OpenSubtitlesHash.compute(size: 131_071, head: window, tail: window))
        XCTAssertNil(OpenSubtitlesHash.compute(size: 200_000, head: Data(count: 65_535), tail: window))
        XCTAssertNil(OpenSubtitlesHash.compute(size: 200_000, head: window, tail: Data(count: 65_537)))
        XCTAssertNotNil(OpenSubtitlesHash.compute(size: 131_072, head: window, tail: window))
    }

    func testSlicesOfLargerBuffersAreHandled() {
        let affine = filled(200_000) { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        let expected = OpenSubtitlesHash.compute(data: affine)
        XCTAssertEqual(expected, "60a0df1f5fa2cd40")

        var padded = Data([1, 2, 3, 4, 5, 6, 7])
        padded.append(affine)
        let slice = padded.dropFirst(7)
        XCTAssertEqual(slice.startIndex, 7, "the slice does not start at index 0")
        XCTAssertEqual(OpenSubtitlesHash.compute(data: slice), expected)

        let head = padded.dropFirst(7).prefix(65_536)
        let tail = affine.suffix(65_536)
        XCTAssertEqual(head.startIndex, 7)
        XCTAssertEqual(tail.startIndex, 134_464)
        XCTAssertEqual(OpenSubtitlesHash.compute(size: 200_000, head: head, tail: tail), expected)
    }
}

// MARK: - Probe

final class SubtitleHashProbeTests: XCTestCase {
    private let fileURL = URL(string: "https://cdn.test/dl/Movie.2020.mkv")!

    private func makeProbe(_ server: RangeFileServer, allowLocal: Bool = false) -> SubtitleHashProbe {
        return SubtitleHashProbe(http: server, policy: testPolicy(allowLocal: allowLocal), timeout: 5)
    }

    func testHashesAFileWithTwoRangeRequests() async {
        let server = RangeFileServer(size: 200_000)
        let result = await makeProbe(server).probe(url: fileURL)
        XCTAssertEqual(result, .success(SubtitleHashResult(hash: "60a0df1f5fa2cd40", size: 200_000)))

        let requests = server.requests
        XCTAssertEqual(requests.map { $0.headers["Range"] ?? "" }, ["bytes=0-65535", "bytes=134464-199999"])
        XCTAssertTrue(requests.allSatisfy { $0.headers["Accept-Encoding"] == "identity" }, "no compression: it would shift the bytes")
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
        XCTAssertTrue(requests.allSatisfy { $0.maxBytes == 65_536 }, "a server that ignores Range must not be downloaded in full")
    }

    func testFilesAbove4GiBUseSixtyFourBitOffsets() async {
        let server = RangeFileServer(size: 4_295_033_890)
        let result = await makeProbe(server).probe(url: fileURL)
        XCTAssertEqual(result, .success(SubtitleHashResult(hash: "20609fe11f608422", size: 4_295_033_890)))
        XCTAssertEqual(server.requests.map { $0.headers["Range"] ?? "" }, ["bytes=0-65535", "bytes=4294968354-4295033889"])
    }

    func testSmallestHashableFilesAndTheGapBetweenWindows() async {
        let exact = RangeFileServer(size: 131_072)
        let exactResult = await makeProbe(exact).probe(url: fileURL)
        XCTAssertEqual(exactResult, .success(SubtitleHashResult(hash: "60a0df1f5fa1c000", size: 131_072)))
        XCTAssertEqual(exact.requests.map { $0.headers["Range"] ?? "" }, ["bytes=0-65535", "bytes=65536-131071"])

        let gap = RangeFileServer(size: 131_080)
        let gapResult = await makeProbe(gap).probe(url: fileURL)
        XCTAssertEqual(gapResult, .success(SubtitleHashResult(hash: "60a0df1f5fa1c008", size: 131_080)))
        XCTAssertEqual(gap.requests.map { $0.headers["Range"] ?? "" }, ["bytes=0-65535", "bytes=65544-131079"])
    }

    func testStreamHeadersAreForwardedButRangeAndEncodingAreOurs() async {
        let server = RangeFileServer(size: 200_000)
        let hints = StreamBehaviorHints(proxyRequestHeaders: ["Referer": "https://site.test/", "Range": "bytes=999-",
                                                              "accept-encoding": "gzip", "Accept": "application/json"])
        let stream = AddonStream(source: .url("https://cdn.test/dl/Movie.2020.mkv"), behaviorHints: hints)
        let result = await makeProbe(server).probe(stream: stream)
        XCTAssertEqual(result, .success(SubtitleHashResult(hash: "60a0df1f5fa2cd40", size: 200_000)))
        for request in server.requests {
            XCTAssertEqual(request.headers["Referer"], "https://site.test/")
            XCTAssertEqual(request.headers["Accept-Encoding"], "identity")
            XCTAssertEqual(request.headers["Accept"], "*/*")
            XCTAssertNil(request.headers["accept-encoding"], "the stream's own spelling must not survive")
            XCTAssertNotEqual(request.headers["Range"], "bytes=999-")
        }
    }

    func testHashAndSizeFromBehaviorHintsNeedNoNetwork() async {
        let server = RangeFileServer(size: 200_000)
        let hints = StreamBehaviorHints(videoHash: "8E245D9679D31E12", videoSize: 12_909_756, filename: "breakdance.avi")
        let stream = AddonStream(source: .url("https://cdn.test/dl/Movie.2020.mkv"), behaviorHints: hints)
        let result = await makeProbe(server).probe(stream: stream)
        XCTAssertEqual(result, .success(SubtitleHashResult(hash: "8e245d9679d31e12", size: 12_909_756)))
        XCTAssertTrue(server.requests.isEmpty)

        // Only the size is known: the hash still has to be computed.
        let partial = AddonStream(source: .url("https://cdn.test/dl/Movie.2020.mkv"),
                                  behaviorHints: StreamBehaviorHints(videoSize: 12_909_756))
        let partialResult = await makeProbe(server).probe(stream: partial)
        XCTAssertEqual(partialResult, .success(SubtitleHashResult(hash: "60a0df1f5fa2cd40", size: 200_000)))
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAServerThatIgnoresRangeIsGivenUpOnImmediately() async {
        // 200 with a 200000 byte body: the real client cuts the transfer (responseTooLarge), the probe must not retry.
        let big = RangeFileServer(size: 200_000, behaviour: .ignoreRange)
        let bigResult = await makeProbe(big).probe(url: fileURL)
        XCTAssertEqual(bigResult, .failure(.rangeUnsupported))
        XCTAssertEqual(big.requests.count, 1)

        // A small body that fits the cap is still a 200: not a ranged answer.
        let small = RangeFileServer(size: 40_000, behaviour: .ignoreRange)
        let smallResult = await makeProbe(small).probe(url: fileURL)
        XCTAssertEqual(smallResult, .failure(.rangeUnsupported))
        XCTAssertEqual(small.requests.count, 1)
    }

    func testRejectedRangesAndHTTPErrors() async {
        let cases: [(Int, SubtitleHashFailure)] = [
            (416, .notSatisfiable), (401, .httpStatus(401)), (403, .httpStatus(403)),
            (404, .httpStatus(404)), (429, .httpStatus(429)), (500, .httpStatus(500)), (200, .rangeUnsupported)
        ]
        for (status, expected) in cases {
            let server = RangeFileServer(size: 200_000, behaviour: .status(status))
            let result = await makeProbe(server).probe(url: fileURL)
            XCTAssertEqual(result, .failure(expected), "status \(status)")
            XCTAssertEqual(server.requests.count, 1, "no second request after a refusal (\(status))")
        }
    }

    func testFilesTooSmallForAHash() async {
        let medium = RangeFileServer(size: 100_000)
        let mediumResult = await makeProbe(medium).probe(url: fileURL)
        XCTAssertEqual(mediumResult, .failure(.tooSmall(size: 100_000)))
        XCTAssertEqual(medium.requests.count, 1)

        let tiny = RangeFileServer(size: 1_000)
        let tinyResult = await makeProbe(tiny).probe(url: fileURL)
        XCTAssertEqual(tinyResult, .failure(.tooSmall(size: 1_000)))

        let almost = RangeFileServer(size: 131_071)
        let almostResult = await makeProbe(almost).probe(url: fileURL)
        XCTAssertEqual(almostResult, .failure(.tooSmall(size: 131_071)))
    }

    func testInconsistentAnswersAreRejected() async {
        let missing = RangeFileServer(size: 200_000, behaviour: .withoutContentRange)
        let missingResult = await makeProbe(missing).probe(url: fileURL)
        XCTAssertEqual(missingResult, .failure(.rangeUnsupported))

        let unknown = RangeFileServer(size: 200_000, behaviour: .unknownTotal)
        let unknownResult = await makeProbe(unknown).probe(url: fileURL)
        XCTAssertEqual(unknownResult, .failure(.unknownSize))

        let compressed = RangeFileServer(size: 200_000, behaviour: .compressed)
        let compressedResult = await makeProbe(compressed).probe(url: fileURL)
        XCTAssertEqual(compressedResult, .failure(.rangeUnsupported))

        let short = RangeFileServer(size: 200_000, behaviour: .shortBody)
        let shortResult = await makeProbe(short).probe(url: fileURL)
        XCTAssertEqual(shortResult, .failure(.truncated(expected: 65_536, received: 65_526)))

        let shifted = RangeFileServer(size: 200_000, behaviour: .wrongOffset)
        let shiftedResult = await makeProbe(shifted).probe(url: fileURL)
        XCTAssertEqual(shiftedResult, .failure(.rangeUnsupported))

        let growing = RangeFileServer(size: 200_000, behaviour: .totalGrows)
        let growingResult = await makeProbe(growing).probe(url: fileURL)
        XCTAssertEqual(growingResult, .failure(.changedWhileReading))
        XCTAssertEqual(growing.requests.count, 2)
    }

    func testTransportFailuresAreMappedAndCancellationIsRespected() async {
        let timeout = RangeFileServer(size: 200_000, behaviour: .failure(AddonError.timeout))
        let timeoutResult = await makeProbe(timeout).probe(url: fileURL)
        XCTAssertEqual(timeoutResult, .failure(.network(.timeout)))

        let blocked = RangeFileServer(size: 200_000, behaviour: .failure(AddonError.blockedURL(.loopback)))
        let blockedResult = await makeProbe(blocked).probe(url: fileURL)
        XCTAssertEqual(blockedResult, .failure(.network(.blockedURL(.loopback))))

        let cancelled = RangeFileServer(size: 200_000, behaviour: .failure(CancellationError()))
        let cancelledResult = await makeProbe(cancelled).probe(url: fileURL)
        XCTAssertEqual(cancelledResult, .failure(.cancelled))

        let other = RangeFileServer(size: 200_000, behaviour: .failure(ProbeTransportFailure()))
        let otherResult = await makeProbe(other).probe(url: fileURL)
        XCTAssertEqual(otherResult, .failure(.network(.unreachable("cdn.test"))))
    }

    func testACancelledTaskDoesNotTouchTheNetwork() async {
        let server = RangeFileServer(size: 200_000)
        let probe = makeProbe(server)
        let url = fileURL
        let task = Task { () -> Result<SubtitleHashResult, SubtitleHashFailure> in
            while !Task.isCancelled {
                await Task.yield()
            }
            return await probe.probe(url: url)
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testPlaylistsAndSourcesWithoutASingleFileNeverTouchTheNetwork() async {
        let server = RangeFileServer(size: 200_000)
        let probe = makeProbe(server)
        let adaptive = [
            "https://cdn.test/live/master.m3u8?token=1",
            "https://cdn.test/vod/manifest.mpd",
            "https://cdn.test/vod/movie.ism/manifest",
            "https://cdn.test/proxy?u=https%3A%2F%2Fother.test%2Fa.m3u8"
        ]
        for raw in adaptive {
            let result = await probe.probe(url: URL(string: raw)!)
            XCTAssertEqual(result, .failure(.adaptiveStream), raw)
        }

        let sources: [StreamSource] = [
            .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: nil, trackers: []),
            .youtube("dQw4w9WgXcQ"), .external("https://page.test/watch"), .playerFrame("https://page.test/frame"),
            .archive(kind: "rar"), .unknown
        ]
        for source in sources {
            let result = await probe.probe(stream: AddonStream(source: source))
            XCTAssertEqual(result, .failure(.notAFile), "\(source)")
        }
        let notAURL = await probe.probe(url: URL(string: "ftp://cdn.test/file.mkv")!)
        XCTAssertEqual(notAURL, .failure(.invalidURL))
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testPlainHTTPToPublicHostsIsSkippedButLocalNetworkIsProbed() async {
        let server = RangeFileServer(size: 200_000)
        let probe = makeProbe(server, allowLocal: true)

        let publicHost = await probe.probe(url: URL(string: "http://cdn.test/file.mkv")!)
        XCTAssertEqual(publicHost, .failure(.insecureTransport), "ATS would block a URLSession data task to a public http host")
        let publicIP = await probe.probe(url: URL(string: "http://93.184.216.34/file.mkv")!)
        XCTAssertEqual(publicIP, .failure(.insecureTransport))
        XCTAssertTrue(server.requests.isEmpty)

        let expected = SubtitleHashResult(hash: "60a0df1f5fa2cd40", size: 200_000)
        let lanAddress = await probe.probe(url: URL(string: "http://192.168.1.20:8080/file.mkv")!)
        XCTAssertEqual(lanAddress, .success(expected))
        let lanName = await probe.probe(url: URL(string: "http://nas.local/movies/file.mkv")!)
        XCTAssertEqual(lanName, .success(expected))
        let secure = await probe.probe(url: URL(string: "https://cdn.test/file.mkv")!)
        XCTAssertEqual(secure, .success(expected))
        XCTAssertEqual(server.requests.count, 6)
    }

    func testContentRangeParsing() {
        XCTAssertEqual(SubtitleHashProbe.parseContentRange("bytes 0-65535/12909756"),
                       SubtitleHashProbe.ContentRange(first: 0, last: 65_535, total: 12_909_756))
        XCTAssertEqual(SubtitleHashProbe.parseContentRange("bytes 0-65535/*"),
                       SubtitleHashProbe.ContentRange(first: 0, last: 65_535, total: nil))
        XCTAssertEqual(SubtitleHashProbe.parseContentRange("  BYTES 5-9/100 "),
                       SubtitleHashProbe.ContentRange(first: 5, last: 9, total: 100))
        XCTAssertEqual(SubtitleHashProbe.parseContentRange("bytes=0-9/100"),
                       SubtitleHashProbe.ContentRange(first: 0, last: 9, total: 100), "tolerated")
        for invalid in ["bytes */1234", "bytes 10-5/100", "bytes 0-9/9", "items 0-9/10", "bytes 0-9", "bytes a-b/c", ""] {
            XCTAssertNil(SubtitleHashProbe.parseContentRange(invalid), invalid)
        }
    }

    func testFailureMessagesAreItalianAndNeverEmpty() {
        let failures: [SubtitleHashFailure] = [
            .notAFile, .adaptiveStream, .insecureTransport, .invalidURL, .rangeUnsupported, .unknownSize, .notSatisfiable,
            .tooSmall(size: 10), .truncated(expected: 2, received: 1), .changedWhileReading, .httpStatus(500),
            .network(.offline), .cancelled
        ]
        for failure in failures {
            XCTAssertFalse(failure.message.isEmpty, "\(failure)")
        }
        XCTAssertEqual(SubtitleHashFailure.network(.timeout).message, AddonError.timeout.message)
    }
}

// MARK: - Request parameters

final class SubtitleVideoParamsTests: XCTestCase {
    func testFilenameFromURLDropsQueryAndFragmentAndDecodesPercentEscapes() {
        let cases: [(String, String?)] = [
            ("https://cdn.test/dl/The%20Matrix%201999.mkv?token=abc&x=1", "The Matrix 1999.mkv"),
            ("https://cdn.test/a/b/Movie.Name.2020.1080p.mkv#t=10", "Movie.Name.2020.1080p.mkv"),
            ("https://cdn.test/a/Movie.mkv?next=/other/Wrong.mkv", "Movie.mkv"),
            ("https://cdn.test/dir/Caf%C3%A9.2020.mp4", "Café.2020.mp4"),
            ("https://cdn.test/My Movie.mkv", "My Movie.mkv"),
            ("https://cdn.test/100%.mkv", "100%.mkv"),
            ("https://cdn.test/dl/a%2Fb.mkv", "b.mkv"),
            ("https://cdn.test/hls/index.m3u8?x=1", nil),
            ("https://cdn.test/dash/manifest.mpd", nil),
            ("https://cdn.test/stream/abcdef", nil),
            ("https://cdn.test/", nil),
            ("https://cdn.test", nil),
            ("https://cdn.test/12345.67", nil),
            ("", nil)
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(SubtitleVideoParams.derivedFilename(fromURL: raw), expected, raw)
        }
    }

    func testBehaviorHintsWinOverLocalValues() {
        let hints = StreamBehaviorHints(videoHash: "8E245D9679D31E12", videoSize: 12_909_756, filename: " Breakdance.avi ")
        let stream = AddonStream(source: .url("https://cdn.test/dl/Other.Name.mkv?token=1"), behaviorHints: hints)
        let local = SubtitleHashResult(hash: "0123456789abcdef", size: 42)
        let params = SubtitleVideoParams.resolve(stream: stream, local: local, filename: "Caller.mkv")
        XCTAssertEqual(params, SubtitleVideoParams(hash: "8e245d9679d31e12", size: 12_909_756, filename: "Breakdance.avi"))
    }

    func testLocalPairIsUsedWhenTheHintsAreIncomplete() {
        let url = "https://cdn.test/files/The%20Matrix%201999.mkv?token=abc"
        let local = SubtitleHashResult(hash: "60A0DF1F5FA2CD40", size: 200_000)

        let plainStream = AddonStream(source: .url(url))
        XCTAssertEqual(SubtitleVideoParams.resolve(stream: plainStream, local: local),
                       SubtitleVideoParams(hash: "60a0df1f5fa2cd40", size: 200_000, filename: "The Matrix 1999.mkv"))

        // A size without a hash must not be mixed with a locally computed hash: the pair describes the same bytes.
        let sizeOnly = AddonStream(source: .url(url), behaviorHints: StreamBehaviorHints(videoSize: 999))
        XCTAssertEqual(SubtitleVideoParams.resolve(stream: sizeOnly, local: local).size, 200_000)

        // Without a local result, a single hint value is passed on as it is.
        XCTAssertEqual(SubtitleVideoParams.resolve(stream: sizeOnly).size, 999)
        XCTAssertNil(SubtitleVideoParams.resolve(stream: sizeOnly).hash)
        let hashOnly = AddonStream(source: .url(url), behaviorHints: StreamBehaviorHints(videoHash: "8e245d9679d31e12"))
        XCTAssertEqual(SubtitleVideoParams.resolve(stream: hashOnly).hash, "8e245d9679d31e12")
        XCTAssertNil(SubtitleVideoParams.resolve(stream: hashOnly).size)
    }

    func testFilenamePrecedenceAndSourcesWithoutAFileName() {
        let torrent = AddonStream(source: .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: 1, trackers: []))
        XCTAssertNil(SubtitleVideoParams.resolve(stream: torrent).filename)
        XCTAssertEqual(SubtitleVideoParams.resolve(stream: torrent, filename: "Show.S01E02.mkv").filename, "Show.S01E02.mkv")

        let hls = AddonStream(source: .url("https://cdn.test/hls/index.m3u8"))
        XCTAssertNil(SubtitleVideoParams.resolve(stream: hls).filename, "a playlist name says nothing about the release")

        let named = AddonStream(source: .url("https://cdn.test/hls/index.m3u8"),
                                behaviorHints: StreamBehaviorHints(filename: "Real.Name.2020.mkv"))
        XCTAssertEqual(SubtitleVideoParams.resolve(stream: named, filename: "Caller.mkv").filename, "Real.Name.2020.mkv")

        XCTAssertTrue(SubtitleVideoParams.resolve(stream: nil).isEmpty)
        XCTAssertNil(SubtitleVideoParams.resolve(stream: nil, filename: "  ").filename, "blank names are dropped")
        XCTAssertEqual(SubtitleVideoParams.resolve(stream: nil, filename: "dir/Name.mkv").filename, "Name.mkv")
    }

    func testExtrasAreInTheOrderStremioClientsUse() {
        let params = SubtitleVideoParams(hash: "8e245d9679d31e12", size: 12_909_756, filename: "a b.mkv")
        XCTAssertEqual(params.extras.map { $0.name }, ["videoHash", "videoSize", "filename"])
        XCTAssertEqual(params.extras.map { $0.value }, ["8e245d9679d31e12", "12909756", "a b.mkv"])
        XCTAssertTrue(SubtitleVideoParams().extras.isEmpty)
    }
}

// MARK: - Languages

final class LanguageCodesTests: XCTestCase {
    func testAllIso6391CodesAreKnownAndNamedInItalian() {
        let codes = ("aa ab ae af ak am an ar as av ay az ba be bg bi bm bn bo br bs ca ce ch co cr cs cu cv cy da de dv dz ee el en eo es et eu "
            + "fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy hz ia id ie ig ii ik io is it iu ja jv ka kg ki kj kk kl km kn ko "
            + "kr ks ku kv kw ky la lb lg li ln lo lt lu lv mg mh mi mk ml mn mr ms mt my na nb nd ne ng nl nn no nr nv ny oc oj om or os pa pi "
            + "pl ps pt qu rm rn ro ru rw sa sc sd se sg si sk sl sm sn so sq sr ss st su sv sw ta te tg th ti tk tl tn to tr ts tt tw ty ug uk "
            + "ur uz ve vi vo wa wo xh yi yo za zh zu").split(separator: " ").map { String($0) }
        XCTAssertEqual(codes.count, 183)
        for code in codes {
            XCTAssertEqual(LanguageCodes.normalise(code), code, code)
            XCTAssertEqual(LanguageCodes.normalise(code.uppercased()), code, code)
            XCTAssertNotEqual(LanguageCodes.displayName(code), code, "\(code) has an Italian name")
        }
    }

    func testBibliographicAndTerminologicCodesAgree() {
        let pairs: [(String, String, String)] = [
            ("tib", "bod", "bo"), ("cze", "ces", "cs"), ("wel", "cym", "cy"), ("ger", "deu", "de"), ("gre", "ell", "el"),
            ("baq", "eus", "eu"), ("per", "fas", "fa"), ("fre", "fra", "fr"), ("arm", "hye", "hy"), ("ice", "isl", "is"),
            ("geo", "kat", "ka"), ("mao", "mri", "mi"), ("mac", "mkd", "mk"), ("may", "msa", "ms"), ("bur", "mya", "my"),
            ("dut", "nld", "nl"), ("rum", "ron", "ro"), ("slo", "slk", "sk"), ("alb", "sqi", "sq"), ("chi", "zho", "zh")
        ]
        for (bibliographic, terminologic, alpha2) in pairs {
            XCTAssertEqual(LanguageCodes.normalise(bibliographic), alpha2, bibliographic)
            XCTAssertEqual(LanguageCodes.normalise(terminologic), alpha2, terminologic)
            XCTAssertTrue(LanguageCodes.matches(bibliographic, terminologic), "\(bibliographic) / \(terminologic)")
        }
    }

    func testCodesObservedFromTheRealAddon() {
        // docs/research/api-probe-2026-10-20.md: languages returned by opensubtitles-v3.strem.io.
        let observed: [(String, String)] = [
            ("eng", "en"), ("ell", "el"), ("pob", "pt-BR"), ("por", "pt"), ("spa", "es"), ("slv", "sl"), ("tur", "tr"),
            ("fre", "fr"), ("ron", "ro"), ("cze", "cs"), ("hrv", "hr"), ("heb", "he"), ("nor", "no"), ("dan", "da"),
            ("fin", "fi"), ("rus", "ru"), ("swe", "sv")
        ]
        for (raw, expected) in observed {
            XCTAssertEqual(LanguageCodes.normalise(raw), expected, raw)
        }
    }

    func testOpenSubtitlesAliases() {
        XCTAssertEqual(LanguageCodes.normalise("pob"), "pt-BR")
        XCTAssertEqual(LanguageCodes.normalise("POB"), "pt-BR")
        XCTAssertEqual(LanguageCodes.normalise("zht"), "zh-Hant")
        XCTAssertEqual(LanguageCodes.normalise("zhe"), "zh")
        XCTAssertEqual(LanguageCodes.normalise("spl"), "es-419")
        XCTAssertEqual(LanguageCodes.displayName("pob"), "Portoghese (Brasile)")
        XCTAssertEqual(LanguageCodes.displayName("por"), "Portoghese")
        XCTAssertEqual(LanguageCodes.displayName("zht"), "Cinese tradizionale")
        XCTAssertEqual(LanguageCodes.displayName("zhe"), "Cinese (bilingue)")
        XCTAssertEqual(LanguageCodes.displayName("zho"), "Cinese")
        XCTAssertEqual(LanguageCodes.displayName("spl"), "Spagnolo (America Latina)")
    }

    func testBCP47TagsKeepOnlyTheVariantsThatChangeWhatIsRead() {
        let cases: [(String, String)] = [
            ("en-US", "en"), ("en_GB", "en"), ("it_IT", "it"), ("eng-US", "en"),
            ("pt-BR", "pt-BR"), ("pt_br", "pt-BR"), ("PT-br", "pt-BR"), ("pt-PT", "pt-PT"), ("pt", "pt"), ("pt-AO", "pt"),
            ("zh-Hans-CN", "zh-Hans"), ("zh-CN", "zh-Hans"), ("zh-SG", "zh-Hans"), ("zh-Hant", "zh-Hant"), ("zh-TW", "zh-Hant"),
            ("zh-HK", "zh-Hant"), ("zh-Hant-TW", "zh-Hant"), ("zh", "zh"),
            ("es-419", "es-419"), ("es-MX", "es"), ("es-ES", "es"), ("sr-Latn-RS", "sr"), ("yue-Hant-HK", "yue"), ("nb-NO", "nb")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(LanguageCodes.normalise(raw), expected, raw)
        }
    }

    func testIsoThreeAndDeprecatedCodes() {
        let cases: [(String, String)] = [
            ("cmn", "zh"), ("arb", "ar"), ("nob", "nb"), ("nno", "nn"), ("nor", "no"), ("fil", "fil"), ("yue", "yue"), ("ast", "ast"),
            ("iw", "he"), ("in", "id"), ("ji", "yi"), ("jw", "jv"), ("mo", "ro"), ("scc", "sr"), ("scr", "hr"),
            ("pes", "fa"), ("zsm", "ms"), ("swh", "sw"), ("und", "und"), ("mul", "mul"), ("zxx", "zxx")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(LanguageCodes.normalise(raw), expected, raw)
        }
    }

    func testLanguageNamesInSeveralLanguages() {
        let cases: [(String, String)] = [
            ("Italian", "it"), ("italiano", "it"), ("  ITALIANO ", "it"), ("Inglese", "en"), ("English", "en"),
            ("Español", "es"), ("ESPAÑOL", "es"), ("Spanish", "es"), ("Deutsch", "de"), ("Français", "fr"), ("Português", "pt"),
            ("Português Brazil", "pt-BR"), ("Português (Brasil)", "pt-BR"), ("Brazilian Portuguese", "pt-BR"),
            ("Čeština", "cs"), ("Türkçe", "tr"), ("日本語", "ja"), ("한국어", "ko"), ("中文", "zh"), ("Ελληνικά", "el"),
            ("русский", "ru"), ("Traditional Chinese", "zh-Hant")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(LanguageCodes.normalise(raw), expected, raw)
        }
    }

    func testUnknownTextIsKeptAsIs() {
        XCTAssertEqual(LanguageCodes.normalise("xx"), "xx")
        XCTAssertEqual(LanguageCodes.normalise("  Dothraki "), "dothraki")
        XCTAssertEqual(LanguageCodes.normalise("Dothraki (ceremonial)"), "dothraki (ceremonial)")
        XCTAssertEqual(LanguageCodes.normalise(""), "")
        XCTAssertEqual(LanguageCodes.displayName("  Dothraki "), "Dothraki", "unknown text is shown as the addon wrote it")
        XCTAssertEqual(LanguageCodes.displayName("xx"), "xx")
        XCTAssertEqual(LanguageCodes.displayName(""), "Lingua non specificata")
        XCTAssertEqual(LanguageCodes.displayName("und"), "Lingua non specificata")
        XCTAssertEqual(LanguageCodes.baseLanguage("Dothraki"), "dothraki")
    }

    func testItalianDisplayNames() {
        let cases: [(String, String)] = [
            ("it", "Italiano"), ("ita", "Italiano"), ("eng", "Inglese"), ("fre", "Francese"), ("ger", "Tedesco"),
            ("spa", "Spagnolo"), ("pt-PT", "Portoghese (Portogallo)"), ("pt-BR", "Portoghese (Brasile)"),
            ("zh-Hans", "Cinese semplificato"), ("ell", "Greco"), ("heb", "Ebraico"), ("jpn", "Giapponese"),
            ("fil", "Filippino"), ("nob", "Norvegese bokmål"), ("nor", "Norvegese"), ("Italian", "Italiano")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(LanguageCodes.displayName(raw), expected, raw)
        }
    }

    func testBaseLanguageDropsTheVariant() {
        XCTAssertEqual(LanguageCodes.baseLanguage("pt-BR"), "pt")
        XCTAssertEqual(LanguageCodes.baseLanguage("pob"), "pt")
        XCTAssertEqual(LanguageCodes.baseLanguage("zh-Hant"), "zh")
        XCTAssertEqual(LanguageCodes.baseLanguage("es-419"), "es")
        XCTAssertEqual(LanguageCodes.baseLanguage("nob"), "nb")
        XCTAssertEqual(LanguageCodes.baseLanguage("xx"), "xx")
        XCTAssertEqual(LanguageCodes.baseLanguage("it-IT"), "it")
    }

    func testMatching() {
        XCTAssertTrue(LanguageCodes.matches("fre", "fr"))
        XCTAssertTrue(LanguageCodes.matches("ita", "Italian"))
        XCTAssertTrue(LanguageCodes.matches("it-IT", "ita"))
        XCTAssertTrue(LanguageCodes.matches("pob", "pt-BR"))
        XCTAssertTrue(LanguageCodes.matches("pob", "pt"), "a wish for Portuguese accepts Brazilian Portuguese")
        XCTAssertTrue(LanguageCodes.matches("pt", "pob"))
        XCTAssertTrue(LanguageCodes.matches("pob", "por"))
        XCTAssertFalse(LanguageCodes.matches("pt-BR", "pt-PT"), "two different variants are different")
        XCTAssertFalse(LanguageCodes.matches("pob", "pt-PT"))
        XCTAssertFalse(LanguageCodes.matches("zh-Hans", "zh-Hant"))
        XCTAssertTrue(LanguageCodes.matches("zhe", "zht"))
        XCTAssertTrue(LanguageCodes.matches("no", "nb"))
        XCTAssertTrue(LanguageCodes.matches("nb", "nn"))
        XCTAssertFalse(LanguageCodes.matches("it", "en"))
        XCTAssertFalse(LanguageCodes.matches("", ""))
        XCTAssertFalse(LanguageCodes.matches("", "it"))
        XCTAssertFalse(LanguageCodes.matches("it", "   "))
        XCTAssertTrue(LanguageCodes.matches("Dothraki", "dothraki"))
        XCTAssertFalse(LanguageCodes.matches("Dothraki", "it"))
        XCTAssertTrue(LanguageCodes.matches("und", "und"))
        XCTAssertFalse(LanguageCodes.matches("und", "it"))
    }

    func testMatchStrength() {
        XCTAssertEqual(LanguageCodes.matchStrength("ita", "it"), 2)
        XCTAssertEqual(LanguageCodes.matchStrength("pob", "pt-BR"), 2)
        XCTAssertEqual(LanguageCodes.matchStrength("pt", "pt-BR"), 1)
        XCTAssertEqual(LanguageCodes.matchStrength("pt-BR", "pt-PT"), 0)
        XCTAssertEqual(LanguageCodes.matchStrength("it", "en"), 0)
    }
}

// MARK: - Catalog

final class SubtitleCatalogTests: XCTestCase {
    func testDeduplicatesByURLKeepsTheFirstAndFillsItsGaps() {
        let first = subtitleFixture("a", "eng", url: "https://s.test/1.srt", addon: "Primo")
        let second = subtitleFixture("b", "eng", label: "English", url: "https://s.test/1.srt ", addon: "Secondo")
        let other = subtitleFixture("c", "eng", url: "https://s.test/2.srt")
        let candidates = SubtitleCatalog.candidates(from: [first, second, other])
        XCTAssertEqual(candidates.map { $0.url }, ["https://s.test/1.srt", "https://s.test/2.srt"])
        XCTAssertEqual(candidates.first?.subtitle.id, "a", "the first occurrence wins")
        XCTAssertEqual(candidates.first?.subtitle.label, "English", "a missing label is taken from the duplicate")
        XCTAssertEqual(candidates.first?.addonName, "Primo")
        XCTAssertEqual(candidates.first?.id, "https://s.test/1.srt")
    }

    func testEntriesWithoutAURLAreDropped() {
        let subtitles = [subtitleFixture("x", "eng", url: "   "), subtitleFixture("y", "ita")]
        XCTAssertEqual(SubtitleCatalog.candidates(from: subtitles).map { $0.subtitle.id }, ["y"])
        XCTAssertTrue(SubtitleCatalog.candidates(from: []).isEmpty)
    }

    func testLanguageIsNormalisedAndNamed() {
        let subtitles = [
            subtitleFixture("pob", "pob"), subtitleFixture("none", ""), subtitleFixture("text", "Dothraki"),
            subtitleFixture("zhe", "zhe"), subtitleFixture("fre", "fre")
        ]
        let byID = Dictionary(uniqueKeysWithValues: SubtitleCatalog.candidates(from: subtitles).map { ($0.subtitle.id, $0) })
        XCTAssertEqual(byID["pob"]?.language, "pt-BR")
        XCTAssertEqual(byID["pob"]?.languageName, "Portoghese (Brasile)")
        XCTAssertEqual(byID["none"]?.language, "und")
        XCTAssertEqual(byID["none"]?.languageName, "Lingua non specificata")
        XCTAssertEqual(byID["text"]?.language, "dothraki")
        XCTAssertEqual(byID["text"]?.languageName, "Dothraki")
        XCTAssertEqual(byID["zhe"]?.language, "zh")
        XCTAssertEqual(byID["zhe"]?.languageName, "Cinese (bilingue)")
        XCTAssertEqual(byID["fre"]?.language, "fr")
    }

    func testOrderingFollowsLanguageWishesThenKindThenLabelThenInputOrder() {
        let subtitles = [
            subtitleFixture("s1", "eng", addon: "A"),
            subtitleFixture("s2", "ita", addon: "A"),
            subtitleFixture("s3", "fre", addon: "A"),
            subtitleFixture("s4", "ita", label: "Italiano (forzati)", addon: "B"),
            subtitleFixture("s5", "ita", label: "Italiano SDH", addon: "B"),
            subtitleFixture("s6", "ita", label: "Italiano - Bluray", addon: "B"),
            subtitleFixture("s7", "deu", addon: "B"),
            subtitleFixture("s8", "eng", label: "English", url: "https://subs.test/s1.srt", addon: "B")
        ]
        let preferences = SubtitlePreferences(languages: ["ita", "eng"])
        let candidates = SubtitleCatalog.candidates(from: subtitles, preferences: preferences)
        // Italian: plain with label (s6), plain (s2), hearing impaired (s5), forced (s4); English (s1, label filled from s8);
        // the rest by language name: Francese, Tedesco.
        XCTAssertEqual(candidates.map { $0.subtitle.id }, ["s6", "s2", "s5", "s4", "s1", "s3", "s7"])
        XCTAssertEqual(candidates[2].isHearingImpaired, true)
        XCTAssertEqual(candidates[3].isForced, true)

        let groups = SubtitleCatalog.groups(from: candidates)
        XCTAssertEqual(groups.map { $0.language }, ["it", "en", "fr", "de"])
        XCTAssertEqual(groups.map { $0.name }, ["Italiano", "Inglese", "Francese", "Tedesco"])
        XCTAssertEqual(groups[0].candidates.count, 4)
        XCTAssertEqual(groups[0].id, "it")
        XCTAssertEqual(SubtitleCatalog.availableLanguages(in: candidates), ["it", "en", "fr", "de"])
    }

    func testWithoutWishesLanguagesAreAlphabeticalByNameAndStable() {
        let subtitles = [subtitleFixture("t1", "ger"), subtitleFixture("t2", "eng"), subtitleFixture("t3", "ger"), subtitleFixture("t4", "ita")]
        let candidates = SubtitleCatalog.candidates(from: subtitles)
        // Inglese, Italiano, Tedesco: each language stays together and keeps the input order inside it.
        XCTAssertEqual(candidates.map { $0.subtitle.id }, ["t2", "t4", "t1", "t3"])
        XCTAssertEqual(SubtitleCatalog.availableLanguages(in: candidates), ["en", "it", "de"])
    }

    func testExactLanguageMatchesComeBeforeLooserOnes() {
        let subtitles = [
            subtitleFixture("por", "por"), subtitleFixture("pob", "pob"), subtitleFixture("ptpt", "pt-PT"),
            subtitleFixture("eng", "eng"), subtitleFixture("spa", "spa")
        ]
        let brazilian = SubtitleCatalog.candidates(from: subtitles, preferences: SubtitlePreferences(languages: ["pt-BR", "en"]))
        XCTAssertEqual(brazilian.map { $0.subtitle.id }, ["pob", "por", "eng", "ptpt", "spa"],
                       "pob is exact, por is Portuguese without variant, European Portuguese was not asked for")
        let generic = SubtitleCatalog.candidates(from: subtitles, preferences: SubtitlePreferences(languages: ["pt"]))
        XCTAssertEqual(generic.map { $0.subtitle.id }, ["por", "pob", "ptpt", "eng", "spa"])
    }

    func testHearingImpairedPreferenceReordersInsideALanguage() {
        let subtitles = [
            subtitleFixture("plain", "eng"), subtitleFixture("sdh", "eng", label: "English SDH"),
            subtitleFixture("forced", "eng", label: "English forced")
        ]
        let normal = SubtitleCatalog.candidates(from: subtitles, preferences: SubtitlePreferences(languages: ["en"]))
        XCTAssertEqual(normal.map { $0.subtitle.id }, ["plain", "sdh", "forced"])
        let accessible = SubtitleCatalog.candidates(from: subtitles,
                                                    preferences: SubtitlePreferences(languages: ["en"], preferHearingImpaired: true))
        XCTAssertEqual(accessible.map { $0.subtitle.id }, ["sdh", "plain", "forced"], "forced stays last")
    }

    func testHearingImpairedAndForcedHeuristics() {
        let cases: [(String?, String, Bool, Bool)] = [
            ("English SDH", "en", true, false),
            ("English [CC]", "en", true, false),
            ("Eng-Closed Captions", "en", true, false),
            ("Inglese (non udenti)", "en", true, false),
            ("English HI", "en", true, false),
            ("Hearing Impaired", "en", true, false),
            ("Hard of hearing", "en", true, false),
            ("Deaf and HoH", "en", true, false),
            ("English - Forced", "en", false, true),
            ("Italiano forzati", "it", false, true),
            ("Français (forcé)", "fr", false, true),
            ("Foreign parts only", "en", false, true),
            ("Signs & Songs", "en", false, true),
            ("Subtitles Forced SDH", "en", true, true),
            ("English", "en", false, false),
            ("Accented speech", "en", false, false),
            ("Hindi", "hi", false, false),
            ("Hindi HI", "hi", false, false),
            ("HI", "en", false, false),
            ("", "en", false, false),
            (nil, "en", false, false)
        ]
        for (label, language, expectedImpaired, expectedForced) in cases {
            let flags = SubtitleCatalog.flags(label: label, language: language)
            XCTAssertEqual(flags.hearingImpaired, expectedImpaired, "hearing impaired: \(label ?? "nil")")
            XCTAssertEqual(flags.forced, expectedForced, "forced: \(label ?? "nil")")
        }
    }

    func testPreferredSkipsForcedTracksAndNeedsAMatch() {
        let subtitles = [
            subtitleFixture("forced-it", "ita", label: "Italiano forzati"),
            subtitleFixture("en", "eng"),
            subtitleFixture("de", "deu")
        ]
        let italianThenEnglish = SubtitlePreferences(languages: ["it", "en"])
        let candidates = SubtitleCatalog.candidates(from: subtitles, preferences: italianThenEnglish)
        XCTAssertEqual(SubtitleCatalog.preferred(in: candidates, preferences: italianThenEnglish)?.subtitle.id, "en",
                       "forced-only Italian is not a translation: the next wish is used")
        XCTAssertNil(SubtitleCatalog.preferred(in: candidates, preferences: SubtitlePreferences(languages: ["it"])))
        XCTAssertNil(SubtitleCatalog.preferred(in: candidates, preferences: SubtitlePreferences(languages: ["ja"])))
        XCTAssertNil(SubtitleCatalog.preferred(in: candidates, preferences: SubtitlePreferences()), "no wish, no automatic choice")
        XCTAssertNil(SubtitleCatalog.preferred(in: [], preferences: italianThenEnglish))

        let full = [subtitleFixture("plain", "ita"), subtitleFixture("sdh", "ita", label: "Italiano SDH")]
        let all = SubtitleCatalog.candidates(from: full, preferences: SubtitlePreferences(languages: ["it"]))
        XCTAssertEqual(SubtitleCatalog.preferred(in: all, preferences: SubtitlePreferences(languages: ["it"]))?.subtitle.id, "plain")
        let accessible = SubtitlePreferences(languages: ["it"], preferHearingImpaired: true)
        XCTAssertEqual(SubtitleCatalog.preferred(in: all, preferences: accessible)?.subtitle.id, "sdh")
    }

    func testTitleAndDetailForTheMenu() {
        let withLabel = SubtitleCatalog.candidates(from: [subtitleFixture("a", "ita", label: "Director's cut", addon: "OpenSubtitles v3")])
        XCTAssertEqual(withLabel.first?.title, "Director's cut")
        XCTAssertEqual(withLabel.first?.detail, "Italiano · OpenSubtitles v3")

        let plain = SubtitleCatalog.candidates(from: [subtitleFixture("b", "ita", addon: "OpenSubtitles v3")])
        XCTAssertEqual(plain.first?.title, "Italiano")
        XCTAssertEqual(plain.first?.detail, "OpenSubtitles v3")

        let flagged = SubtitleCatalog.candidates(from: [subtitleFixture("c", "eng", label: "  English SDH ")])
        XCTAssertEqual(flagged.first?.title, "English SDH")
        XCTAssertEqual(flagged.first?.detail, "Inglese · Non udenti")

        let blankLabel = SubtitleCatalog.candidates(from: [subtitleFixture("d", "fre", label: "   ")])
        XCTAssertEqual(blankLabel.first?.title, "Francese")
        XCTAssertEqual(blankLabel.first?.detail, "")
    }

    func testEncodingHintFromTheURL() {
        XCTAssertEqual(SubtitleCatalog.encodingHint(forURL: "https://subs.test/file/1?senc=cp1250"), "cp1250")
        XCTAssertEqual(SubtitleCatalog.encodingHint(forURL: "https://subs.test/file/1?x=1&SENC=windows-1251#frag"), "windows-1251")
        XCTAssertEqual(SubtitleCatalog.encodingHint(forURL: "https://subs.test/file/1?senc=iso-8859%2D2"), "iso-8859-2")
        XCTAssertNil(SubtitleCatalog.encodingHint(forURL: "https://subs.test/file/1"))
        XCTAssertNil(SubtitleCatalog.encodingHint(forURL: "https://subs.test/file/1?senc="))
        XCTAssertNil(SubtitleCatalog.encodingHint(forURL: "https://subs.test/file/1?other=senc"))
        XCTAssertNil(SubtitleCatalog.encodingHint(forURL: "https://subs.test/file/1#senc=cp1250"))

        let candidates = SubtitleCatalog.candidates(from: [subtitleFixture("p", "pol", url: "https://subs.test/p.srt?senc=cp1250")])
        XCTAssertEqual(candidates.first?.encodingHint, "cp1250")
    }

    func testTheFixtureResponseGoesThroughDecoderAndCatalog() throws {
        let response = try ResponseDecoder.decode(Fixture.data("subtitles.json"), resource: "subtitles")
        guard case .subtitles(let list) = response.payload else { return XCTFail("expected subtitles") }
        let candidates = SubtitleCatalog.candidates(from: list, preferences: SubtitlePreferences(languages: ["it"]))
        XCTAssertEqual(candidates.map { $0.language }, ["it", "fr", "en"])
        XCTAssertEqual(candidates[0].title, "Italiano")
        XCTAssertEqual(candidates[2].title, "English [CC]")
        XCTAssertEqual(candidates[2].detail, "Inglese · Non udenti")
    }

    func testARealisticOpenSubtitlesPayload() throws {
        // Shape observed on opensubtitles-v3.strem.io (docs/research/api-probe-2026-10-20.md): extra fields are ignored.
        let json = """
        {"subtitles":[
          {"id":"30949","url":"https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/36919","SubEncoding":"CP1252",
           "lang":"eng","m":"i","g":"11","subtitleFileName":"a.srt","movieReleaseName":"b","releaseGroup":"aFLDp","releaseFormat":"HDTV",
           "fpsMilli":23980,"season":0,"episode":0},
          {"id":"2","url":"https://subs5.strem.io/pt/download/subencoding-stremio-utf8/src-api/file/2","lang":"pob"},
          {"id":"3","url":"https://subs5.strem.io/pt/download/subencoding-stremio-utf8/src-api/file/3","lang":"por"},
          {"id":"4","url":"https://subs5.strem.io/el/download/subencoding-stremio-utf8/src-api/file/4","lang":"ell"},
          {"id":"5","url":"https://subs5.strem.io/zh/download/subencoding-stremio-utf8/src-api/file/5","lang":"zht"},
          {"id":"6","url":"https://subs5.strem.io/cs/download/subencoding-stremio-utf8/src-api/file/6","lang":"cze"},
          {"id":"7","url":"https://other.test/cs/7.srt?senc=cp1250","lang":"cze"}
        ]}
        """
        let response = try ResponseDecoder.decode(Data(json.utf8), resource: "subtitles")
        guard case .subtitles(let list) = response.payload else { return XCTFail("expected subtitles") }
        XCTAssertEqual(list.count, 7)

        let preferences = SubtitlePreferences(languages: ["pt-BR", "en", "el"])
        let candidates = SubtitleCatalog.candidates(from: list, preferences: preferences)
        XCTAssertEqual(candidates.map { $0.subtitle.id }, ["2", "3", "30949", "4", "6", "7", "5"])
        let groups = SubtitleCatalog.groups(from: candidates)
        XCTAssertEqual(groups.map { $0.language }, ["pt-BR", "pt", "en", "el", "cs", "zh-Hant"])
        XCTAssertEqual(groups.map { $0.name }, ["Portoghese (Brasile)", "Portoghese", "Inglese", "Greco", "Ceco", "Cinese tradizionale"])
        XCTAssertNil(candidates.first(where: { $0.subtitle.id == "6" })?.encodingHint)
        XCTAssertEqual(candidates.first(where: { $0.subtitle.id == "7" })?.encodingHint, "cp1250")
        XCTAssertEqual(SubtitleCatalog.preferred(in: candidates, preferences: preferences)?.subtitle.id, "2")
    }
}

// MARK: - Parser encoding hint

final class SubtitleEncodingHintTests: XCTestCase {
    private func srt(_ text: String) -> String {
        return "1\n00:00:01,000 --> 00:00:02,000\n\(text)\n"
    }

    func testTheAnnouncedCharsetDecodesLegacyBytes() throws {
        let polish = "Zażółć gęślą jaźń"
        let data = try XCTUnwrap(srt(polish).data(using: .windowsCP1250))
        XCTAssertNil(String(data: data, encoding: .utf8), "the bytes are not UTF-8")

        XCTAssertEqual(try SubtitleParser.parse(data, encodingHint: "cp1250").first?.text, polish)
        XCTAssertEqual(try SubtitleParser.parse(data, encodingHint: "Windows-1250").first?.text, polish)
        XCTAssertNotEqual(try SubtitleParser.parse(data).first?.text, polish, "without a hint the default code page is Windows-1252")
        XCTAssertEqual(try SubtitleParser.parse(data, languageHint: "pol").first?.text, polish, "the language heuristic still works")
    }

    func testTheHintBeatsTheLanguageGuessAndUnknownHintsFallBack() throws {
        let russian = "Привет, мир"
        let data = try XCTUnwrap(srt(russian).data(using: .windowsCP1251))
        XCTAssertEqual(try SubtitleParser.parse(data, languageHint: "pol", encodingHint: "windows-1251").first?.text, russian)

        let polish = "Zażółć gęślą jaźń"
        let polishData = try XCTUnwrap(srt(polish).data(using: .windowsCP1250))
        XCTAssertEqual(try SubtitleParser.parse(polishData, languageHint: "pl", encodingHint: "not-a-charset").first?.text, polish)
    }

    func testValidUTF8IsNeverReinterpreted() throws {
        let text = "Zażółć gęślą jaźń"
        let data = Data(srt(text).utf8)
        XCTAssertEqual(try SubtitleParser.parse(data, encodingHint: "cp1251").first?.text, text,
                       "the official addon re-encodes to UTF-8 but keeps announcing the original charset")
        XCTAssertEqual(try SubtitleParser.parse(data, languageHint: "ita", encodingHint: "latin1").first?.text, text)
    }

    func testExistingBehaviourIsUnchangedWithoutAHint() throws {
        let data = try Fixture.data("sample_cp1252.srt")
        XCTAssertEqual(try SubtitleParser.parse(data, languageHint: "ita").first?.text, "È già così perché sì")
        XCTAssertEqual(SubtitleParser.decode(data, languageHint: "pt-BR"), SubtitleParser.decode(data, languageHint: "por"),
                       "a variant of the language hint selects the same code pages")
    }

    func testCharsetNames() {
        XCTAssertEqual(SubtitleParser.encoding(forCharset: "CP1250"), .windowsCP1250)
        XCTAssertEqual(SubtitleParser.encoding(forCharset: "windows_1251"), .windowsCP1251)
        XCTAssertEqual(SubtitleParser.encoding(forCharset: "Windows-1252"), .windowsCP1252)
        XCTAssertEqual(SubtitleParser.encoding(forCharset: " ISO-8859-2 "), .isoLatin2)
        XCTAssertEqual(SubtitleParser.encoding(forCharset: "latin1"), .isoLatin1)
        XCTAssertEqual(SubtitleParser.encoding(forCharset: "UTF-8"), .utf8)
        XCTAssertNil(SubtitleParser.encoding(forCharset: "klingon-8"))
        XCTAssertNil(SubtitleParser.encoding(forCharset: ""))
    }
}

// MARK: - AddonService

final class SubtitleServiceTests: XCTestCase {
    private let reply = "{\"subtitles\":[{\"id\":\"1\",\"url\":\"https://subs.test/1.srt\",\"lang\":\"eng\"}]}"

    private func manifestJSON(id: String, name: String, resources: String, idPrefixes: String?) -> String {
        var json = "{\"id\":\"\(id)\",\"version\":\"1.0.0\",\"name\":\"\(name)\",\"types\":[\"movie\",\"series\"],"
        json += "\"resources\":\(resources),\"catalogs\":[]"
        if let prefixes = idPrefixes { json += ",\"idPrefixes\":\(prefixes)" }
        return json + "}"
    }

    /// Installs an addon at `https://<host>/manifest.json`.
    private func install(_ env: TestEnvironment, host: String, name: String = "OpenSubtitles v3",
                         resources: String = "[\"subtitles\"]", idPrefixes: String? = "[\"tt\"]") async throws {
        let manifest = manifestJSON(id: "org.test.\(host)", name: name, resources: resources, idPrefixes: idPrefixes)
        env.server.set("https://\(host)/manifest.json", json: manifest)
        _ = try await env.registry.install(input: "https://\(host)/manifest.json")
    }

    private func subtitleRequests(_ env: TestEnvironment) -> [String] {
        return env.server.requests.map { $0.url.absoluteString }.filter { $0.contains("/subtitles/") }
    }

    func testStreamHintsAreSentBeforeAnyLocalValue() async throws {
        let env = try TestEnvironment()
        try await install(env, host: "os.test")
        let expected = "https://os.test/subtitles/movie/tt0111161/videoHash=8e245d9679d31e12&videoSize=12909756&filename=Breakdance.avi.json"
        env.server.set(expected, json: reply)

        let hints = StreamBehaviorHints(videoHash: "8E245D9679D31E12", videoSize: 12_909_756, filename: "Breakdance.avi")
        let stream = AddonStream(source: .url("https://cdn.test/other/Different.Name.mkv?token=1"), behaviorHints: hints)
        let local = SubtitleHashResult(hash: "0123456789abcdef", size: 42)
        let subtitles = await env.service.subtitles(type: "movie", videoID: "tt0111161", stream: stream, local: local)
        XCTAssertEqual(subtitles.map { $0.id }, ["1"], "the request with the stream's own values was the one that matched")
        XCTAssertEqual(subtitles.first?.addonName, "OpenSubtitles v3")
        XCTAssertEqual(subtitleRequests(env), [expected])
    }

    func testALocallyComputedHashIsUsedAndTheFilenameLosesItsQueryString() async throws {
        let env = try TestEnvironment()
        try await install(env, host: "os.test")
        let expected = "https://os.test/subtitles/movie/tt0133093/videoHash=60a0df1f5fa2cd40&videoSize=200000&filename=The%20Matrix%201999.mkv.json"
        env.server.set(expected, json: reply)

        let stream = AddonStream(source: .url("https://cdn.test/files/The%20Matrix%201999.mkv?token=abc&x=%2F"))
        let local = SubtitleHashResult(hash: "60a0df1f5fa2cd40", size: 200_000)
        let subtitles = await env.service.subtitles(type: "movie", videoID: "tt0133093", stream: stream, local: local)
        XCTAssertEqual(subtitles.map { $0.id }, ["1"])
        XCTAssertEqual(subtitleRequests(env), [expected])
    }

    func testWithoutAnyHashOnlyTheFilenameTravels() async throws {
        let env = try TestEnvironment()
        try await install(env, host: "os.test")
        let expected = "https://os.test/subtitles/movie/tt0133093/filename=The%20Matrix%201999.mkv.json"
        env.server.set(expected, json: reply)

        let stream = AddonStream(source: .url("https://cdn.test/files/The%20Matrix%201999.mkv?token=abc"))
        let subtitles = await env.service.subtitles(type: "movie", videoID: "tt0133093", stream: stream)
        XCTAssertEqual(subtitles.map { $0.id }, ["1"])
        XCTAssertEqual(subtitleRequests(env), [expected])

        let bare = await env.service.subtitles(type: "movie", videoID: "tt0133093", stream: nil)
        XCTAssertTrue(bare.isEmpty, "no params: the bare URL is requested (and is a 404 here)")
        XCTAssertTrue(subtitleRequests(env).contains("https://os.test/subtitles/movie/tt0133093.json"))
    }

    func testExplicitValuesAreStillSentAsGiven() async throws {
        let env = try TestEnvironment()
        try await install(env, host: "os.test")
        let expected = "https://os.test/subtitles/movie/tt0133093/videoHash=abc123&videoSize=1000&filename=Name%20With%20Spaces%20%26%20Symbols.mkv.json"
        env.server.set(expected, json: reply)
        let subtitles = await env.service.subtitles(type: "movie", videoID: "tt0133093", videoHash: "abc123", videoSize: 1000,
                                                    filename: "Name With Spaces & Symbols.mkv")
        XCTAssertEqual(subtitles.map { $0.id }, ["1"])
    }

    func testOnlyIdsTheAddonDeclaresAreSent() async throws {
        let env = try TestEnvironment()
        try await install(env, host: "os.test")
        try await install(env, host: "any.test", name: "Any Id", idPrefixes: nil)
        env.server.set("https://os.test/subtitles/series/kitsu%3A7442.json", json: reply)
        env.server.set("https://any.test/subtitles/series/kitsu%3A7442.json",
                       json: "{\"subtitles\":[{\"id\":\"k\",\"url\":\"https://subs.test/k.srt\",\"lang\":\"jpn\"}]}")

        let subtitles = await env.service.subtitles(type: "series", videoID: "kitsu:7442")
        XCTAssertEqual(subtitles.map { $0.id }, ["k"])
        XCTAssertEqual(subtitleRequests(env), ["https://any.test/subtitles/series/kitsu%3A7442.json"],
                       "OpenSubtitles declares the tt prefix: a kitsu id never reaches it")
    }

    func testResourceObjectsInheritTheManifestPrefixes() async throws {
        let env = try TestEnvironment()
        // `resources` is an object with `types` only: the manifest-level idPrefixes still apply.
        try await install(env, host: "inherit.test", name: "Inherit",
                          resources: "[{\"name\":\"subtitles\",\"types\":[\"movie\"]}]", idPrefixes: "[\"tt\"]")
        env.server.set("https://inherit.test/subtitles/movie/kitsu%3A1.json", json: reply)
        env.server.set("https://inherit.test/subtitles/movie/tt1.json", json: reply)

        let foreign = await env.service.subtitles(type: "movie", videoID: "kitsu:1")
        XCTAssertTrue(foreign.isEmpty)
        XCTAssertTrue(subtitleRequests(env).isEmpty)

        let imdb = await env.service.subtitles(type: "movie", videoID: "tt1")
        XCTAssertEqual(imdb.map { $0.id }, ["1"])
        XCTAssertEqual(subtitleRequests(env), ["https://inherit.test/subtitles/movie/tt1.json"])
    }

    func testPrefixesOfTheResourceReplaceTheManifestOnes() async throws {
        let env = try TestEnvironment()
        try await install(env, host: "own.test", name: "Own",
                          resources: "[{\"name\":\"subtitles\",\"types\":[\"movie\"],\"idPrefixes\":[\"yt_\"]}]", idPrefixes: "[\"tt\"]")
        env.server.set("https://own.test/subtitles/movie/yt_abc.json", json: reply)
        env.server.set("https://own.test/subtitles/movie/tt1.json", json: reply)

        let own = await env.service.subtitles(type: "movie", videoID: "yt_abc")
        XCTAssertEqual(own.map { $0.id }, ["1"])
        let other = await env.service.subtitles(type: "movie", videoID: "tt1")
        XCTAssertTrue(other.isEmpty)
        XCTAssertEqual(subtitleRequests(env), ["https://own.test/subtitles/movie/yt_abc.json"])
    }

    func testDeclaredPrefixRule() {
        func manifest(_ json: String) -> AddonManifest? {
            return try? ResponseDecoder.decodeManifest(Data(json.utf8))
        }
        guard let short = manifest(manifestJSON(id: "a", name: "A", resources: "[\"subtitles\"]", idPrefixes: "[\"tt\"]")),
              let noPrefix = manifest(manifestJSON(id: "b", name: "B", resources: "[\"subtitles\"]", idPrefixes: nil)),
              let emptyPrefix = manifest(manifestJSON(id: "c", name: "C", resources: "[\"subtitles\"]", idPrefixes: "[]")),
              let noSubtitles = manifest(manifestJSON(id: "d", name: "D", resources: "[\"stream\"]", idPrefixes: "[\"tt\"]")) else {
            return XCTFail("manifests should decode")
        }
        XCTAssertTrue(AddonService.declaresSubtitleID(short, id: "tt0111161"))
        XCTAssertFalse(AddonService.declaresSubtitleID(short, id: "kitsu:1"))
        XCTAssertTrue(AddonService.declaresSubtitleID(noPrefix, id: "anything"))
        XCTAssertTrue(AddonService.declaresSubtitleID(emptyPrefix, id: "anything"), "an empty list means every id")
        XCTAssertFalse(AddonService.declaresSubtitleID(noSubtitles, id: "tt0111161"), "no subtitles resource at all")
    }

    func testResultsFromSeveralAddonsAreMergedByURLInAddonOrder() async throws {
        let env = try TestEnvironment()
        try await install(env, host: "first.test", name: "Primo")
        try await install(env, host: "second.test", name: "Secondo")
        env.server.set("https://first.test/subtitles/movie/tt1.json",
                       json: "{\"subtitles\":[{\"id\":\"a\",\"url\":\"https://subs.test/same.srt\",\"lang\":\"ita\"},{\"id\":\"b\",\"url\":\"https://subs.test/en.srt\",\"lang\":\"eng\"}]}")
        env.server.set("https://second.test/subtitles/movie/tt1.json",
                       json: "{\"subtitles\":[{\"id\":\"c\",\"url\":\"https://subs.test/same.srt\",\"lang\":\"ita\",\"label\":\"Italiano SDH\"},{\"id\":\"d\",\"url\":\"https://subs.test/fr.srt\",\"lang\":\"fre\"}]}")

        let subtitles = await env.service.subtitles(type: "movie", videoID: "tt1")
        XCTAssertEqual(subtitles.map { $0.id }, ["a", "b", "d"])
        XCTAssertEqual(subtitles.map { $0.addonName }, ["Primo", "Primo", "Secondo"])

        let candidates = SubtitleCatalog.candidates(from: subtitles, preferences: SubtitlePreferences(languages: ["fr", "it"]))
        XCTAssertEqual(candidates.map { $0.subtitle.id }, ["d", "a", "b"])
        XCTAssertEqual(candidates.map { $0.addonName }, ["Secondo", "Primo", "Primo"])
    }

    func testProbeAndServiceWorkTogether() async throws {
        let env = try TestEnvironment()
        try await install(env, host: "os.test")
        let files = RangeFileServer(size: 200_000)
        let probe = SubtitleHashProbe(http: files, policy: testPolicy(), timeout: 5)

        let stream = AddonStream(source: .url("https://cdn.test/dl/Movie.2020.mkv?sig=xyz"))
        guard case .success(let local) = await probe.probe(stream: stream) else { return XCTFail("the probe should succeed") }
        XCTAssertEqual(local, SubtitleHashResult(hash: "60a0df1f5fa2cd40", size: 200_000))

        let expected = "https://os.test/subtitles/movie/tt0133093/videoHash=60a0df1f5fa2cd40&videoSize=200000&filename=Movie.2020.mkv.json"
        env.server.set(expected, json: reply)
        let subtitles = await env.service.subtitles(type: "movie", videoID: "tt0133093", stream: stream, local: local)
        XCTAssertEqual(subtitles.map { $0.id }, ["1"])
        XCTAssertEqual(files.requests.count, 2)
    }
}
