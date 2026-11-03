import XCTest
@testable import AetherCore

final class ExtrasSettingsTests: XCTestCase {
    func testDefaultsAndOldSettingsDecode() throws {
        let fresh = ExtrasSettings()
        XCTAssertTrue(fresh.checkUpdates)
        XCTAssertTrue(fresh.prefetchNextLink)
        XCTAssertFalse(fresh.episodeNotifications)
        XCTAssertFalse(fresh.translateSubtitles)
        XCTAssertTrue(fresh.posterTint)
        let old = try JSONDecoder().decode(AdvancedSettings.self, from: Data("{\"verboseLogging\":true}".utf8))
        XCTAssertTrue(old.verboseLogging)
        XCTAssertEqual(old.extras, ExtrasSettings())
    }

    func testTheHourIsKeptInRange() throws {
        let decoded = try JSONDecoder().decode(ExtrasSettings.self, from: Data("{\"episodeNotificationHour\":99}".utf8))
        XCTAssertEqual(decoded.episodeNotificationHour, 23)
    }
}

final class DevbuildFeedTests: XCTestCase {
    private func source(_ builds: [(String, String)]) -> Data {
        let versions = builds.map { "{\"version\":\"1.5\",\"buildVersion\":\"\($0.0)\",\"date\":\"2026-11-03T10:00:00Z\",\"downloadURL\":\"\($0.1)\",\"localizedDescription\":\"devbuild · build \($0.0)\\n- Prima\\n- Seconda\"}" }
        return Data("{\"apps\":[{\"versions\":[\(versions.joined(separator: ","))]}]}".utf8)
    }

    func testTheNewestBuildWins() {
        let data = source([("135", "https://github.com/x/y/releases/download/devbuilds/a.ipa"), ("137", "https://github.com/x/y/releases/download/devbuilds/b.ipa")])
        let latest = DevbuildFeed.latest(from: data)
        XCTAssertEqual(latest?.build, 137)
        XCTAssertTrue(DevbuildFeed.isNewer(latest!, than: 135))
        XCTAssertFalse(DevbuildFeed.isNewer(latest!, than: 137))
        XCTAssertFalse(DevbuildFeed.isNewer(latest!, than: 0), "an unknown installed build never claims an update")
    }

    func testAnIpaOutsideGitHubIsIgnored() {
        XCTAssertNil(DevbuildFeed.latest(from: source([("140", "https://evil.example/a.ipa")])))
        XCTAssertNil(DevbuildFeed.latest(from: source([("140", "http://github.com/a.ipa")])))
        XCTAssertNil(DevbuildFeed.latest(from: Data("not json".utf8)))
    }

    func testNotesBecomeLinesAndTheInstallAddressCarriesTheIpa() {
        XCTAssertEqual(DevbuildFeed.noteLines("devbuild · build 1\n- Prima\n* Seconda\n\n• Terza"), ["devbuild · build 1", "Prima", "Seconda", "Terza"])
        let ipa = URL(string: "https://github.com/x/y/releases/download/devbuilds/a.ipa")!
        let url = DevbuildFeed.sideStoreInstallURL(for: ipa)
        XCTAssertEqual(url?.scheme, "sidestore")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, ipa.absoluteString)
    }
}

final class EpisodeAlertTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func item(_ name: String, season: Int, episode: Int, aired: String) -> TraktTitle {
        var t = TraktTitle(kind: .show, title: name, year: nil, imdb: nil, tmdb: nil, tvdb: nil, note: nil, progress: nil,
                           season: season, episode: episode, episodeTitle: "Finale")
        t.firstAired = aired
        return t
    }

    func testAnUpcomingEpisodeIsAnnouncedOnItsDayAtTheChosenHour() {
        let now = ISO8601DateFormatter().date(from: "2026-11-03T08:00:00Z")!
        let alerts = EpisodeAlertPlanner.plan([item("Show", season: 2, episode: 5, aired: "2026-11-05T01:00:00.000Z")], now: now, hour: 18, calendar: utc)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].title, "Show")
        XCTAssertEqual(alerts[0].body, "S02E05 · Finale esce oggi.")
        XCTAssertEqual(utc.component(.hour, from: alerts[0].fire), 18)
        XCTAssertEqual(utc.component(.day, from: alerts[0].fire), 5)
    }

    func testPastDuplicatesAndTheLimitAreHandled() {
        let now = ISO8601DateFormatter().date(from: "2026-11-03T08:00:00Z")!
        let items = [item("A", season: 1, episode: 1, aired: "2026-11-01T01:00:00.000Z"),
                     item("B", season: 1, episode: 1, aired: "2026-11-06T01:00:00.000Z"),
                     item("B", season: 1, episode: 1, aired: "2026-11-06T01:00:00.000Z"),
                     item("C", season: 1, episode: 2, aired: "2026-11-07T01:00:00.000Z")]
        XCTAssertEqual(EpisodeAlertPlanner.plan(items, now: now, hour: 9, calendar: utc).map { $0.title }, ["B", "C"])
        XCTAssertEqual(EpisodeAlertPlanner.plan(items, now: now, hour: 9, limit: 1, calendar: utc).count, 1)
    }

    func testWhenTheHourHasPassedItFiresAtTheAiringTime() {
        let now = ISO8601DateFormatter().date(from: "2026-11-05T19:00:00Z")!
        let alerts = EpisodeAlertPlanner.plan([item("Late", season: 1, episode: 3, aired: "2026-11-05T22:30:00Z")], now: now, hour: 18, calendar: utc)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].fire, ISO8601DateFormatter().date(from: "2026-11-05T22:30:00Z"))
    }
}

