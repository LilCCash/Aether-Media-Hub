import XCTest
import AetherCore
@testable import Aether

/// What the player tells the viewer about AirPlay. No stream is started: the route is injected.
@MainActor
final class AirPlayAdviceModelTests: XCTestCase {
    private func makeModel(_ url: String) -> PlayerViewModel {
        let env = AppEnvironment(arguments: ["-AETHER_UITEST", "-AETHER_UITEST_SESSION", UUID().uuidString, "-AETHER_UITEST_RESET"])
        let meta = MetaItem(id: "tt9000001", type: "movie", name: "Aether Fixture One")
        let stream = AddonStream(source: .url(url), name: "Test")
        let request = PlayerRequest(meta: meta, video: nil, source: .stream(stream), alternatives: [])
        let model = PlayerViewModel(request: request, env: env)
        model.screenMirroredProvider = { false }
        return model
    }

    func testMPVSendsOnlyTheSoundToAnAirPlayDevice() throws {
        let model = makeModel("https://cdn.example.com/film.mkv")
        try XCTSkipUnless(model.engine.kind == .mpv, "this build does not play .mkv with MPV")
        model.airPlayRouteProvider = { "Samsung" }
        model.refreshAirPlayRoute()
        XCTAssertEqual(model.airPlayAdvice, .audioOnlyBecauseMPV(route: "Samsung"))
        XCTAssertEqual(model.airPlayRoute, "Samsung", "the route must not be wiped by an engine that never reports external playback")
        XCTAssertEqual(model.airPlayAlert?.title, "AirPlay: sul televisore va solo l'audio")

        model.acknowledgeAirPlayAlert()
        XCTAssertNil(model.airPlayAlert)
        XCTAssertEqual(model.airPlayAdvice, .audioOnlyBecauseMPV(route: "Samsung"), "the chip stays while the sound goes to AirPlay")

        model.refreshAirPlayRoute()
        XCTAssertNil(model.airPlayAlert, "the same route does not ask again")
    }

    func testLeavingAirPlayClearsTheAdviceAndTheSameDeviceDoesNotAskAgain() throws {
        let model = makeModel("https://cdn.example.com/film.mkv")
        try XCTSkipUnless(model.engine.kind == .mpv, "this build does not play .mkv with MPV")
        model.airPlayRouteProvider = { "Samsung" }
        model.refreshAirPlayRoute()
        model.acknowledgeAirPlayAlert()

        model.airPlayRouteProvider = { nil }
        model.refreshAirPlayRoute()
        XCTAssertEqual(model.airPlayAdvice, .none)
        XCTAssertNil(model.airPlayRoute)

        model.airPlayRouteProvider = { "Samsung" }
        model.refreshAirPlayRoute()
        XCTAssertEqual(model.airPlayAdvice, .audioOnlyBecauseMPV(route: "Samsung"))
        XCTAssertNil(model.airPlayAlert, "already explained for this device during this player session")

        model.airPlayRouteProvider = { "Camera" }
        model.refreshAirPlayRoute()
        XCTAssertEqual(model.airPlayAlert?.title, "AirPlay: sul televisore va solo l'audio", "another device is explained too")
    }

    func testMirroringTheScreenNeedsNoWarning() throws {
        let model = makeModel("https://cdn.example.com/film.mkv")
        try XCTSkipUnless(model.engine.kind == .mpv, "this build does not play .mkv with MPV")
        model.screenMirroredProvider = { true }
        model.airPlayRouteProvider = { "Samsung" }
        model.refreshAirPlayRoute()
        XCTAssertEqual(model.airPlayAdvice, .none)
        XCTAssertNil(model.airPlayAlert)
    }

    func testAVPlayerShowsNoChipUntilExternalPlaybackIsActive() {
        let model = makeModel("https://cdn.example.com/film.mp4")
        XCTAssertEqual(model.engine.kind, .avPlayer)
        model.airPlayRouteProvider = { "Samsung" }
        model.refreshAirPlayRoute()
        XCTAssertNil(model.airPlayRoute)
        XCTAssertEqual(model.airPlayAdvice, .none)
        XCTAssertNil(model.airPlayAlert)
    }
}
