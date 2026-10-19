import XCTest
@testable import AetherCore

final class AddonURLTests: XCTestCase {
    func testParsesCanonicalAndDeepLinkForms() throws {
        XCTAssertEqual(try AddonURL.parseInstallInput("https://example.com/manifest.json").absoluteString,
                       "https://example.com/manifest.json")
        XCTAssertEqual(try AddonURL.parseInstallInput("stremio://example.com/a/b/manifest.json").absoluteString,
                       "https://example.com/a/b/manifest.json")
        XCTAssertEqual(try AddonURL.parseInstallInput("  https://example.com/addon/configure \n").absoluteString,
                       "https://example.com/addon/manifest.json")
        XCTAssertEqual(try AddonURL.parseInstallInput("https://example.com").absoluteString,
                       "https://example.com/manifest.json")
        XCTAssertEqual(try AddonURL.parseInstallInput("example.com/x").absoluteString,
                       "https://example.com/x/manifest.json")
        XCTAssertEqual(try AddonURL.parseInstallInput("<https://example.com/m/manifest.json>").absoluteString,
                       "https://example.com/m/manifest.json")
    }

    func testKeepsQueryAndDropsFragment() throws {
        let url = try AddonURL.parseInstallInput("https://example.com/x/manifest.json?config=abc#frag")
        XCTAssertEqual(url.absoluteString, "https://example.com/x/manifest.json?config=abc")
    }

    func testRejectsDangerousOrMalformedInput() {
        XCTAssertThrowsError(try AddonURL.parseInstallInput("file:///etc/passwd")) { error in
            XCTAssertEqual(error as? AddonError, .blockedURL(.scheme("file")))
        }
        XCTAssertThrowsError(try AddonURL.parseInstallInput("ftp://example.com/manifest.json")) { error in
            XCTAssertEqual(error as? AddonError, .blockedURL(.scheme("ftp")))
        }
        XCTAssertThrowsError(try AddonURL.parseInstallInput("javascript:alert(1)"))
        XCTAssertThrowsError(try AddonURL.parseInstallInput("data:text/html,<script>alert(1)</script>"))
        XCTAssertThrowsError(try AddonURL.parseInstallInput("https://user:pass@example.com/manifest.json")) { error in
            XCTAssertEqual(error as? AddonError, .blockedURL(.credentialsInURL))
        }
        XCTAssertThrowsError(try AddonURL.parseInstallInput(""))
        XCTAssertThrowsError(try AddonURL.parseInstallInput("   "))
        XCTAssertThrowsError(try AddonURL.parseInstallInput("stremio:///detail/movie/tt1"))
        XCTAssertThrowsError(try AddonURL.parseInstallInput("https://example.com/data.json"))
        XCTAssertThrowsError(try AddonURL.parseInstallInput("https://example.com/" + String(repeating: "a", count: 5000)))
    }

    func testCanonicalKeyIgnoresCaseDefaultPortAndFragment() throws {
        let a = try AddonURL.parseInstallInput("https://EXAMPLE.com:443/a/manifest.json#x")
        let b = try AddonURL.parseInstallInput("https://example.com/a/manifest.json")
        XCTAssertEqual(AddonURL.canonicalKey(a), AddonURL.canonicalKey(b))
        let c = try AddonURL.parseInstallInput("https://example.com/other/manifest.json")
        XCTAssertNotEqual(AddonURL.canonicalKey(a), AddonURL.canonicalKey(c))
    }

    func testDeepLinkInstallURL() {
        XCTAssertEqual(AddonURL.installURL(fromDeepLink: URL(string: "stremio://example.com/m/manifest.json")!)?.absoluteString,
                       "https://example.com/m/manifest.json")
        XCTAssertEqual(AddonURL.installURL(fromDeepLink: URL(string: "aether://addon?url=https%3A%2F%2Fexample.com%2Fm%2Fmanifest.json")!)?.absoluteString,
                       "https://example.com/m/manifest.json")
        XCTAssertNil(AddonURL.installURL(fromDeepLink: URL(string: "https://example.com/manifest.json")!))
        XCTAssertNil(AddonURL.installURL(fromDeepLink: URL(string: "aether://other")!))
    }

    func testDisplayHostHidesPathAndQuery() {
        let url = URL(string: "https://addon.example.com:8443/SECRETKEY/manifest.json?token=abc")!
        XCTAssertEqual(AddonURL.displayHost(url), "addon.example.com:8443")
    }
}

