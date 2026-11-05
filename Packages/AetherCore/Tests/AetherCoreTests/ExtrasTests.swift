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

final class SurfacesTests: XCTestCase {
    private func progress(_ meta: String, _ video: String, position: Double, duration: Double = 3600, at: TimeInterval, season: Int? = nil, episode: Int? = nil) -> PlaybackProgress {
        PlaybackProgress(metaID: meta, videoID: video, type: season == nil ? "movie" : "series", title: "T-" + meta,
                         episodeTitle: season == nil ? nil : "Pilota", season: season, episode: episode,
                         position: position, duration: duration, updatedAt: Date(timeIntervalSince1970: at))
    }

    func testTheWidgetListsUnfinishedTitlesOncePerTitleNewestFirst() {
        let history = [progress("a", "a", position: 1800, at: 100),
                       progress("b", "b:1:1", position: 600, at: 300, season: 1, episode: 1),
                       progress("b", "b:1:2", position: 900, at: 400, season: 1, episode: 2),
                       progress("c", "c", position: 3500, at: 500),     // almost finished
                       progress("d", "d", position: 5, at: 600)]        // just started
        let items = ContinueWatchingPlanner.items(from: history)
        XCTAssertEqual(items.map { $0.metaID }, ["b", "a"])
        XCTAssertEqual(items[0].videoID, "b:1:2")
        XCTAssertEqual(items[0].subtitle, "S1E2 · Pilota")
        XCTAssertEqual(items[1].progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(ContinueWatchingPlanner.items(from: history, limit: 1).count, 1)
    }

    func testTheLiveActivityFollowsTheRunningDownloads() {
        func item(_ title: String, state: DownloadState, written: Int64, total: Int64) -> DownloadItem {
            DownloadItem(metaID: title, videoID: nil, type: "movie", title: title, sourceURL: "https://x.test/a.mp4", state: state, bytesWritten: written, totalBytes: total)
        }
        XCTAssertNil(DownloadActivityPlanner.summary([item("A", state: .queued, written: 0, total: 100), item("B", state: .completed, written: 100, total: 100)]))
        let one = DownloadActivityPlanner.summary([item("A", state: .downloading, written: 25, total: 100)])
        XCTAssertEqual(one?.title, "A")
        XCTAssertEqual(one?.fraction ?? 0, 0.25, accuracy: 0.001)
        let two = DownloadActivityPlanner.summary([item("A", state: .downloading, written: 50, total: 100), item("B", state: .downloading, written: 150, total: 300)])
        XCTAssertEqual(two?.title, "2 download")
        XCTAssertEqual(two?.fraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(two?.count, 2)
    }

    func testFollowingAFriendDoesNotMakeEveryoneJump() {
        let remote = PlaybackSyncMessage(isPlaying: true, position: 100, sentAt: 1000)
        XCTAssertTrue(PlaybackSyncPlanner.actions(localPlaying: true, localPosition: 101, remote: remote, now: 1000.5).isEmpty)
        XCTAssertEqual(PlaybackSyncPlanner.actions(localPlaying: false, localPosition: 101, remote: remote, now: 1000.5), [.play])
        XCTAssertEqual(PlaybackSyncPlanner.actions(localPlaying: true, localPosition: 50, remote: remote, now: 1001), [.seek(101)])
    }

    func testAPauseSeeksExactlyAndTheLagIsCapped() {
        let paused = PlaybackSyncMessage(isPlaying: false, position: 200, sentAt: 1000)
        XCTAssertEqual(PlaybackSyncPlanner.actions(localPlaying: true, localPosition: 200.2, remote: paused, now: 1004), [.pause])
        XCTAssertEqual(PlaybackSyncPlanner.actions(localPlaying: true, localPosition: 203, remote: paused, now: 1004), [.seek(200), .pause])
        let playing = PlaybackSyncMessage(isPlaying: true, position: 10, sentAt: 0)      // clocks that disagree by hours
        XCTAssertEqual(PlaybackSyncPlanner.actions(localPlaying: true, localPosition: 0, remote: playing, now: 50_000), [.seek(13)])
    }

    func testTheNewSwitchesAreOnByDefault() {
        let fresh = ExtrasSettings()
        XCTAssertTrue(fresh.widget && fresh.downloadLiveActivity && fresh.downloadNotifications && fresh.sharePlay)
    }
}

final class PauseScreenSettingsTests: XCTestCase {
    func testTheDelayIsKeptInRangeAndOnByDefault() throws {
        XCTAssertTrue(ExtrasSettings().pauseScreen)
        XCTAssertEqual(ExtrasSettings().pauseScreenSeconds, 5)
        XCTAssertEqual(try JSONDecoder().decode(ExtrasSettings.self, from: Data("{\"pauseScreenSeconds\":1}".utf8)).pauseScreenSeconds, 3)
        XCTAssertEqual(try JSONDecoder().decode(ExtrasSettings.self, from: Data("{\"pauseScreenSeconds\":99}".utf8)).pauseScreenSeconds, 15)
    }
}

final class ViewingStatsTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func row(_ meta: String, _ video: String, position: Double, duration: Double, daysAgo: Int, now: Date, completed: Bool = false, season: Int? = nil, episode: Int? = nil) -> PlaybackProgress {
        PlaybackProgress(metaID: meta, videoID: video, type: season == nil ? "movie" : "series", title: meta, season: season, episode: episode,
                         position: position, duration: duration, updatedAt: now.addingTimeInterval(-Double(daysAgo) * 86_400), isCompleted: completed)
    }

    func testTotalsDaysStreakAndKinds() {
        let now = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!
        let history = [row("a", "a", position: 600, duration: 6000, daysAgo: 0, now: now),
                       row("b", "b", position: 100, duration: 3000, daysAgo: 1, now: now, completed: true),
                       row("c", "c:1:1", position: 1200, duration: 2400, daysAgo: 2, now: now, season: 1, episode: 1),
                       row("d", "d", position: 900, duration: 5400, daysAgo: 20, now: now)]
        let stats = ViewingStatsPlanner.compute(history, now: now, calendar: utc)
        XCTAssertEqual(stats.totalSeconds, 600 + 3000 + 1200 + 900, accuracy: 0.1)
        XCTAssertEqual(stats.weekSeconds, 600 + 3000 + 1200, accuracy: 0.1)
        XCTAssertEqual(stats.days, [0, 0, 0, 0, 1200, 3000, 600])
        XCTAssertEqual(stats.streak, 3)
        XCTAssertEqual(stats.titles, 4)
        XCTAssertEqual(stats.completed, 1)
        XCTAssertEqual(stats.films, 3)
        XCTAssertEqual(stats.episodes, 1)
    }

    func testTheStreakSurvivesAnEmptyTodayAndBreaksOnAGap() {
        let now = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!
        let yesterdayOnly = [row("a", "a", position: 60, duration: 600, daysAgo: 1, now: now), row("b", "b", position: 60, duration: 600, daysAgo: 2, now: now)]
        XCTAssertEqual(ViewingStatsPlanner.compute(yesterdayOnly, now: now, calendar: utc).streak, 2)
        let gap = [row("a", "a", position: 60, duration: 600, daysAgo: 0, now: now), row("b", "b", position: 60, duration: 600, daysAgo: 2, now: now)]
        XCTAssertEqual(ViewingStatsPlanner.compute(gap, now: now, calendar: utc).streak, 1)
        XCTAssertEqual(ViewingStatsPlanner.compute([], now: now, calendar: utc).streak, 0)
    }
}
