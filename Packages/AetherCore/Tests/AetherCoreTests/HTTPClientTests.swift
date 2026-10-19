import XCTest
@testable import AetherCore

/// Scripted network layer below `URLSession`, so the real `URLSessionHTTPClient` (delegate, redirects, limits,
/// cancellation) is exercised without sockets.
final class StubURLProtocol: URLProtocol {
    enum Step {
        case respond(status: Int, headers: [String: String], chunks: [Data])
        case redirect(to: String, status: Int)
        case fail(Error)
        case hang(seconds: TimeInterval)
    }

    static var handler: ((URLRequest) -> Step)?
    static var seenURLs: [String] = []

    static func reset() {
        handler = nil
        seenURLs = []
    }

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }

    override func startLoading() {
        guard let url = request.url, let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        StubURLProtocol.seenURLs.append(url.absoluteString)
        switch handler(request) {
        case .respond(let status, let headers, let chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target, let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .hang(let seconds):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self = self else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
        }
    }

    override func stopLoading() {}
}

final class HTTPClientTests: XCTestCase {
    private func makeClient(policy: NetworkPolicy = testPolicy()) -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionHTTPClient(policyProvider: { policy }, configuration: configuration)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testReturnsBodyStatusAndLowercasedHeaders() async throws {
        StubURLProtocol.handler = { _ in .respond(status: 200, headers: ["Content-Type": "application/json", "X-Test": "1"], chunks: [Data("{\"ok\":true}".utf8)]) }
        let response = try await makeClient().send(HTTPRequest(url: URL(string: "https://addon.test/manifest.json")!))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "{\"ok\":true}")
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertTrue(response.isSuccess)
    }

    func testHTTPErrorStatusIsReturnedNotThrown() async throws {
        StubURLProtocol.handler = { _ in .respond(status: 404, headers: [:], chunks: [Data("nope".utf8)]) }
        let response = try await makeClient().send(HTTPRequest(url: URL(string: "https://addon.test/x.json")!))
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertFalse(response.isSuccess)
    }

    func testStreamingSizeLimitAbortsOversizedBodies() async {
        let chunk = Data(repeating: 0x41, count: 400 * 1024)
        StubURLProtocol.handler = { _ in .respond(status: 200, headers: [:], chunks: [chunk, chunk, chunk, chunk]) }
        do {
            _ = try await makeClient().send(HTTPRequest(url: URL(string: "https://addon.test/big.json")!, maxBytes: 1024 * 1024))
            XCTFail("expected responseTooLarge")
        } catch let error as AddonError {
            XCTAssertEqual(error, .responseTooLarge(limit: 1024 * 1024))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testDeclaredContentLengthOverLimitIsRejectedEarly() async {
        StubURLProtocol.handler = { _ in .respond(status: 200, headers: ["Content-Length": "99999999"], chunks: [Data("x".utf8)]) }
        do {
            _ = try await makeClient().send(HTTPRequest(url: URL(string: "https://addon.test/big.json")!, maxBytes: 1024))
            XCTFail("expected responseTooLarge")
        } catch let error as AddonError {
            XCTAssertEqual(error, .responseTooLarge(limit: 1024))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRedirectToPrivateAddressIsBlocked() async {
        StubURLProtocol.handler = { request in
            if request.url?.host == "addon.test" { return .redirect(to: "https://192.168.1.1/admin", status: 302) }
            return .respond(status: 200, headers: [:], chunks: [Data("secret".utf8)])
        }
        do {
            _ = try await makeClient().send(HTTPRequest(url: URL(string: "https://addon.test/manifest.json")!))
            XCTFail("expected redirectBlocked")
        } catch let error as AddonError {
            XCTAssertEqual(error, .redirectBlocked(.privateAddress("192.168.1.1")))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertFalse(StubURLProtocol.seenURLs.contains("https://192.168.1.1/admin"), "the blocked hop must never be fetched")
    }

    func testHTTPSToHTTPDowngradeIsBlocked() async {
        StubURLProtocol.handler = { request in
            if request.url?.scheme == "https" { return .redirect(to: "http://other.test/manifest.json", status: 301) }
            return .respond(status: 200, headers: [:], chunks: [Data("{}".utf8)])
        }
        do {
            _ = try await makeClient().send(HTTPRequest(url: URL(string: "https://addon.test/manifest.json")!))
            XCTFail("expected redirectBlocked")
        } catch let error as AddonError {
            guard case .redirectBlocked = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSafeRedirectIsFollowed() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/old/manifest.json" { return .redirect(to: "https://addon.test/new/manifest.json", status: 301) }
            return .respond(status: 200, headers: [:], chunks: [Data("{\"moved\":true}".utf8)])
        }
        let response = try await makeClient().send(HTTPRequest(url: URL(string: "https://addon.test/old/manifest.json")!))
        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "{\"moved\":true}")
    }

    func testRedirectLoopStops() async {
        StubURLProtocol.handler = { request in
            let n = Int(request.url?.lastPathComponent ?? "0") ?? 0
            return .redirect(to: "https://addon.test/hop/\(n + 1)", status: 302)
        }
        do {
            _ = try await makeClient().send(HTTPRequest(url: URL(string: "https://addon.test/hop/0")!))
            XCTFail("expected tooManyRedirects")
        } catch let error as AddonError {
            XCTAssertEqual(error, .tooManyRedirects)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPolicyViolationNeverReachesTheNetwork() async {
        StubURLProtocol.handler = { _ in .respond(status: 200, headers: [:], chunks: []) }
        do {
            _ = try await makeClient().send(HTTPRequest(url: URL(string: "https://127.0.0.1/manifest.json")!))
            XCTFail("expected blockedURL")
        } catch let error as AddonError {
            XCTAssertEqual(error, .blockedURL(.loopback))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(StubURLProtocol.seenURLs.isEmpty)
    }

    func testTransportErrorsAreMapped() async {
        let cases: [(URLError.Code, AddonError)] = [
            (.timedOut, .timeout),
            (.notConnectedToInternet, .offline),
            (.serverCertificateUntrusted, .tlsFailure),
            (.cannotConnectToHost, .unreachable("addon.test"))
        ]
        for (code, expected) in cases {
            StubURLProtocol.handler = { _ in .fail(URLError(code)) }
            do {
                _ = try await makeClient().send(HTTPRequest(url: URL(string: "https://addon.test/manifest.json")!))
                XCTFail("expected \(expected)")
            } catch let error as AddonError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testTaskCancellationAbortsTheRequest() async {
        StubURLProtocol.handler = { _ in .hang(seconds: 10) }
        let client = makeClient()
        let started = Date()
        let task = Task { () -> Bool in
            do {
                _ = try await client.send(HTTPRequest(url: URL(string: "https://addon.test/slow.json")!))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled, "a cancelled task must surface CancellationError")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testDeadlineHelperTimesOut() async {
        do {
            _ = try await withDeadline(seconds: 0.2) { () -> Int in
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return 1
            }
            XCTFail("expected timeout")
        } catch let error as AddonError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("unexpected \(error)")
        }
        let value = try? await withDeadline(seconds: 2) { () -> Int in 7 }
        XCTAssertEqual(value, 7)
    }
}
