import XCTest
import AetherCore
@testable import Aether

@MainActor
final class FakeCastBackend: CastBackend {
    let target: CastTarget
    var availability: CastAvailability = .available
    var devices: [CastDevice] = []
    var isDiscovering = false
    var onDevicesChanged: (() -> Void)?
    var onStatus: ((CastRemoteStatus) -> Void)?
    var onSessionEnded: ((String?) -> Void)?

    var loadError: Error?
    var loaded: [CastMedia] = []
    var endedSessions = 0
    var commands: [String] = []

    init(target: CastTarget) { self.target = target }

    func startDiscovery() { isDiscovering = true }
    func stopDiscovery() { isDiscovering = false }
    func load(_ media: CastMedia, on device: CastDevice) async throws {
        if let error = loadError { throw error }
        loaded.append(media)
    }
    func play() async { commands.append("play") }
    func pause() async { commands.append("pause") }
    func seek(to seconds: Double) async { commands.append("seek:\(Int(seconds))") }
    func endSession() async { endedSessions += 1 }
}

/// Scenario 17 (network errors while casting) at the coordinator level, with fake receivers.
/// A real TV is not involved: see docs/04-TESTING.md for what remains hardware-only.
@MainActor
final class CastCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var settings: SettingsStore!
    private var cast: FakeCastBackend!
    private var dlna: FakeCastBackend!
    private var coordinator: CastCoordinator!
    private let device = CastDevice(id: "tv-1", name: "Salotto", target: .googleCast, detail: nil)
    private let media = CastMedia(url: URL(string: "https://example.com/movie.mp4")!, title: "Film", subtitle: nil,
                                  artworkURL: nil, contentType: "video/mp4", isLive: false, startPosition: 12)

    override func setUp() {
        super.setUp()
        suite = "aether.tests.cast.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = SettingsStore(defaults: defaults)
        cast = FakeCastBackend(target: .googleCast)
        dlna = FakeCastBackend(target: .dlna)
        coordinator = CastCoordinator(settings: settings, googleCast: cast, dlna: dlna)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testSuccessfulCastCreatesASession() async throws {
        try await coordinator.cast(media, to: device, localPosition: 12)
        XCTAssertEqual(coordinator.session?.device, device)
        XCTAssertEqual(cast.loaded.count, 1)
        XCTAssertNil(coordinator.lastError)
    }

    func testNetworkFailureWhileConnectingLeavesNoSessionAndExplainsWhy() async {
        cast.loadError = CastError.deviceUnreachable("«Salotto» non risponde.")
        do {
            try await coordinator.cast(media, to: device, localPosition: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "«Salotto» non risponde.")
        }
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(coordinator.lastError, "«Salotto» non risponde.")
    }

    func testReceiverRejectingTheMediaIsSurfacedAsFailedState() async throws {
        try await coordinator.cast(media, to: device, localPosition: 0)
        cast.onStatus?(CastRemoteStatus(state: .failed("formato non supportato"), position: 0, duration: nil))
        XCTAssertEqual(coordinator.lastError, "formato non supportato")
        XCTAssertEqual(coordinator.session?.status.state, .failed("formato non supportato"))
    }

    func testConnectionLostMidSessionEndsItAndReportsThePosition() async throws {
        var ended: (Double, String?)?
        coordinator.onRemoteSessionEnded = { position, reason in ended = (position, reason) }
        try await coordinator.cast(media, to: device, localPosition: 0)
        cast.onStatus?(CastRemoteStatus(state: .playing, position: 301, duration: 3600))
        cast.onSessionEnded?("Il televisore non risponde più.")
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(ended?.0, 301)
        XCTAssertEqual(ended?.1, "Il televisore non risponde più.")
        XCTAssertEqual(coordinator.lastError, "Il televisore non risponde più.")
    }

    func testPlaybackEndingOnTheReceiverClosesTheSession() async throws {
        var endedAt: Double?
        coordinator.onRemoteSessionEnded = { position, _ in endedAt = position }
        try await coordinator.cast(media, to: device, localPosition: 0)
        cast.onStatus?(CastRemoteStatus(state: .ended, position: 3590, duration: 3600))
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(endedAt, 3590)
    }

    func testStopEndsTheRemoteSessionAndHandsBackThePosition() async throws {
        var endedAt: Double?
        coordinator.onRemoteSessionEnded = { position, _ in endedAt = position }
        try await coordinator.cast(media, to: device, localPosition: 0)
        cast.onStatus?(CastRemoteStatus(state: .playing, position: 99, duration: 3600))
        coordinator.stop()
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(endedAt, 99)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(cast.endedSessions, 1)
    }

    func testStatusFromAnInactiveBackendIsIgnored() async throws {
        try await coordinator.cast(media, to: device, localPosition: 0)
        dlna.onStatus?(CastRemoteStatus(state: .failed("stale"), position: 0, duration: nil))
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(coordinator.session?.status.state, .connecting)
    }

    func testSwitchingProtocolEndsThePreviousSession() async throws {
        try await coordinator.cast(media, to: device, localPosition: 0)
        let tv = CastDevice(id: "dlna-1", name: "Camera", target: .dlna, detail: nil)
        try await coordinator.cast(media, to: tv, localPosition: 0)
        XCTAssertEqual(cast.endedSessions, 1)
        XCTAssertEqual(coordinator.session?.device, tv)
    }

    func testDisabledProtocolRefusesWithAReason() async {
        settings.value.casting.googleCastEnabled = false
        do {
            try await coordinator.cast(media, to: device, localPosition: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Disattivato"))
        }
        XCTAssertNil(coordinator.session)
    }

    func testUnavailableBackendRefusesWithItsReason() async {
        cast.availability = .unavailable("SDK assente")
        do {
            try await coordinator.cast(media, to: device, localPosition: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "SDK assente")
        }
    }

    func testDevicesFromEnabledProtocolsAreMerged() {
        cast.devices = [device]
        dlna.devices = [CastDevice(id: "dlna-1", name: "Camera", target: .dlna, detail: nil)]
        cast.onDevicesChanged?()
        XCTAssertEqual(coordinator.devices.count, 2)
        settings.value.casting.dlnaEnabled = false
        cast.onDevicesChanged?()
        XCTAssertEqual(coordinator.devices.map { $0.target }, [.googleCast])
    }

    func testDiscoveryStartsOnlyForEnabledProtocolsAndStops() {
        settings.value.casting.dlnaEnabled = false
        coordinator.beginDiscovery()
        XCTAssertTrue(cast.isDiscovering)
        XCTAssertFalse(dlna.isDiscovering)
        coordinator.endDiscovery()
        XCTAssertFalse(cast.isDiscovering)
    }

    func testContentTypeMapping() {
        XCTAssertEqual(CastMedia.contentType(forContainer: "m3u8"), "application/x-mpegURL")
        XCTAssertEqual(CastMedia.contentType(forContainer: "webm"), "video/webm")
        XCTAssertEqual(CastMedia.contentType(forContainer: nil), "video/mp4")
    }
}
