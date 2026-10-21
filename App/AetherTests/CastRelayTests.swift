import XCTest
import AetherCore
@testable import Aether

@MainActor
final class FakeRelay: RelayPublishing {
    var availability: RelayAvailability = .ready(LANInterface(name: "en0", address: "192.168.1.50", netmask: "255.255.255.0"))
    var onLeaseLost: ((RelayLease, RelayEndReason) -> Void)?
    var publishError: Error?
    var served = 0
    private(set) var published: [RelayPublishRequest] = []
    private(set) var released: [(lease: RelayLease, reason: RelayEndReason)] = []
    private var counter = 0

    static let token = String(repeating: "ab", count: 32)

    func publish(_ request: RelayPublishRequest) async throws -> RelayLease {
        if let error = publishError { throw error }
        published.append(request)
        counter += 1
        return RelayLease(id: RelaySessionID(label: "lease\(counter)"), url: URL(string: "http://192.168.1.50:50123/r/\(FakeRelay.token)/video.\(request.fileExtension)")!)
    }

    func release(_ lease: RelayLease, reason: RelayEndReason) {
        released.append((lease, reason))
    }

    func requestsServed(_ lease: RelayLease) -> Int { return served }
}

/// The cast coordinator with the relay in the middle (a fake one), at the level of what reaches the receivers.
@MainActor
final class CastRelayCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var settings: SettingsStore!
    private var cast: FakeCastBackend!
    private var dlna: FakeCastBackend!
    private var relay: FakeRelay!
    private var coordinator: CastCoordinator!
    private let device = CastDevice(id: "tv-1", name: "Salotto", target: .googleCast, detail: nil, address: "192.168.1.60")
    private let secretURL = URL(string: "https://api.torbox.app/v1/dl?token=SECRET123")!

    override func setUp() {
        super.setUp()
        suite = "aether.tests.castrelay.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = SettingsStore(defaults: defaults)
        cast = FakeCastBackend(target: .googleCast)
        dlna = FakeCastBackend(target: .dlna)
        relay = FakeRelay()
        coordinator = CastCoordinator(settings: settings, googleCast: cast, dlna: dlna, relay: relay)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func request(_ source: CastSource, ext: String = "mkv") -> CastRequest {
        return CastRequest(title: "Film", subtitle: nil, artworkURL: nil, contentType: "video/x-matroska", isLive: false, startPosition: 12,
                           source: source, fileExtension: ext)
    }

    private var relayRequest: CastRequest { return request(.relay(RelayUpstream(url: secretURL, headers: ["Authorization": "Bearer SECRET123"]))) }

    // MARK: Relay delivery

    func testARelayCastGivesTheReceiverTheRelayAddressOnly() async throws {
        try await coordinator.cast(relayRequest, to: device, localPosition: 12)
        let loaded = try XCTUnwrap(cast.loaded.first)
        XCTAssertEqual(loaded.url.absoluteString, "http://192.168.1.50:50123/r/\(FakeRelay.token)/video.mkv")
        XCTAssertFalse(loaded.url.absoluteString.contains("SECRET123"))
        XCTAssertEqual(coordinator.session?.delivery, .relay)
        let published = try XCTUnwrap(relay.published.first)
        XCTAssertEqual(published.owner, .cast(.googleCast))
        XCTAssertEqual(published.receiverAddress, "192.168.1.60")
        XCTAssertEqual(published.fileExtension, "mkv")
        XCTAssertEqual(published.contentType, "video/x-matroska")
        XCTAssertTrue(relay.released.isEmpty)
    }

    func testAnUnavailableRelayRefusesAndNothingIsSent() async {
        relay.publishError = CastError.relayUnavailable("Il ponte sul telefono non è disponibile: test.")
        do {
            try await coordinator.cast(relayRequest, to: device, localPosition: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Il ponte sul telefono non è disponibile: test.")
        }
        XCTAssertTrue(cast.loaded.isEmpty, "the receiver must never be given the real address as a fallback")
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(coordinator.lastError, "Il ponte sul telefono non è disponibile: test.")
    }

    func testACoordinatorWithoutARelayRefusesARelayRequest() async {
        let bare = CastCoordinator(settings: settings, googleCast: cast, dlna: dlna)
        do {
            try await bare.cast(relayRequest, to: device, localPosition: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CastError)
        }
        XCTAssertTrue(cast.loaded.isEmpty)
    }

    // MARK: The lease is released exactly once

    func testStoppingReleasesTheLease() async throws {
        try await coordinator.cast(relayRequest, to: device, localPosition: 0)
        coordinator.stop()
        XCTAssertEqual(relay.released.map { $0.reason }, [.userStopped])
        coordinator.stop()
        XCTAssertEqual(relay.released.count, 1)
    }

    func testTheReceiverEndingReleasesTheLease() async throws {
        try await coordinator.cast(relayRequest, to: device, localPosition: 0)
        cast.onStatus?(CastRemoteStatus(state: .ended, position: 3590, duration: 3600))
        XCTAssertEqual(relay.released.map { $0.reason }, [.receiverEnded])
    }

    func testTheReceiverDroppingTheSessionReleasesTheLease() async throws {
        try await coordinator.cast(relayRequest, to: device, localPosition: 0)
        cast.onSessionEnded?("Il televisore non risponde più.")
        XCTAssertEqual(relay.released.map { $0.reason }, [.receiverEnded])
        XCTAssertNil(coordinator.session)
    }

    func testALoadFailureReleasesTheLease() async {
        cast.loadError = CastError.deviceUnreachable("«Salotto» non risponde.")
        relay.served = 5
        do {
            try await coordinator.cast(relayRequest, to: device, localPosition: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "«Salotto» non risponde.", "a receiver that did reach the phone gets no network hint")
        }
        XCTAssertEqual(relay.released.map { $0.reason }, [.loadFailed])
        XCTAssertNil(coordinator.session)
    }

    func testSwitchingToAnotherProtocolReleasesTheOldLeaseBeforeThePublish() async throws {
        try await coordinator.cast(relayRequest, to: device, localPosition: 0)
        let tv = CastDevice(id: "dlna-1", name: "Camera", target: .dlna, detail: nil, address: "192.168.1.61")
        try await coordinator.cast(relayRequest, to: tv, localPosition: 0)
        XCTAssertEqual(relay.released.map { $0.reason }, [.replaced])
        XCTAssertEqual(relay.published.map { $0.owner }, [.cast(.googleCast), .cast(.dlna)])
        XCTAssertEqual(cast.endedSessions, 1)
    }

    func testALeaseLostByTheRelayEndsTheSessionWithAReason() async throws {
        var ended: (Double, String?)?
        coordinator.onRemoteSessionEnded = { position, reason in ended = (position, reason) }
        try await coordinator.cast(relayRequest, to: device, localPosition: 0)
        cast.onStatus?(CastRemoteStatus(state: .playing, position: 301, duration: 3600))
        let lost = try XCTUnwrap(coordinator.session).title
        XCTAssertEqual(lost, "Film")
        let lease = RelayLease(id: RelaySessionID(label: "lease1"), url: URL(string: "http://192.168.1.50:50123/r/x/video.mkv")!)
        relay.onLeaseLost?(lease, .addressChanged)
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(ended?.0, 301)
        XCTAssertTrue(coordinator.lastError?.contains("Il ponte si è interrotto") ?? false)
        XCTAssertTrue(relay.released.isEmpty, "a lease the relay already ended is not released again")
    }

    func testAnExpiredSourceLinkIsExplained() async throws {
        try await coordinator.cast(relayRequest, to: device, localPosition: 0)
        let lease = RelayLease(id: RelaySessionID(label: "lease1"), url: URL(string: "http://192.168.1.50:50123/r/x/video.mkv")!)
        relay.onLeaseLost?(lease, .upstreamRejected)
        XCTAssertEqual(coordinator.lastError, "Il link del servizio è scaduto. Riapri la sorgente per ottenerne uno nuovo.")
    }

    // MARK: The network hint

    func testAReceiverThatNeverReachedThePhoneGetsTheLocalNetworkHint() async throws {
        try await coordinator.cast(relayRequest, to: device, localPosition: 0)
        relay.served = 0
        cast.onStatus?(CastRemoteStatus(state: .failed("Errore del ricevitore"), position: 0, duration: nil))
        XCTAssertTrue(coordinator.lastError?.contains("Rete locale") ?? false)
    }

    func testAFailureAfterTheReceiverReadFromThePhoneKeepsItsOwnMessage() async throws {
        try await coordinator.cast(relayRequest, to: device, localPosition: 0)
        relay.served = 3
        cast.onStatus?(CastRemoteStatus(state: .failed("Errore del ricevitore"), position: 0, duration: nil))
        XCTAssertEqual(coordinator.lastError, "Errore del ricevitore")
    }

    func testALoadTimeoutWithoutAnyRequestGetsTheHint() async {
        cast.loadError = CastError.timedOut
        relay.served = 0
        do {
            try await coordinator.cast(relayRequest, to: device, localPosition: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Rete locale"))
        }
    }

    // MARK: Direct link with the key

    func testTheKeyLinkIsNotSentUnlessTheSettingIsOn() async {
        do {
            try await coordinator.cast(request(.directWithKey(secretURL)), to: device, localPosition: 0)
            XCTFail("expected an error")
        } catch {
            guard case CastError.directLinkNotAllowed = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertTrue(cast.loaded.isEmpty)
        XCTAssertNil(coordinator.session)
    }

    func testTheKeyLinkIsSentWhenTheSettingIsOnAndTurningItOffEndsTheSession() async throws {
        settings.value.advanced.sendDirectLinkToTV = true
        var ended: (Double, String?)?
        coordinator.onRemoteSessionEnded = { position, reason in ended = (position, reason) }
        try await coordinator.cast(request(.directWithKey(secretURL)), to: device, localPosition: 0)
        XCTAssertEqual(cast.loaded.first?.url, secretURL)
        XCTAssertEqual(coordinator.session?.delivery, .directWithKey)
        XCTAssertTrue(relay.published.isEmpty, "the relay is not involved when the key link is sent")

        var advanced = settings.value.advanced
        advanced.sendDirectLinkToTV = false
        coordinator.advancedDidChange(advanced)
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(coordinator.lastError, "Trasmissione interrotta: il link diretto è stato disattivato.")
        XCTAssertEqual(ended?.1, "Trasmissione interrotta: il link diretto è stato disattivato.")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(cast.endedSessions, 1)
    }

    func testTurningTheSettingOffDoesNotTouchOtherSessions() async throws {
        try await coordinator.cast(relayRequest, to: device, localPosition: 0)
        coordinator.advancedDidChange(AdvancedSettings())
        XCTAssertNotNil(coordinator.session)
    }

    // MARK: Nothing prints the address

    func testNoDescriptionHoldsAnAddressOrAToken() async throws {
        let sample = relayRequest
        let media = sample.media(url: URL(string: "http://192.168.1.50:50123/r/\(FakeRelay.token)/video.mkv")!)
        let lease = RelayLease(id: RelaySessionID(label: "lease1"), url: media.url)
        var dumped = ""
        dump(sample, to: &dumped)
        dump(media, to: &dumped)
        dump(lease, to: &dumped)
        let texts = [String(describing: sample), String(reflecting: sample), String(describing: media), String(reflecting: media),
                     String(describing: lease), String(reflecting: lease), dumped]
        for text in texts {
            XCTAssertFalse(text.contains("SECRET123"), text)
            XCTAssertFalse(text.contains(FakeRelay.token), text)
            XCTAssertFalse(text.contains("192.168.1.50"), text)
            XCTAssertFalse(text.contains("torbox"), text)
        }
    }
}
