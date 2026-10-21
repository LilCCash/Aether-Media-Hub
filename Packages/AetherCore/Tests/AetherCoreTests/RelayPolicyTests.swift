import XCTest
@testable import AetherCore

final class CastDeliveryTests: XCTestCase {
    private let lan = LANInterface(name: "en0", address: "192.168.1.23", netmask: "255.255.255.0")
    private var ready: RelayAvailability { return .ready(lan) }
    private let down = RelayAvailability.unavailable(.noLAN)

    private func decide(_ traits: CastSourceTraits, target: CastTarget = .googleCast, direct: Bool = false,
                        relay: RelayAvailability) -> CastDeliveryOutcome {
        return CastDeliveryPlanner.decide(traits, target: target, sendDirectLinkToTV: direct, relay: relay)
    }

    private let key = CastSourceTraits(carriesAccountKey: true)
    private let headers = CastSourceTraits(hasRequestHeaders: true)

    func testAKeyLinkGoesThroughTheRelayWhenItIsReady() {
        XCTAssertEqual(decide(key, relay: ready), .deliver(.relay))
        XCTAssertEqual(decide(key, target: .dlna, relay: ready), .deliver(.relay))
    }

    func testAKeyLinkIsRefusedWhenTheRelayIsNotAvailableAndNeverSentDirectly() {
        for target in [CastTarget.googleCast, .dlna] {
            let outcome = decide(key, target: target, relay: down)
            XCTAssertEqual(outcome, .refuse(.relayUnavailable(.noLAN, carriesKey: true, headers: false)))
        }
    }

    func testChoosingTheDirectLinkSendsTheKeyLinkAsItIs() {
        for target in [CastTarget.googleCast, .dlna] {
            XCTAssertEqual(decide(key, target: target, direct: true, relay: ready), .deliver(.directWithKey))
            XCTAssertEqual(decide(key, target: target, direct: true, relay: down), .deliver(.directWithKey))
        }
    }

    func testRequestHeadersAlwaysNeedTheRelayWhateverTheSetting() {
        for direct in [false, true] {
            XCTAssertEqual(decide(headers, direct: direct, relay: ready), .deliver(.relay))
            XCTAssertEqual(decide(headers, direct: direct, relay: down), .refuse(.relayUnavailable(.noLAN, carriesKey: false, headers: true)))
        }
    }

    func testAKeyLinkThatAlsoNeedsHeadersUsesTheRelayEvenWithTheDirectSetting() {
        let both = CastSourceTraits(carriesAccountKey: true, hasRequestHeaders: true)
        XCTAssertEqual(decide(both, direct: true, relay: ready), .deliver(.relay))
    }

    func testAPlainAddressIsSentAsItIs() {
        for relay in [ready, down] {
            XCTAssertEqual(decide(CastSourceTraits(), relay: relay), .deliver(.direct))
            XCTAssertEqual(decide(CastSourceTraits(), direct: true, relay: relay), .deliver(.direct))
        }
    }

    func testADownloadedFileIsRefused() {
        XCTAssertEqual(decide(CastSourceTraits(isLocalFile: true), relay: ready), .refuse(.localFile))
    }

    func testAirPlayDoesNotGoThroughTheCoordinator() {
        XCTAssertEqual(decide(key, target: .airPlay, relay: down), .deliver(.direct))
        XCTAssertEqual(decide(CastSourceTraits(isLocalFile: true), target: .airPlay, relay: down), .deliver(.direct))
    }

    func testNoRefusalMessageContainsAnAddressOrTheWordToken() {
        let refusals: [CastRefusal] = [
            .localFile, .plainHTTPNeedsRelay,
            .relayUnavailable(.noLAN, carriesKey: true, headers: false), .relayUnavailable(.localNetworkDisabledInSettings, carriesKey: true, headers: false),
            .relayUnavailable(.listenerFailed, carriesKey: false, headers: true)
        ]
        for refusal in refusals {
            let text = (refusal.title + " " + refusal.message).lowercased()
            XCTAssertFalse(text.contains("http://") || text.contains("https://"), "\(refusal)")
            XCTAssertFalse(text.contains("token"), "\(refusal)")
            XCTAssertFalse(refusal.message.isEmpty)
        }
    }