final class PosterPaletteTests: XCTestCase {
    private func image(_ pixels: [(UInt8, UInt8, UInt8)]) -> [UInt8] { return pixels.flatMap { [$0.0, $0.1, $0.2, 255] } }

    func testARedPosterGivesARedBase() {
        let palette = PosterPaletteExtractor.palette(rgba: image(Array(repeating: (200, 20, 30), count: 50)))
        XCTAssertNotNil(palette)
        XCTAssertGreaterThan(palette!.base.red, palette!.base.green)
        XCTAssertGreaterThan(palette!.base.red, palette!.base.blue)
        XCTAssertLessThan(max(palette!.backdrop.red, palette!.backdrop.green, palette!.backdrop.blue), 0.3)
        XCTAssertGreaterThan(max(palette!.accent.red, palette!.accent.green, palette!.accent.blue), 0.8)
    }

    func testBlackBordersAreNotTheColourOfThePoster() {
        var pixels = Array(repeating: (UInt8(0), UInt8(0), UInt8(0)), count: 80)
        pixels += Array(repeating: (UInt8(20), UInt8(60), UInt8(220)), count: 20)
        let palette = PosterPaletteExtractor.palette(rgba: image(pixels))
        XCTAssertGreaterThan(palette!.base.blue, 0.7)
    }

    func testAGreyPosterStillGivesAColourAndNothingGivesNil() {
        XCTAssertNotNil(PosterPaletteExtractor.palette(rgba: image(Array(repeating: (120, 120, 120), count: 10))))
        XCTAssertNil(PosterPaletteExtractor.palette(rgba: []))
    }
}

final class SubtitleTranslationPlanTests: XCTestCase {
    private func cues(_ texts: [String]) -> [SubtitleCue] { return texts.enumerated().map { SubtitleCue(start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element) } }

    func testBatchesRespectBothLimits() {
        let list = cues((0..<10).map { _ in String(repeating: "a", count: 100) })
        XCTAssertEqual(SubtitleTranslationPlan.batches(for: list, maxItems: 4, maxCharacters: 10_000).map { $0.count }, [4, 4, 2])
        XCTAssertEqual(SubtitleTranslationPlan.batches(for: list, maxItems: 100, maxCharacters: 250).map { $0.count }, [2, 2, 2, 2, 2])
        XCTAssertTrue(SubtitleTranslationPlan.batches(for: [], maxItems: 4).isEmpty)
    }

    func testStylingTagsAreRemovedBeforeTranslating() {
        XCTAssertEqual(SubtitleTranslationPlan.plainText("{\\an8}<i>Hello</i> there"), "Hello there")
        XCTAssertEqual(SubtitleTranslationPlan.plainText("Plain"), "Plain")
    }

    func testTranslationsReplaceOnlyWhereThereIsOne() {
        let out = SubtitleTranslationPlan.apply([0: "Ciao", 2: "  "], to: cues(["Hello", "Bye", "Empty"]))
        XCTAssertEqual(out.map { $0.text }, ["Ciao", "Bye", "Empty"])
        XCTAssertEqual(out[0].start, 0)
    }

    func testOfferedUnlessAlreadyInTheViewersLanguage() {
        XCTAssertFalse(SubtitleTranslationPlan.shouldOffer(subtitleLanguage: "it", target: "it"))
        XCTAssertFalse(SubtitleTranslationPlan.shouldOffer(subtitleLanguage: "ita", target: "it"))
        XCTAssertTrue(SubtitleTranslationPlan.shouldOffer(subtitleLanguage: "en", target: "it"))
        XCTAssertTrue(SubtitleTranslationPlan.shouldOffer(subtitleLanguage: nil, target: "it"))
    }
}
