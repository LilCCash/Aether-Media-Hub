import XCTest
@testable import AetherCore

final class AddonDebridRoutingTests: XCTestCase {
    private let rdKey = "RDKEY1234567890ABCDEFGH"

    private func handle(_ url: String, scope: AddonDebridScope? = nil) -> AddonHandle {
        let manifest = AddonManifest(id: "test.addon", version: "1.0.0", name: "Test")
        var addon = InstalledAddon(manifest: manifest, host: URL(string: url)?.host ?? "", fingerprint: "f")
        addon.debridScope = scope
        return AddonHandle(addon: addon, transportURL: URL(string: url)!)
    }

    private var realDebrid: StreamDebridContext { StreamDebridContext(service: .realDebrid, realDebridKey: rdKey) }
    private var torbox: StreamDebridContext { StreamDebridContext(service: .torbox) }

    private func url(_ decision: AddonDebridRouting.Decision) -> URL? {
        if case .use(let url, _) = decision { return url }
        return nil
    }

    // MARK: TorBox: nothing changes

    func testWithTorBoxEveryAddonIsAskedExactlyAsInstalled() {
        let torrentio = handle("https://torrentio.strem.fun/sort=quality%7Ctorbox=TBKEY1234567890ABCD/manifest.json")
        XCTAssertEqual(AddonDebridRouting.decide(torrentio, context: torbox), .use(torrentio.transportURL, switched: nil))
        let other = handle("https://example.org/abc/manifest.json", scope: .torbox)
        XCTAssertEqual(AddonDebridRouting.decide(other, context: torbox), .use(other.transportURL, switched: nil))
        XCTAssertEqual(AddonDebridRouting.decide(handle("https://x.org/manifest.json", scope: .realDebrid), context: torbox), .skip)
    }

    func testWithoutAContextNothingChanges() {
        let torrentio = handle("https://torrentio.strem.fun/torbox=TBKEY1234567890ABCD/manifest.json", scope: .realDebrid)
        XCTAssertEqual(AddonDebridRouting.decide(torrentio, context: nil), .use(torrentio.transportURL, switched: nil))
    }

    // MARK: Real-Debrid

    func testScopesWithRealDebrid() {
        XCTAssertEqual(AddonDebridRouting.decide(handle("https://x.org/manifest.json", scope: .torbox), context: realDebrid), .skip)
        let mediaFusion = handle("https://mediafusion.elfhosted.com/ENCRYPTED/manifest.json", scope: .realDebrid)
        XCTAssertEqual(AddonDebridRouting.decide(mediaFusion, context: realDebrid), .use(mediaFusion.transportURL, switched: nil))
        let unknown = handle("https://mammamia.example/cfg/manifest.json")
        XCTAssertEqual(AddonDebridRouting.decide(unknown, context: realDebrid), .use(unknown.transportURL, switched: nil))
    }

    func testTorrentioIsSwitchedToRealDebridKeepingTheOtherOptions() throws {
        let original = handle("https://torrentio.strem.fun/providers=yts,eztv%7Csort=quality%7Ctorbox=TBKEY1234567890ABCD/manifest.json")
        let decision = AddonDebridRouting.decide(original, context: realDebrid)
        guard case .use(let url, let switched) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(switched, .torrentio)
        let config = try XCTUnwrap(url.pathComponents.dropLast().last)
        XCTAssertEqual(config, "providers=yts,eztv|sort=quality|debridoptions=nodownloadlinks|realdebrid=\(rdKey)")
        XCTAssertFalse(url.absoluteString.contains("TBKEY"))
        XCTAssertEqual(url.lastPathComponent, "manifest.json")
        XCTAssertEqual(url.host, "torrentio.strem.fun")
    }

    func testTorrentioKeepsItsDebridOptionsAndReadsAnEncodedPath() throws {
        let original = handle("https://torrentio.strem.fun/debridoptions=nocatalog%7Ctorbox=TBKEY1234567890ABCD/manifest.json")
        let url = try XCTUnwrap(self.url(AddonDebridRouting.decide(original, context: realDebrid)))
        XCTAssertEqual(url.pathComponents.dropLast().last, "debridoptions=nocatalog,nodownloadlinks|realdebrid=\(rdKey)")
    }

    func testTorrentioWithoutConfigurationGetsOne() throws {
        let original = handle("https://torrentio.strem.fun/manifest.json")
        let url = try XCTUnwrap(self.url(AddonDebridRouting.decide(original, context: realDebrid)))
        XCTAssertEqual(url.pathComponents.dropLast().last, "debridoptions=nodownloadlinks|realdebrid=\(rdKey)")
    }