    func testTheRefusalSaysWhyTheRelayCannotRun() {
        let noWifi = CastRefusal.relayUnavailable(.noLAN, carriesKey: true, headers: false).message
        XCTAssertTrue(noWifi.contains("Wi-Fi"))
        XCTAssertTrue(noWifi.contains("Impostazioni ▸ Avanzate"), "it points to the direct-link setting")
        let disabled = CastRefusal.relayUnavailable(.localNetworkDisabledInSettings, carriesKey: true, headers: false).message
        XCTAssertTrue(disabled.contains("rete locale"))
        let headersMessage = CastRefusal.relayUnavailable(.noLAN, carriesKey: false, headers: true).message
        XCTAssertFalse(headersMessage.contains("Impostazioni ▸ Avanzate"), "the direct-link setting cannot help a header-bound source")
    }
}

final class CastCompatibilityRelayTests: XCTestCase {
    private func info(_ url: String, details: String = "", hints: StreamBehaviorHints = StreamBehaviorHints()) -> (URL, StreamInfo) {
        let stream = AddonStream(source: .url(url), details: details, behaviorHints: hints)
        return (URL(string: url)!, StreamAnalyzer.analyze(stream))
    }

    private let headers = ["Referer": "https://x.test"]

    func testTheDefaultDeliveryChangesNothing() {
        let (url, details) = info("https://cdn.example.com/a.mp4", details: "1080p x264")
        for target in CastTarget.allCases {
            XCTAssertEqual(CastCompatibility.evaluate(url: url, info: details, target: target),
                           CastCompatibility.evaluate(url: url, info: details, target: target, delivery: .direct))
        }
        XCTAssertTrue(CastCompatibility.evaluate(url: url, info: details, headers: headers, target: .googleCast).isBlocked)
        XCTAssertTrue(CastCompatibility.evaluate(url: url, info: details, headers: headers, target: .dlna).isBlocked)
    }

    func testRequestHeadersAreNotABlockWhenThePhoneRelays() {
        let (url, details) = info("https://cdn.example.com/a.mp4", details: "1080p x264")
        for target in [CastTarget.googleCast, .dlna] {
            XCTAssertFalse(CastCompatibility.evaluate(url: url, info: details, headers: headers, target: target, delivery: .relay).isBlocked, target.title)
        }
    }

    func testALocalNetworkSourceNeedsNoRoomOnTheTelevisionsNetworkWhenRelayed() {
        let (url, details) = info("http://192.168.1.20/a.mp4")
        let direct = CastCompatibility.evaluate(url: url, info: details, target: .googleCast)
        guard case .warning(let directMessages) = direct else { return XCTFail("expected a warning") }
        XCTAssertTrue(directMessages.contains(where: { $0.contains("rete locale") }))
        let relayed = CastCompatibility.evaluate(url: url, info: details, target: .googleCast, delivery: .relay)
        XCTAssertEqual(relayed, .ok, "the phone reaches its own LAN source; the television only needs the phone")
    }

    func testPlainHTTPAndHTTPSWarningsDisappearWhenRelayed() {
        let (httpURL, httpInfo) = info("http://192.168.1.20/a.mp4")
        XCTAssertEqual(CastCompatibility.evaluate(url: httpURL, info: httpInfo, target: .googleCast, delivery: .relay), .ok)
        let (httpsURL, httpsInfo) = info("https://cdn.example.com/a.mp4", details: "1080p x264")
        guard case .warning(let dlnaDirect) = CastCompatibility.evaluate(url: httpsURL, info: httpsInfo, target: .dlna) else {
            return XCTFail("direct HTTPS on DLNA warns")
        }
        XCTAssertTrue(dlnaDirect.contains(where: { $0.contains("HTTPS") }))
        XCTAssertEqual(CastCompatibility.evaluate(url: httpsURL, info: httpsInfo, target: .dlna, delivery: .relay), .ok)
    }

    func testLoopbackIsStillBlockedWhenRelayed() {
        let (url, details) = info("http://127.0.0.1:8080/a.mp4")
        for target in CastTarget.allCases {
            XCTAssertTrue(CastCompatibility.evaluate(url: url, info: details, target: target, delivery: .relay).isBlocked, target.title)
        }
    }

    func testPlainHTTPFromThePublicInternetIsNotRelayed() {
        let (url, details) = info("http://cdn.example.com/a.mp4")
        let verdict = CastCompatibility.evaluate(url: url, info: details, headers: headers, target: .googleCast, delivery: .relay)
        XCTAssertEqual(verdict, .blocked(CastRefusal.plainHTTPNeedsRelay.message))
    }

    func testRelayingDoesNotMakeAnMKVWorkOnACast() {
        let (url, details) = info("https://cdn.example.com/a.mkv")
        guard case .warning(let messages) = CastCompatibility.evaluate(url: url, info: details, target: .googleCast, delivery: .relay) else {
            return XCTFail("MKV on Cast still warns")
        }
        XCTAssertTrue(messages.contains(where: { $0.contains("MKV") }))
        XCTAssertTrue(CastCompatibility.evaluate(url: url, info: details, target: .airPlay, delivery: .relay).isBlocked, "AirPlay and MKV stays blocked")
    }

