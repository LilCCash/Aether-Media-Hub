import XCTest
@testable import AetherCore

/// When a Matroska file goes through the on-the-fly conversion: for AVPlayer (Picture in Picture, AirPlay) and for Google Cast.
final class RemuxRoutingTests: XCTestCase {
    private let device = DeviceVideoCapabilities.conservative
    private let available = RemuxRouting(available: true, matroskaForAVPlayer: false)
    private let preferred = RemuxRouting(available: true, matroskaForAVPlayer: true)

    private func plan(_ container: String?, choice: PlayerEngineChoice, mpv: Bool = true, remux: RemuxRouting) -> PlaybackPlan {
        return PlaybackPlanner.plan(container: container, facts: nil, device: device, mpvAvailable: mpv, choice: choice, remux: remux)
    }

    func testTheAVPlayerEngineConvertsMatroskaWhenTheConverterIsThere() {
        let result = plan("mkv", choice: .avPlayer, remux: available)
        XCTAssertEqual(result.engine, .avPlayer)
        XCTAssertTrue(result.usesRemux)
        XCTAssertNil(result.blockingMessage)
        XCTAssertTrue(result.notes.contains { $0.text.contains("convertito al volo") })
    }

    func testTheAVPlayerEngineStillRefusesMatroskaWithoutTheConverter() {
        let result = plan("mkv", choice: .avPlayer, remux: .unavailable)
        XCTAssertNil(result.engine)
        XCTAssertFalse(result.usesRemux)
        XCTAssertNotNil(result.blockingMessage)
    }

    func testTheAVPlayerEngineStillRefusesOtherContainers() {
        for container in ["avi", "ts", "webm", "wmv"] {
            let result = plan(container, choice: .avPlayer, remux: preferred)
            XCTAssertNil(result.engine, container)
            XCTAssertFalse(result.usesRemux, container)
        }
    }

    func testAutomaticKeepsUsingMPVForMatroskaUnlessTheViewerAsks() {
        let result = plan("mkv", choice: .automatic, remux: available)
        XCTAssertEqual(result.engine, .mpv)
        XCTAssertFalse(result.usesRemux)
        let asked = plan("mkv", choice: .automatic, remux: preferred)
        XCTAssertEqual(asked.engine, .avPlayer)
        XCTAssertTrue(asked.usesRemux)
    }

    func testAutomaticWithTheConverterAsksForNeedsTheConverter() {
        let result = plan("mkv", choice: .automatic, remux: RemuxRouting(available: false, matroskaForAVPlayer: true))
        XCTAssertEqual(result.engine, .mpv, "the setting alone does not make the converter appear")
        XCTAssertFalse(result.usesRemux)
    }

    func testAutomaticLeavesTheOtherFormatsToMPV() {
        for container in ["avi", "ts", "webm"] {
            let result = plan(container, choice: .automatic, remux: preferred)
            XCTAssertEqual(result.engine, .mpv, container)
            XCTAssertFalse(result.usesRemux, container)
        }
    }

    func testNativeContainersNeverUseTheConverter() {
        for choice in [PlayerEngineChoice.automatic, .avPlayer] {
            let result = plan("mp4", choice: choice, remux: preferred)
            XCTAssertEqual(result.engine, .avPlayer)
            XCTAssertFalse(result.usesRemux)
        }
    }

    func testTheMPVEngineIsNeverConverted() {
        let result = plan("mkv", choice: .mpv, remux: preferred)
        XCTAssertEqual(result.engine, .mpv)
        XCTAssertFalse(result.usesRemux)
    }

    func testTheContainerNameIsMatchedWithoutCare() {
        XCTAssertTrue(plan("MKV", choice: .avPlayer, remux: available).usesRemux)
    }

    // MARK: Settings

    func testTheConversionSettingsDefaultAndSurviveARoundTrip() throws {
        XCTAssertFalse(PlaybackSettings().convertMatroskaForAVPlayer, "off until the viewer asks")
        XCTAssertTrue(CastingSettings().convertMatroskaForGoogleCast)
        let emptyPlayback = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        let emptyCasting = try JSONDecoder().decode(CastingSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(emptyPlayback.convertMatroskaForAVPlayer)
        XCTAssertTrue(emptyCasting.convertMatroskaForGoogleCast)
        var playback = PlaybackSettings()
        playback.convertMatroskaForAVPlayer = true
        var casting = CastingSettings()
        casting.convertMatroskaForGoogleCast = false
        XCTAssertTrue(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(playback)).convertMatroskaForAVPlayer)
        XCTAssertFalse(try JSONDecoder().decode(CastingSettings.self, from: JSONEncoder().encode(casting)).convertMatroskaForGoogleCast)
    }

    // MARK: Cast compatibility

    private func matroska() -> StreamInfo {
        let stream = AddonStream(source: .url("https://cdn.test/film.mkv"), name: "Film", details: "1080p x264")
        return StreamAnalyzer.analyze(stream, capabilities: PlaybackCapabilities(mpvAvailable: true))
    }

    func testAMatroskaFileSentToGoogleCastIsJudgedOnTheHLSItBecomes() {
        let url = URL(string: "https://cdn.test/film.mkv")!
        let plain = CastCompatibility.evaluate(url: url, info: matroska(), target: .googleCast, delivery: .relay)
        XCTAssertTrue(plain.messages.contains { $0.contains("MKV") }, "as it is, the MKV warning stays")
        let converted = CastCompatibility.evaluate(url: url, info: matroska(), target: .googleCast, delivery: .relay, remuxed: true)
        XCTAssertFalse(converted.messages.contains { $0.contains("MKV") })
        XCTAssertFalse(converted.isBlocked)
    }

    func testAPlainHTTPMatroskaWithoutSecretsIsConvertedAndNotRefused() {
        let url = URL(string: "http://cdn.example.com/film.mkv")!
        let converted = CastCompatibility.evaluate(url: url, info: matroska(), target: .googleCast, delivery: .relay, remuxed: true)
        XCTAssertFalse(converted.isBlocked, "nothing secret travels: the conversion only reads the file the phone could play itself")
        let withHeaders = CastCompatibility.evaluate(url: url, info: matroska(), headers: ["Cookie": "x"], target: .googleCast,
                                                     delivery: .relay, remuxed: true)
        XCTAssertEqual(withHeaders, .blocked(CastRefusal.plainHTTPNeedsRelay.message), "headers over plain HTTP are still not forwarded")
    }

    func testAnAVIFileGoogleCastCannotReadStaysBlockedUnlessConverted() {
        let url = URL(string: "https://cdn.test/film.avi")!
        let stream = AddonStream(source: .url(url.absoluteString), name: "Film")
        let info = StreamAnalyzer.analyze(stream, capabilities: PlaybackCapabilities(mpvAvailable: true))
        XCTAssertTrue(CastCompatibility.evaluate(url: url, info: info, target: .googleCast, delivery: .relay).isBlocked)
    }
}
