import XCTest
import AetherCore
@testable import Aether

private final class FakeRelayServer: RelayServing, @unchecked Sendable {
    var port: UInt16?
    var onFailure: (@Sendable () -> Void)?
    var started = 0
    var stopped = 0
    var failStart = false

    func start(preferredPort: UInt16?) async throws -> UInt16 {
        if failStart { throw RelayServerError.couldNotStart }
        started += 1
        let chosen = preferredPort ?? 50123
        port = chosen
        return chosen
    }

    func stop() {
        stopped += 1
        port = nil
    }

    func url(host: String, token: String, leaf: String) -> URL? {
        return URL(string: "http://\(host):\(port ?? 0)/r/\(token)/\(leaf)")
    }
}

private final class StubFetcher: RelayRangeFetcher, @unchecked Sendable {
    var probeError: Error?

    func probe() async throws -> RelayResource {
        if let error = probeError { throw error }
        return RelayResource(contentType: "application/octet-stream", length: 1000, acceptsRanges: true)
    }

    func fetch(_ range: ClosedRange<Int64>) async throws -> Data {
        return Data(count: range.count)
    }
}

private final class LANBox: @unchecked Sendable {
    var interface: LANInterface? = LANInterface(name: "en0", address: "192.168.1.50", netmask: "255.255.255.0")
}