final class ResourceURLBuilderTests: XCTestCase {
    func testBuildsPathsLikeStremioCore() throws {
        let transport = URL(string: "https://addon.test/cfg=abc/manifest.json?token=1")!
        let path = ResourcePath(resource: "catalog", type: "movie", id: "top",
                                extra: [ExtraValue(name: "search", value: "game of thrones"), ExtraValue(name: "skip", value: "100")])
        XCTAssertEqual(ResourceURLBuilder.url(transport: transport, path: path)?.absoluteString,
                       "https://addon.test/cfg=abc/catalog/movie/top/search=game%20of%20thrones&skip=100.json?token=1")

        let plain = URL(string: "https://addon.test/manifest.json")!
        XCTAssertEqual(ResourceURLBuilder.url(transport: plain, path: ResourcePath(resource: "catalog", type: "movie", id: "top"))?.absoluteString,
                       "https://addon.test/catalog/movie/top.json")
    }

    func testIdsAreComponentEncoded() {
        let transport = URL(string: "https://addon.test/manifest.json")!
        XCTAssertEqual(ResourceURLBuilder.url(transport: transport, path: ResourcePath(resource: "stream", type: "series", id: "tt0898266:9:17"))?.absoluteString,
                       "https://addon.test/stream/series/tt0898266%3A9%3A17.json")
        XCTAssertEqual(ResourceURLBuilder.url(transport: transport, path: ResourcePath(resource: "meta", type: "channel", id: "yt_id:UC123"))?.absoluteString,
                       "https://addon.test/meta/channel/yt_id%3AUC123.json")
        XCTAssertEqual(ResourceURLBuilder.url(transport: transport, path: ResourcePath(resource: "meta", type: "movie", id: "è/../x"))?.absoluteString,
                       "https://addon.test/meta/movie/%C3%A8%2F..%2Fx.json", "path traversal characters must be escaped")
    }

    func testUnreservedSetMatchesCore() {
        XCTAssertEqual(URIComponent.encode("a b/c?d&e=f~g'h(i)*!_-."), "a%20b%2Fc%3Fd%26e%3Df~g'h(i)*!_-.")
    }

    func testNonManifestTransportIsRejected() {
        XCTAssertNil(ResourceURLBuilder.url(transport: URL(string: "https://addon.test/stremio/v1")!,
                                            path: ResourcePath(resource: "catalog", type: "movie", id: "x")))
    }
}

final class NetworkPolicyTests: XCTestCase {
    func testAddressClassification() {
        func cls(_ text: String) -> AddressClass? { return IPAddress.parse(text)?.addressClass }
        XCTAssertEqual(cls("8.8.8.8"), .publicInternet)
        XCTAssertEqual(cls("172.32.0.1"), .publicInternet)
        XCTAssertEqual(cls("10.1.2.3"), .privateNetwork)
        XCTAssertEqual(cls("172.16.5.4"), .privateNetwork)
        XCTAssertEqual(cls("172.31.255.255"), .privateNetwork)
        XCTAssertEqual(cls("192.168.1.1"), .privateNetwork)
        XCTAssertEqual(cls("100.64.0.1"), .privateNetwork)
        XCTAssertEqual(cls("127.0.0.1"), .loopback)
        XCTAssertEqual(cls("169.254.10.10"), .linkLocal)
        XCTAssertEqual(cls("0.0.0.0"), .unspecified)
        XCTAssertEqual(cls("224.0.0.251"), .multicast)
        XCTAssertEqual(cls("255.255.255.255"), .reserved)
        XCTAssertEqual(cls("::1"), .loopback)
        XCTAssertEqual(cls("fe80::1"), .linkLocal)
        XCTAssertEqual(cls("fd12:3456::1"), .privateNetwork)
        XCTAssertEqual(cls("ff02::1"), .multicast)
        XCTAssertEqual(cls("2606:4700:4700::1111"), .publicInternet)
        XCTAssertEqual(cls("::ffff:192.168.1.1"), .privateNetwork, "IPv4-mapped addresses are classified by their IPv4 part")
        XCTAssertEqual(cls("::ffff:8.8.8.8"), .publicInternet)
        XCTAssertEqual(cls("[::1]"), .loopback)
        XCTAssertNil(IPAddress.parse("256.1.1.1"))
        XCTAssertNil(IPAddress.parse("1.2.3"))
        XCTAssertNil(IPAddress.parse("example.com"))
    }

    func testPublicHTTPSIsAllowed() async throws {
        try await testPolicy().validate(URL(string: "https://example.com/manifest.json")!)
    }

    func testPlainHTTPToPublicHostIsRefusedForRequestsButNotForMedia() async throws {
        let policy = testPolicy()
        do {
            try await policy.validate(URL(string: "http://example.com/manifest.json")!)
            XCTFail("expected insecureTransport")
        } catch let error as AddonError {
            XCTAssertEqual(error, .insecureTransport)
        }
        // AVFoundation traffic has an ATS media exception.
        try await policy.validate(URL(string: "http://example.com/video.mp4")!, purpose: .mediaPlayback)
    }

