import XCTest
@testable import AetherCore

final class UpstreamGuardTests: XCTestCase {
    private let resolver = StaticHostResolver([
        "cdn.example.com": [.v4(93, 184, 216, 34)],
        "other.example.net": [.v4(151, 101, 1, 69)],
        "rebinding.example.org": [.v4(192, 168, 1, 1)],
        "mixed.example.org": [.v4(93, 184, 216, 34), .v4(10, 0, 0, 7)],
        "nas.lan": [.v4(192, 168, 1, 20)],
        "nas2.lan": [.v4(192, 168, 1, 30)],
        "numeric.example.org": [.v4(127, 0, 0, 1)]
    ])

    private func guardian(allowPrivate: Bool = false, allowLoopback: Bool = false, own: Set<String> = ["192.168.1.5"]) -> UpstreamGuard {
        return UpstreamGuard(allowPrivateOrigin: allowPrivate, allowLoopback: allowLoopback, selfAddresses: own, resolver: resolver)
    }

    private func url(_ text: String) -> URL {
        return URL(string: text)!
    }

    private func block(_ guardian: UpstreamGuard, origin text: String) async -> UpstreamBlock? {
        do {
            try await guardian.validateOrigin(url(text))
            return nil
        } catch {
            return error as? UpstreamBlock
        }
    }

    private func block(_ guardian: UpstreamGuard, from: String, to: String, hop: Int = 1, origin: String? = nil) async -> UpstreamBlock? {
        do {
            try await guardian.validateRedirect(from: url(from), to: url(to), hop: hop, origin: url(origin ?? from))
            return nil
        } catch {
            return error as? UpstreamBlock
        }
    }

    // MARK: Origins

    func testAPublicHttpsOriginIsAllowed() async {
        let result = await block(guardian(), origin: "https://cdn.example.com/dl/a.mkv?token=x")
        XCTAssertNil(result)
        let literal = await block(guardian(), origin: "https://93.184.216.34/a.mkv")
        XCTAssertNil(literal)
        let port = await block(guardian(), origin: "https://cdn.example.com:8443/a.mkv")
        XCTAssertNil(port)
    }

    func testPlainHttpToAPublicHostIsRefused() async {
        let named = await block(guardian(), origin: "http://cdn.example.com/a.mkv")
        XCTAssertEqual(named, .scheme)
        let literal = await block(guardian(allowPrivate: true), origin: "http://93.184.216.34/a.mkv")
        XCTAssertEqual(literal, .scheme)
        let named2 = await block(guardian(allowPrivate: true), origin: "http://cdn.example.com/a.mkv")
        XCTAssertEqual(named2, .scheme)
    }

    func testOtherSchemesAndCredentialsAreRefused() async {
        let ftp = await block(guardian(), origin: "ftp://cdn.example.com/a.mkv")
        XCTAssertEqual(ftp, .scheme)
        let file = await block(guardian(), origin: "file:///etc/passwd")
        XCTAssertEqual(file, .scheme)
        let creds = await block(guardian(), origin: "https://user:pass@cdn.example.com/a.mkv")
        XCTAssertEqual(creds, .credentialsInURL)
        let user = await block(guardian(), origin: "https://user@cdn.example.com/a.mkv")
        XCTAssertEqual(user, .credentialsInURL)
    }

    func testTheDeviceItselfIsNeverAnOrigin() async {
        for text in ["https://127.0.0.1/a", "https://localhost/a", "https://sub.localhost/a", "https://[::1]/a", "https://[::ffff:127.0.0.1]/a",
                     "https://0.0.0.0/a", "https://[::]/a", "https://127.1.2.3:8080/a"] {
            let result = await block(guardian(), origin: text)
            XCTAssertEqual(result, .loopback, text)
        }
    }

    func testLinkLocalMulticastAndReservedAreRefused() async {
        for text in ["https://169.254.1.1/a", "https://224.0.0.1/a", "https://255.255.255.255/a", "https://[fe80::1]/a", "https://[ff02::1]/a"] {
            let result = await block(guardian(allowPrivate: true), origin: text)
            XCTAssertEqual(result, .privateAddress, text)
        }
    }

    func testANameThatResolvesToTheHomeNetworkIsRefused() async {
        let rebinding = await block(guardian(), origin: "https://rebinding.example.org/a")
        XCTAssertEqual(rebinding, .privateAddress)
        let mixed = await block(guardian(), origin: "https://mixed.example.org/a")
        XCTAssertEqual(mixed, .privateAddress, "a single private address in the answer is enough")
        let numeric = await block(guardian(), origin: "https://numeric.example.org/a")
        XCTAssertEqual(numeric, .loopback)
    }

    func testAnUnresolvableNameIsRefused() async {
        let result = await block(guardian(), origin: "https://nowhere.example.com/a")
        XCTAssertEqual(result, .dnsFailure)
    }

    func testTheRelaysOwnAddressIsRefused() async {
        let literal = await block(guardian(allowPrivate: true), origin: "http://192.168.1.5:50000/r/abc/video.mkv")
        XCTAssertEqual(literal, .selfAddress)
        let secure = await block(guardian(), origin: "https://192.168.1.5/a")
        XCTAssertEqual(secure, .selfAddress)
        let mapped = await block(guardian(allowPrivate: true), origin: "https://[::ffff:192.168.1.5]/a")
        XCTAssertEqual(mapped, .selfAddress)
        let named = UpstreamGuard(allowPrivateOrigin: true, selfAddresses: ["192.168.1.5"],
                                  resolver: StaticHostResolver(["phone.lan": [.v4(192, 168, 1, 5)]]))
        do {
            try await named.validateOrigin(url("https://phone.lan/a"))
            XCTFail("the phone's own name must be refused")
        } catch {
            XCTAssertEqual(error as? UpstreamBlock, .selfAddress)
        }
    }