@MainActor
final class RelayServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var settings: SettingsStore!
    private var lan: LANBox!
    private var servers: [FakeRelayServer] = []
    private var fetcher: StubFetcher!
    private var diagnostics: DiagnosticLog!
    private var maker = FakeConversionMaker()
    private var service: RelayService!
    private let upstream = RelayUpstream(url: URL(string: "https://cdn.example.com/dl/f.mkv?token=SECRET123")!, headers: ["Authorization": "Bearer SECRET123"])

    override func setUp() {
        super.setUp()
        suite = "aether.tests.relay.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = SettingsStore(defaults: defaults)
        settings.value.privacy.allowLocalNetwork = true
        lan = LANBox()
        fetcher = StubFetcher()
        diagnostics = DiagnosticLog(enabled: true)
        makeService(idleStopDelay: 0.15)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeService(idleStopDelay: TimeInterval) {
        let lan = self.lan!
        let fetcher = self.fetcher!
        service = RelayService(
            settings: settings, diagnostics: diagnostics, lan: { lan.interface },
            serverFactory: { [unowned self] _, _, _ in
                let server = FakeRelayServer()
                self.servers.append(server)
                return server
            },
            fetcherFactory: { _, _ in fetcher },
            remuxMaker: maker.maker,
            resolver: StaticHostResolver(["cdn.example.com": [.v4(93, 184, 216, 34)]]),
            idleStopDelay: idleStopDelay, watchInterval: 0.05)
    }

    private func request(owner: RelayOwner = .cast(.googleCast)) -> RelayPublishRequest {
        return RelayPublishRequest(upstream: upstream, contentType: "video/x-matroska", fileExtension: "mkv", owner: owner, receiverAddress: "192.168.1.60")
    }

    private func token(of lease: RelayLease) -> String {
        return lease.url.pathComponents.dropFirst(2).first ?? ""
    }

    func testPublishReturnsAKeylessAddressOnThePhonesWifi() async throws {
        let lease = try await service.publish(request())
        let text = lease.url.absoluteString
        let pattern = "^http://192\\.168\\.1\\.50:50123/r/[0-9a-f]{64}/video\\.mkv$"
        XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), text)
        XCTAssertFalse(text.contains("SECRET123"))
        XCTAssertEqual(service.leaseCount, 1)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].started, 1)
    }

    // MARK: Converted files

    private func conversion(_ audio: RemuxAudioChoice = .standard) -> RelayPublishRequest {
        var converted = request()
        converted.contentType = "application/x-mpegURL"
        converted.fileExtension = "m3u8"
        converted.remux = audio
        return converted
    }

    func testAConvertedFileIsServedAsHLSOnTheWifiAddress() async throws {
        let lease = try await service.publish(conversion(.automatic(languages: ["en"])))
        let text = lease.url.absoluteString
        XCTAssertNotNil(text.range(of: "^http://192\\.168\\.1\\.50:50123/r/[0-9a-f]{64}/index\\.m3u8$", options: .regularExpression), text)
        XCTAssertFalse(text.contains("SECRET123"))
        XCTAssertEqual(lease.remuxPlan?.audio.map { $0.language }, ["eng"])
        XCTAssertEqual(maker.choices, [.automatic(languages: ["en"])])
        XCTAssertEqual(service.leaseCount, 1)
    }

    func testAFileThatCannotBeConvertedIsRefusedBeforeAnythingListens() async {
        maker.refusal = .refused(.videoCodec("vp9"))
        do {
            _ = try await service.publish(conversion())
            XCTFail("expected a refusal")
        } catch CastError.conversionRefused(let message) {
            XCTAssertTrue(message.contains("VP9"), message)
        } catch {
            XCTFail("expected a conversion refusal, got \(error)")
        }
        XCTAssertEqual(service.leaseCount, 0)
        XCTAssertTrue(servers.isEmpty, "the listener is only started for something that can be served")
        XCTAssertEqual(maker.engines.first?.closeCount, 1)
    }

    func testABuildWithoutTheConverterRefusesTheConversion() async {
        maker.available = false
        do {
            _ = try await service.publish(conversion())
            XCTFail("expected a refusal")
        } catch CastError.conversionRefused(let message) {
            XCTAssertEqual(message, LocalRemuxError.unavailable.message)
        } catch {
            XCTFail("expected a conversion refusal, got \(error)")
        }
        XCTAssertTrue(servers.isEmpty)
    }

    func testAConvertedLeaseEndsLikeAnyOther() async throws {
        let lease = try await service.publish(conversion())
        service.release(lease, reason: .userStopped)
        XCTAssertEqual(service.leaseCount, 0)
        XCTAssertEqual(maker.engines[0].closeCount, 1, "the converter is closed with the session")
    }

    func testNoWifiMeansNoRelayAndNoServer() async {
        lan.interface = nil
        XCTAssertEqual(service.availability, .unavailable(.noLAN))
        do {
            _ = try await service.publish(request())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Wi-Fi"))
        }
        XCTAssertTrue(servers.isEmpty, "the listener must not even be created")
    }

    func testTheLocalNetworkSettingGatesTheRelay() async {
        settings.value.privacy.allowLocalNetwork = false
        XCTAssertEqual(service.availability, .unavailable(.localNetworkDisabledInSettings))
        do {
            _ = try await service.publish(request())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rete locale"))
        }
        XCTAssertTrue(servers.isEmpty)
    }

    func testTheRelayCannotBePointedAtThePhoneItself() async {
        let itself = RelayUpstream(url: URL(string: "https://192.168.1.50/anything")!, headers: [:])
        do {
            _ = try await service.publish(RelayPublishRequest(upstream: itself, contentType: "video/mp4", fileExtension: "mp4",
                                                              owner: .cast(.googleCast), receiverAddress: nil))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CastError)
        }
        XCTAssertEqual(service.leaseCount, 0)
        XCTAssertTrue(servers.isEmpty)
    }

    func testALoopbackAddressIsRefused() async {
        let loopback = RelayUpstream(url: URL(string: "https://127.0.0.1:8080/x")!, headers: [:])
        do {
            _ = try await service.publish(RelayPublishRequest(upstream: loopback, contentType: "video/mp4", fileExtension: "mp4",
                                                              owner: .cast(.googleCast), receiverAddress: nil))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is CastError)
        }
        XCTAssertTrue(servers.isEmpty)
    }

    func testAProbeFailureLeavesNothingBehind() async {
        fetcher.probeError = RelayError.upstreamNoRanges
        do {
            _ = try await service.publish(request())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("a pezzi"))
        }
        XCTAssertEqual(service.leaseCount, 0)
        XCTAssertTrue(servers.isEmpty, "the listener is only started for a source that can be served")
    }

    func testAnExpiredLinkAtTheProbeIsExplained() async {
        fetcher.probeError = RelayError.upstreamRejected(status: 403)
        do {
            _ = try await service.publish(request())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Il link del servizio è scaduto. Riapri la sorgente per ottenerne uno nuovo.")
        }
    }

    func testAListenerThatCannotStartIsReported() async {
        makeFailingService()
        do {
            _ = try await service.publish(request())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("non riesco ad avviare il ponte"))
        }
        XCTAssertEqual(service.leaseCount, 0)
        XCTAssertTrue(service.listenerFailed)
    }

    private func makeFailingService() {
        let lan = self.lan!
        let fetcher = self.fetcher!
        service = RelayService(
            settings: settings, diagnostics: diagnostics, lan: { lan.interface },
            serverFactory: { _, _, _ in
                let server = FakeRelayServer()
                server.failStart = true
                return server
            },
            fetcherFactory: { _, _ in fetcher },
            resolver: StaticHostResolver(["cdn.example.com": [.v4(93, 184, 216, 34)]]),
            idleStopDelay: 0.15, watchInterval: 0.05)
    }

    func testTheServerStopsAfterTheLastReleaseButNotIfAnotherSessionComesFirst() async throws {
        let first = try await service.publish(request())
        service.release(first, reason: .userStopped)
        XCTAssertEqual(service.leaseCount, 0)
        let second = try await service.publish(request())          // inside the delay: the stop is cancelled
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(servers[0].stopped, 0)
        XCTAssertEqual(servers.count, 1, "the running server is reused")

        service.release(second, reason: .userStopped)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(servers[0].stopped, 1)
    }

    func testChangingNetworkEndsTheSessionsWithAReason() async throws {
        var lost: [(RelayLease, RelayEndReason)] = []
        service.onLeaseLost = { lease, reason in lost.append((lease, reason)) }
        let lease = try await service.publish(request())
        lan.interface = LANInterface(name: "en0", address: "10.0.0.7", netmask: "255.255.255.0")
        service.networkChanged()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(lost.map { $0.1 }, [.addressChanged])
        XCTAssertEqual(lost.first?.0, lease)
        XCTAssertEqual(service.leaseCount, 0)
    }

    func testAReleasedLeaseIsNotReportedAsLost() async throws {
        var lost = 0
        service.onLeaseLost = { _, _ in lost += 1 }
        let lease = try await service.publish(request())
        service.release(lease, reason: .userStopped)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(lost, 0)
        XCTAssertEqual(service.requestsServed(lease), 0)
    }

    func testTheLogHoldsNeitherTheKeyNorTheToken() async throws {
        let lease = try await service.publish(request())
        let secret = token(of: lease)
        XCTAssertEqual(secret.count, 64)
        service.release(lease, reason: .userStopped)
        try await Task.sleep(nanoseconds: 300_000_000)
        let text = await diagnostics.exportText()
        XCTAssertTrue(text.contains("Ponte: sessione"), text)
        XCTAssertFalse(text.contains("SECRET123"), text)
        XCTAssertFalse(text.contains(secret), text)
        XCTAssertFalse(text.contains("cdn.example.com"), text)
    }

    func testPeerRulesAndLocalSources() {
        XCTAssertEqual(RelayService.peerRule(for: "192.168.1.60"), .expected(["192.168.1.60"]))
        XCTAssertEqual(RelayService.peerRule(for: nil), .any)
        XCTAssertEqual(RelayService.peerRule(for: "tv.local"), .any)
        XCTAssertEqual(RelayService.peerRule(for: "fe80::1"), .any)
        XCTAssertTrue(RelayService.isLocalSource(URL(string: "http://192.168.1.20:8080/a")!))
        XCTAssertTrue(RelayService.isLocalSource(URL(string: "http://nas.local/a")!))
        XCTAssertFalse(RelayService.isLocalSource(URL(string: "https://cdn.example.com/a")!))
        XCTAssertFalse(RelayService.isLocalSource(URL(string: "https://93.184.216.34/a")!))
    }
}