    func testSendingTheKeyLinkAlwaysWarnsAboutTheKey() {
        let (url, details) = info("https://cdn.example.com/a.mp4", details: "1080p x264")
        for target in [CastTarget.googleCast, .dlna] {
            guard case .warning(let messages) = CastCompatibility.evaluate(url: url, info: details, target: target, delivery: .directWithKey) else {
                return XCTFail("the key link must never be .ok (\(target.title))")
            }
            XCTAssertTrue(messages.contains(where: { $0.contains("chiave") }), target.title)
            XCTAssertEqual(messages.contains(where: { $0.contains("in chiaro") }), target == .dlna, "the plaintext warning is for DLNA only")
        }
    }
}

final class AdvancedSettingsDirectLinkTests: XCTestCase {
    func testItIsOffByDefaultAndForOldFiles() throws {
        XCTAssertFalse(AdvancedSettings().sendDirectLinkToTV)
        let empty = try JSONDecoder.aether().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.advanced.sendDirectLinkToTV)
        let old = try JSONDecoder.aether().decode(AppSettings.self, from: Data(#"{"advanced":{"verboseLogging":true,"streamingServerURL":"http://x"}}"#.utf8))
        XCTAssertFalse(old.advanced.sendDirectLinkToTV)
        XCTAssertTrue(old.advanced.verboseLogging, "the other advanced settings are kept")
    }

    func testItRoundTripsUnderItsOwnKey() throws {
        var settings = AppSettings()
        settings.advanced.sendDirectLinkToTV = true
        let data = try JSONEncoder.aether().encode(settings)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"sendDirectLinkToTV\""))
        XCTAssertEqual(try JSONDecoder.aether().decode(AppSettings.self, from: data), settings)
    }

    func testAWrongTypeFallsBackToOff() throws {
        let settings = try JSONDecoder.aether().decode(AppSettings.self, from: Data(#"{"advanced":{"sendDirectLinkToTV":"yes"}}"#.utf8))
        XCTAssertFalse(settings.advanced.sendDirectLinkToTV)
    }
}

final class AirPlayAdviceTests: XCTestCase {
    private func advice(_ engine: PlaybackEngineKind, route: String? = "Samsung", external: Bool = false, mirrored: Bool = false,
                        blocked: Bool = false, serving: Bool = false) -> AirPlayAdvice {
        return AirPlayAdvice.evaluate(engine: engine, routeName: route, externalPlaybackActive: external, screenMirrored: mirrored,
                                      externalPlaybackBlockedForKey: blocked, relayServing: serving)
    }

    func testMPVWithAnAirPlayRouteMeansAudioOnly() {
        XCTAssertEqual(advice(.mpv), .audioOnlyBecauseMPV(route: "Samsung"))
    }

    func testNoRouteOrMirroringMeansNoAdvice() {
        XCTAssertEqual(advice(.mpv, route: nil), .none)
        XCTAssertEqual(advice(.mpv, mirrored: true), .none)
        XCTAssertEqual(advice(.avPlayer, route: nil, blocked: true), .none)
    }

    func testAVPlayerCases() {
        XCTAssertEqual(advice(.avPlayer, external: true), .none)
        XCTAssertEqual(advice(.avPlayer, blocked: true), .audioOnlyBecauseKeyProtected(route: "Samsung"))
        XCTAssertEqual(advice(.avPlayer, external: true, serving: true), .videoViaRelay(route: "Samsung"))
        XCTAssertEqual(advice(.avPlayer, external: false, serving: true), .none, "the relay is armed but the picture is not out yet")
    }

    func testABlankRouteNameFallsBackToAirPlay() {
        XCTAssertEqual(advice(.mpv, route: "   "), .audioOnlyBecauseMPV(route: "AirPlay"))
    }
}

final class LANInterfaceSelectorTests: XCTestCase {
    private func raw(_ name: String, _ address: String, mask: String = "255.255.255.0", up: Bool = true, running: Bool = true) -> RawInterface {
        return RawInterface(name: name, address: address, netmask: mask, isUp: up, isRunning: running, isLoopback: name.hasPrefix("lo"))
    }

    func testItPicksTheWiFiOutOfTheUsualMess() {
        let picked = LANInterfaceSelector.pick(from: [
            raw("lo0", "127.0.0.1", mask: "255.0.0.0"), raw("pdp_ip0", "10.20.30.40"), raw("awdl0", "169.254.1.1"),
            raw("utun3", "10.8.0.2"), raw("bridge100", "172.20.10.1", mask: "255.255.255.240"), raw("en0", "192.168.1.23")
        ])
        XCTAssertEqual(picked, LANInterface(name: "en0", address: "192.168.1.23", netmask: "255.255.255.0"))
        XCTAssertEqual(picked?.kind, .wifi)
    }

    func testItNeverPicksALinkLocalAddressOrAnInterfaceThatIsNotRunning() {
        XCTAssertNil(LANInterfaceSelector.pick(from: [raw("en0", "169.254.9.9")]))
        XCTAssertNil(LANInterfaceSelector.pick(from: [raw("en0", "192.168.1.23", running: false)]))
        XCTAssertNil(LANInterfaceSelector.pick(from: [raw("en0", "192.168.1.23", up: false)]))
        XCTAssertNil(LANInterfaceSelector.pick(from: [raw("en0", "8.8.8.8")]), "a public address is not a LAN")
        XCTAssertNil(LANInterfaceSelector.pick(from: []))
    }

    func testThePersonalHotspotIsUsedWhenItIsTheOnlyOne() {
        let picked = LANInterfaceSelector.pick(from: [raw("bridge100", "172.20.10.1", mask: "255.255.255.240")])
        XCTAssertEqual(picked?.name, "bridge100")
        XCTAssertEqual(picked?.kind, .hotspot)
    }

    func testOtherEthernetLikeInterfacesRankBelowEn0() {
        let picked = LANInterfaceSelector.pick(from: [raw("en5", "10.0.0.7"), raw("en0", "192.168.1.23")])
        XCTAssertEqual(picked?.name, "en0")
        XCTAssertEqual(LANInterfaceSelector.pick(from: [raw("en5", "10.0.0.7")])?.name, "en5")
    }

    func testSubnetMembership() {
        let wifi = LANInterface(name: "en0", address: "192.168.1.23", netmask: "255.255.255.0")
        XCTAssertTrue(wifi.contains(peer: "192.168.1.77"))
        XCTAssertFalse(wifi.contains(peer: "192.168.2.77"))
        XCTAssertFalse(wifi.contains(peer: "10.0.0.1"))
        XCTAssertFalse(wifi.contains(peer: "fe80::1"))
        XCTAssertFalse(wifi.contains(peer: "192.168.1.23%en0"))
        XCTAssertFalse(wifi.contains(peer: "not an address"))
        let wide = LANInterface(name: "en0", address: "10.1.2.3", netmask: "255.0.0.0")
        XCTAssertTrue(wide.contains(peer: "10.200.9.9"))
    }
}

final class RelayLogTests: XCTestCase {
    func testNoLogMessageCanCarryAnAddressOrAKey() {
        for event in RelayLogEvent.samples {
            let text = event.message
            XCTAssertFalse(text.lowercased().contains("http"), text)
            XCTAssertFalse(text.contains("/r/"), text)
            XCTAssertFalse(text.contains("SECRET"), text)
            XCTAssertFalse(text.contains("\r") || text.contains("\n"), "a hostile method must not break the line")
            XCTAssertEqual(Redactor.redact(text), text, "the redactor has nothing to hide, so the message is clean: \(text)")
        }
    }

    func testEveryKindOfEventHasASensibleLevel() {
        for event in RelayLogEvent.samples {
            if case .served = event { XCTAssertEqual(event.level, .debug) }
            if case .upstreamFailure = event { XCTAssertEqual(event.level, .warning) }
            if case .limitHit = event { XCTAssertEqual(event.level, .warning) }
        }
        XCTAssertGreaterThanOrEqual(RelayLogEvent.samples.count, 20)
    }

    func testTheRedactorHidesATokenInARequestLineAndInAnAddress() {
        let token = String(repeating: "ab12", count: 16)
        XCTAssertEqual(token.count, 64)
        let line = Redactor.redact("GET /r/\(token)/video.mkv HTTP/1.1")
        XCTAssertFalse(line.contains(token))
        let address = Redactor.redact("http://192.168.1.23:51234/r/\(token)/video.mkv")
        XCTAssertFalse(address.contains(token))
        XCTAssertFalse(address.contains("video.mkv"), "the redactor reduces an address to its host")
    }

    func testTheSessionLabelIsShort() {
        XCTAssertEqual(RelaySessionID(label: "a1b2c3").label.count, 6)
        XCTAssertEqual(RelayLimits.standard.maxConnections, 8)
        XCTAssertEqual(RelayLimits.standard.windowSize, 4 * 1024 * 1024)
    }
}