    func testWithoutARealDebridTokenTheAddonIsUsedAsInstalled() {
        let original = handle("https://torrentio.strem.fun/torbox=TBKEY1234567890ABCD/manifest.json")
        let context = StreamDebridContext(service: .realDebrid, realDebridKey: nil)
        XCTAssertEqual(AddonDebridRouting.decide(original, context: context), .use(original.transportURL, switched: nil))
    }

    func testCometIsSwitchedToRealDebridWithOnlyReadySources() throws {
        let config: [String: Any] = [
            "debridService": "torbox", "debridApiKey": "TBKEY", "cachedOnly": false, "enableTorrent": true,
            "maxResultsPerResolution": 5, "languages": ["required": ["it"]], "resultFormat": ["all"],
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let encoded = data.base64EncodedString()
        let original = handle("https://comet.elfhosted.com/\(encoded)/manifest.json")
        let decision = AddonDebridRouting.decide(original, context: realDebrid)
        guard case .use(let url, let switched) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(switched, .comet)
        let segment = try XCTUnwrap(url.pathComponents.dropLast().last)
        XCTAssertFalse(segment.contains("/") || segment.contains("+"))
        let decoded = try XCTUnwrap(AddonDebridRouting.decodeCometConfig(segment))
        XCTAssertEqual(decoded["debridService"] as? String, "realdebrid")
        XCTAssertEqual(decoded["debridApiKey"] as? String, rdKey)
        XCTAssertEqual(decoded["cachedOnly"] as? Bool, true)
        XCTAssertEqual(decoded["enableTorrent"] as? Bool, false)
        XCTAssertEqual(decoded["maxResultsPerResolution"] as? Int, 5)
        XCTAssertEqual((decoded["languages"] as? [String: Any])?["required"] as? [String], ["it"])
        let services = try XCTUnwrap(decoded["debridServices"] as? [[String: Any]])
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services.first?["service"] as? String, "realdebrid")
        XCTAssertEqual(services.first?["apiKey"] as? String, rdKey)
    }

    func testCometTextThatWouldGiveSlashesIsEscaped() throws {
        let config: [String: Any] = ["debridService": "torbox", "note": "what? a > b ~ c"]
        let encoded = try XCTUnwrap(AddonDebridRouting.encodeCometConfig(config))
        XCTAssertFalse(encoded.contains("/") || encoded.contains("+"))
        let decoded = try XCTUnwrap(AddonDebridRouting.decodeCometConfig(encoded))
        XCTAssertEqual(decoded["note"] as? String, "what? a > b ~ c")
    }

    func testAnUnreadableCometIsNotAsked() {
        let original = handle("https://comet.elfhosted.com/not-base64!!/manifest.json")
        XCTAssertEqual(AddonDebridRouting.decide(original, context: realDebrid), .unreadable(.comet))
    }

    // MARK: Ready sources

    func testOnlyReadySourcesAreKept() {
        func stream(_ name: String) -> AddonStream { AddonStream(source: .url("https://x.org/v.mkv"), name: name) }
        XCTAssertTrue(AddonDebridRouting.isReadyOnRealDebrid(stream("[RD+] Torrentio\n4k"), kind: .torrentio))
        XCTAssertFalse(AddonDebridRouting.isReadyOnRealDebrid(stream("[RD download] Torrentio\n4k"), kind: .torrentio))
        XCTAssertFalse(AddonDebridRouting.isReadyOnRealDebrid(stream("Torrentio\nRD error"), kind: .torrentio))
        XCTAssertTrue(AddonDebridRouting.isReadyOnRealDebrid(stream("[RD\u{26A1}] Comet 1080p"), kind: .comet))
        XCTAssertFalse(AddonDebridRouting.isReadyOnRealDebrid(stream("[RD\u{2B07}] Comet 1080p"), kind: .comet))
        XCTAssertFalse(AddonDebridRouting.isReadyOnRealDebrid(stream("[RD\u{2B07}\u{FE0F}] Comet 1080p"), kind: .comet))
        XCTAssertFalse(AddonDebridRouting.isReadyOnRealDebrid(stream("[RD U] 1080p"), kind: .comet))
    }

    func testAddonsSavedBeforeTheScopeExistedDecode() throws {
        let manifest = AddonManifest(id: "test.addon", version: "1.0.0", name: "Test")
        let addon = InstalledAddon(manifest: manifest, host: "x.org", fingerprint: "f")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(addon)) as? [String: Any])
        object.removeValue(forKey: "debridScope")
        let decoded = try JSONDecoder().decode(InstalledAddon.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.debridScope)
    }
}