    func testASourceOnTheLocalNetworkNeedsThePermission() async {
        let denied = await block(guardian(allowPrivate: false), origin: "https://192.168.1.20/a.mkv")
        XCTAssertEqual(denied, .privateAddress)
        let deniedHttp = await block(guardian(allowPrivate: false), origin: "http://192.168.1.20/a.mkv")
        XCTAssertEqual(deniedHttp, .scheme)
        let allowed = await block(guardian(allowPrivate: true), origin: "http://192.168.1.20:8080/a.mkv")
        XCTAssertNil(allowed)
        let allowedHttps = await block(guardian(allowPrivate: true), origin: "https://192.168.1.20/a.mkv")
        XCTAssertNil(allowedHttps)
        let named = await block(guardian(allowPrivate: true), origin: "http://nas.lan/a.mkv")
        XCTAssertNil(named)
    }

    func testLoopbackIsOnlyForTests() async {
        let allowed = await block(guardian(allowLoopback: true), origin: "https://127.0.0.1:9/a")
        XCTAssertNil(allowed)
        let named = await block(guardian(allowLoopback: true), origin: "https://localhost/a")
        XCTAssertNil(named)
        let unspecified = await block(guardian(allowLoopback: true), origin: "https://0.0.0.0/a")
        XCTAssertEqual(unspecified, .loopback)
    }

    // MARK: Redirects

    func testRedirectsBetweenPublicHostsAreFine() async {
        let result = await block(guardian(), from: "https://cdn.example.com/a", to: "https://other.example.net/b")
        XCTAssertNil(result)
    }

    func testTooManyRedirectsAreRefused() async {
        let third = await block(guardian(), from: "https://cdn.example.com/a", to: "https://other.example.net/b", hop: 3)
        XCTAssertNil(third)
        let fourth = await block(guardian(), from: "https://cdn.example.com/a", to: "https://other.example.net/b", hop: 4)
        XCTAssertEqual(fourth, .tooManyRedirects)
    }

    func testARedirectNeverDowngradesToHttp() async {
        let result = await block(guardian(allowPrivate: true), from: "https://cdn.example.com/a", to: "http://other.example.net/b")
        XCTAssertEqual(result, .downgrade)
        let local = await block(guardian(allowPrivate: true), from: "https://192.168.1.20/a", to: "http://192.168.1.20/b")
        XCTAssertEqual(local, .downgrade)
    }

    func testARedirectCannotLeadToTheHomeNetworkOrTheDevice() async {
        for target in ["https://192.168.1.1/b", "https://127.0.0.1/b", "https://169.254.169.254/latest", "https://192.168.1.5/b",
                       "https://rebinding.example.org/b", "https://[::1]/b"] {
            let result = await block(guardian(allowPrivate: true), from: "https://cdn.example.com/a", to: target)
            XCTAssertNotNil(result, target)
        }
        let credentials = await block(guardian(), from: "https://cdn.example.com/a", to: "https://u:p@other.example.net/b")
        XCTAssertEqual(credentials, .credentialsInURL)
    }

    func testASourceOnTheLocalNetworkMayOnlyRedirectToItself() async {
        let sameHost = await block(guardian(allowPrivate: true), from: "http://192.168.1.20:8080/a", to: "http://192.168.1.20:8080/b")
        XCTAssertNil(sameHost)
        let otherPrivate = await block(guardian(allowPrivate: true), from: "http://192.168.1.20/a", to: "http://192.168.1.30/b")
        XCTAssertNotNil(otherPrivate)
        let otherNamed = await block(guardian(allowPrivate: true), from: "http://nas.lan/a", to: "http://nas2.lan/b")
        XCTAssertNotNil(otherNamed)
        let toPublic = await block(guardian(allowPrivate: true), from: "http://nas.lan/a", to: "https://cdn.example.com/b", origin: "http://nas.lan/a")
        XCTAssertNil(toPublic)
    }

    func testAPublicOriginNeverGainsLocalPrivileges() async {
        // Even with local access on, a public origin that redirects to its own name (now resolving privately) is refused.
        let result = await block(guardian(allowPrivate: true), from: "https://rebinding.example.org/a", to: "https://rebinding.example.org/b",
                                 origin: "https://cdn.example.com/a")
        XCTAssertEqual(result, .privateAddress)
    }

    // MARK: Session headers

    func testHeadersOnlyGoToTheExactOrigin() {
        let strict = guardian()
        let origin = url("https://cdn.example.com/dl/a.mkv")
        XCTAssertTrue(strict.mayCarrySessionHeaders(to: url("https://cdn.example.com/other/path?x=1"), origin: origin))
        XCTAssertTrue(strict.mayCarrySessionHeaders(to: url("https://CDN.example.com:443/b"), origin: origin))
        XCTAssertFalse(strict.mayCarrySessionHeaders(to: url("https://other.example.net/b"), origin: origin))
        XCTAssertFalse(strict.mayCarrySessionHeaders(to: url("https://sub.cdn.example.com/b"), origin: origin))
        XCTAssertFalse(strict.mayCarrySessionHeaders(to: url("http://cdn.example.com/b"), origin: origin))
        XCTAssertFalse(strict.mayCarrySessionHeaders(to: url("https://cdn.example.com:8443/b"), origin: origin))
    }
}
