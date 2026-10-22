import XCTest
import AetherCore
@testable import Aether

@MainActor
final class LocalRemuxServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var settings: SettingsStore!
    private var servers: [FakeLoopbackServer] = []
    private var fetcher = ProbingFetcher()
    private var maker = FakeConversionMaker()
    private var service: LocalRemuxService!
    private let upstream = RelayUpstream(url: URL(string: "https://cdn.example.com/dl/film.mkv?token=SECRET123")!,
                                         headers: ["Authorization": "Bearer SECRET123"])

    override func setUp() {
        super.setUp()
        suite = "aether.tests.localremux.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = SettingsStore(defaults: defaults)
        let fetcher = self.fetcher
        service = LocalRemuxService(
            settings: settings, resolver: StaticHostResolver(["cdn.example.com": [.v4(93, 184, 216, 34)]]),
            engineMaker: maker.maker, fetcherFactory: { _, _ in fetcher },
            serverFactory: { [unowned self] _, _, _ in
                let server = FakeLoopbackServer()
                self.servers.append(server)
                return server
            })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheConvertedFileIsServedOnThePhoneItselfWithoutTheKey() async throws {
        let session = try await service.open(upstream, audio: .standard)
        let text = session.url.absoluteString
        XCTAssertNotNil(text.range(of: "^http://127\\.0\\.0\\.1:50999/r/[0-9a-f]{64}/index\\.m3u8$", options: .regularExpression), text)
        XCTAssertFalse(text.contains("SECRET123"))
        XCTAssertEqual(session.plan.audio.map { $0.codec }, ["aac"])
        XCTAssertEqual(session.plan.audioChoices.count, 2)
        XCTAssertTrue(service.hasSession)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].started, 1)
    }

    func testTheAudioChoiceReachesTheConverter() async throws {
        let session = try await service.open(upstream, audio: .automatic(languages: ["en"]))
        XCTAssertEqual(maker.choices, [.automatic(languages: ["en"])])
        XCTAssertEqual(session.plan.audio.map { $0.language }, ["eng"])
    }

    func testOpeningAnotherFileEndsTheFirst() async throws {
        let first = try await service.open(upstream, audio: .standard)
        let second = try await service.open(upstream, audio: .track(index: 2))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(maker.engines.count, 2)
        XCTAssertEqual(maker.engines[0].closeCount, 1, "the first conversion is dropped")
        XCTAssertEqual(maker.engines[1].closeCount, 0)
        XCTAssertEqual(second.plan.audio.map { $0.index }, [2])
    }

    func testClosingStopsTheListenerAndTheConverter() async throws {
        let session = try await service.open(upstream, audio: .standard)
        service.close(session)
        XCTAssertFalse(service.hasSession)
        XCTAssertEqual(maker.engines[0].closeCount, 1)
        XCTAssertEqual(servers[0].stopped, 1, "nothing listens when nothing is converted")
    }

    func testClosingEndsTheConnectionToTheSourceHost() async throws {
        let session = try await service.open(upstream, audio: .standard)
        XCTAssertEqual(fetcher.invalidated, 0)
        service.close(session)
        XCTAssertEqual(fetcher.invalidated, 1, "the reader of the source does not outlive the conversion")
    }

    func testAListenerTheSystemTookAwayIsStartedAgainWhileAFileIsOpen() async throws {
        _ = try await service.open(upstream, audio: .standard)
        XCTAssertEqual(servers.count, 1)
        servers[0].onFailure?()
        for _ in 0..<100 where servers.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(servers.count, 2, "a new listener replaces the one that failed")
        XCTAssertEqual(servers[0].stopped, 1)
        XCTAssertEqual(servers[1].started, 1)
        XCTAssertTrue(service.hasSession)
    }

    func testTwoStartsAtOnceLeaveOneWorkingSession() async throws {
        let first = Task { try await self.service.open(self.upstream, audio: .standard) }
        let second = Task { try await self.service.open(self.upstream, audio: .track(index: 2)) }
        let results = [await first.result, await second.result]
        let sessions = results.compactMap { try? $0.get() }
        XCTAssertEqual(sessions.count, 1, "the older start gives way to the newer one")
        XCTAssertTrue(service.hasSession)
        if let kept = sessions.first {
            service.close(kept)
            XCTAssertFalse(service.hasSession, "closing the session that was returned really closes the conversion")
        }
    }

    func testAFileThatCannotBeCopiedIsRefusedWithTheReason() async {
        maker.refusal = .refused(.noUsableAudio(["dts"]))
        do {
            _ = try await service.open(upstream, audio: .standard)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? RemuxError, .refused(.noUsableAudio(["dts"])))
            XCTAssertTrue(RemuxFailureText.explain(error).contains("DTS"))
        }
        XCTAssertFalse(service.hasSession)
        XCTAssertEqual(maker.engines.first?.closeCount, 1, "a refused file is not kept open")
        XCTAssertTrue(servers.isEmpty || servers.allSatisfy { $0.started == 0 }, "no listener for a file that cannot be served")
    }

    func testABuildWithoutTheConverterSaysSo() async {
        maker.available = false
        do {
            _ = try await service.open(upstream, audio: .standard)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LocalRemuxError, .unavailable)
            XCTAssertEqual(RemuxFailureText.explain(error), LocalRemuxError.unavailable.message)
        }
    }

    func testADownloadedFileIsNotConverted() async {
        do {
            _ = try await service.open(RelayUpstream(url: URL(fileURLWithPath: "/tmp/film.mkv")), audio: .standard)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LocalRemuxError, .notOnTheNetwork)
        }
    }

    func testAnAddressOnTheHomeNetworkIsRefusedUnlessTheViewerAllowsIt() async {
        let home = RelayUpstream(url: URL(string: "http://192.168.1.20:8096/film.mkv")!)
        settings.value.privacy.allowLocalNetwork = false
        do {
            _ = try await service.open(home, audio: .standard)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LocalRemuxError, .blocked)
        }
        settings.value.privacy.allowLocalNetwork = true
        do {
            let session = try await service.open(home, audio: .standard)
            XCTAssertTrue(service.hasSession)
            XCTAssertNotNil(session)
        } catch {
            XCTFail("a server of the viewer's own network is allowed when the setting is on: \(error)")
        }
    }

    func testAProbeFailureIsExplainedWithoutTheAddress() async {
        fetcher.probeError = RelayError.upstreamRejected(status: 403)
        do {
            _ = try await service.open(upstream, audio: .standard)
            XCTFail("expected an error")
        } catch {
            let text = RemuxFailureText.explain(error)
            XCTAssertEqual(text, "Il link del servizio è scaduto. Riapri la sorgente per ottenerne uno nuovo.")
            XCTAssertFalse(text.contains("SECRET123"))
        }
        XCTAssertEqual(fetcher.invalidated, 1)
    }

    func testASourceThatDoesNotAnswerInRangesIsExplained() async {
        fetcher.length = nil
        do {
            _ = try await service.open(upstream, audio: .standard)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(RemuxFailureText.explain(error).contains("a pezzi"))
        }
    }
}