    func testPrivateAndLoopbackAreBlockedByDefault() async {
        let policy = testPolicy()
        let cases: [(String, AddonError)] = [
            ("https://192.168.1.10/manifest.json", .blockedURL(.privateAddress("192.168.1.10"))),
            ("http://10.0.0.5:7000/manifest.json", .blockedURL(.privateAddress("10.0.0.5"))),
            ("https://127.0.0.1/manifest.json", .blockedURL(.loopback)),
            ("https://localhost/manifest.json", .blockedURL(.loopback)),
            ("https://[::1]/manifest.json", .blockedURL(.loopback)),
            ("https://printer.local/manifest.json", .blockedURL(.localHostname("printer.local"))),
            ("https://intranet/manifest.json", .blockedURL(.localHostname("intranet"))),
            ("https://169.254.169.254/latest/meta-data", .blockedURL(.privateAddress("169.254.169.254"))),
            ("file:///etc/passwd", .blockedURL(.scheme("file"))),
            ("ftp://example.com/x", .blockedURL(.scheme("ftp"))),
            ("https://u:p@example.com/x", .blockedURL(.credentialsInURL))
        ]
        for (text, expected) in cases {
            do {
                try await policy.validate(URL(string: text)!)
                XCTFail("\(text) should have been blocked")
            } catch let error as AddonError {
                XCTAssertEqual(error, expected, text)
            } catch {
                XCTFail("unexpected error for \(text): \(error)")
            }
        }
    }

    func testNumericHostSpellingsCannotSmuggleLoopback() async {
        for text in ["http://2130706433/", "http://0x7f000001/"] {
            for allowLocal in [false, true] {
                do {
                    try await testPolicy(allowLocal: allowLocal).validate(URL(string: text)!)
                    XCTFail("\(text) must be blocked (allowLocal=\(allowLocal))")
                } catch is AddonError {
                    // expected
                } catch {
                    XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testLocalNetworkCanBeEnabledButLoopbackStaysBlocked() async throws {
        let policy = testPolicy(allowLocal: true)
        try await policy.validate(URL(string: "http://192.168.1.10:7000/manifest.json")!)
        try await policy.validate(URL(string: "http://printer.local/manifest.json")!)
        do {
            try await policy.validate(URL(string: "http://127.0.0.1:7000/manifest.json")!)
            XCTFail("loopback must stay blocked")
        } catch let error as AddonError {
            XCTAssertEqual(error, .blockedURL(.loopback))
        }
        let loopbackAllowed = NetworkPolicy(allowLocalNetwork: false, allowLoopback: true, checkDNS: false)
        try await loopbackAllowed.validate(URL(string: "http://127.0.0.1:7000/manifest.json")!)
    }

    func testDNSRebindingToPrivateAddressIsBlocked() async throws {
        let resolver = StaticHostResolver([
            "evil.example": [.v4(192, 168, 0, 5)],
            "mixed.example": [.v4(8, 8, 8, 8), .v4(10, 0, 0, 1)],
            "good.example": [.v4(8, 8, 8, 8)],
            "metadata.example": [.v4(169, 254, 169, 254)]
        ])
        let policy = NetworkPolicy(allowLocalNetwork: false, checkDNS: true, resolver: resolver)
        try await policy.validate(URL(string: "https://good.example/manifest.json")!)
        for host in ["evil.example", "mixed.example", "metadata.example"] {
            do {
                try await policy.validate(URL(string: "https://\(host)/manifest.json")!)
                XCTFail("\(host) must be blocked")
            } catch let error as AddonError {
                XCTAssertEqual(error, .blockedURL(.privateAddress(host)))
            }
        }
        // Unresolvable hosts are not a policy violation: the request itself will fail.
        try await policy.validate(URL(string: "https://unknown.example/manifest.json")!)
        let lan = NetworkPolicy(allowLocalNetwork: true, checkDNS: true, resolver: resolver)
        try await lan.validate(URL(string: "https://evil.example/manifest.json")!)
    }

    func testIsLocalNetworkDetection() async {
        let resolver = StaticHostResolver(["nas.example": [.v4(192, 168, 1, 20)], "cdn.example": [.v4(1, 1, 1, 1)]])
        let policy = NetworkPolicy(checkDNS: true, resolver: resolver)
        let a = await policy.isLocalNetwork(URL(string: "http://192.168.1.2/m")!)
        let b = await policy.isLocalNetwork(URL(string: "http://nas.example/m")!)
        let c = await policy.isLocalNetwork(URL(string: "https://cdn.example/m")!)
        let d = await policy.isLocalNetwork(URL(string: "http://tv.local/m")!)
        XCTAssertTrue(a)
        XCTAssertTrue(b)
        XCTAssertFalse(c)
        XCTAssertTrue(d)
    }
}
