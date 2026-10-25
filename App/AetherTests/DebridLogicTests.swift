import XCTest
import AetherCore
@testable import Aether

// The rules behind the TorBox screens, without views or network: which rows are torrents, in which order they are shown, what
// automatic choice may pick, how progress and errors are worded, and what the player does with a failure.

final class DebridStreamLogicTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 40)
    private let hashB = String(repeating: "b", count: 40)
    private let hashC = String(repeating: "c", count: 40)

    private func torrent(_ hash: String, _ name: String) -> AddonStream {
        return AddonStream(source: StreamSource.torrent(infoHash: hash, fileIndex: nil, trackers: []), name: name)
    }

    private func direct(_ name: String) -> AddonStream {
        return AddonStream(source: StreamSource.url("https://cdn.test/" + name + ".mp4"), name: name)
    }

    /// Ranked the way the picker ranks them when a TorBox key is saved: direct links first, torrents after them in the order given.
    private func ranked(_ streams: [AddonStream]) -> [RankedStream] {
        var preferences = StreamPreferences()
        preferences.capabilities = PlaybackCapabilities(mpvAvailable: false, debridAvailable: true)
        return StreamSelector.rank(streams, preferences: preferences)
    }

    private func names(_ list: [RankedStream]) -> [String] {
        return list.map { (item: RankedStream) -> String in return item.stream.name ?? "" }
    }

    func testOnlyTorrentsAreTorrents() {
        XCTAssertTrue(DebridStreamLogic.isTorrent(torrent(hashA, "T")))
        XCTAssertFalse(DebridStreamLogic.isTorrent(direct("D")))
        XCTAssertFalse(DebridStreamLogic.isTorrent(AddonStream(source: StreamSource.youtube("abc"))))
    }

    func testTheHashIsCanonicalisedAndAnInvalidOneIsRefused() {
        XCTAssertEqual(DebridStreamLogic.canonicalHash(of: torrent(String(repeating: "A", count: 40), "T")), hashA)
        // 32 characters of base32 are 20 bytes: here all zero.
        XCTAssertEqual(DebridStreamLogic.canonicalHash(of: torrent(String(repeating: "A", count: 32), "T")), String(repeating: "0", count: 40))
        XCTAssertNil(DebridStreamLogic.canonicalHash(of: torrent("not-a-hash", "T")))
        XCTAssertNil(DebridStreamLogic.canonicalHash(of: direct("D")))
    }

    func testTheCacheCheckAsksEachTorrentOnceInListOrder() {
        let list = ranked([torrent(hashB, "B"), direct("D"), torrent(hashA, "A"), torrent(String(repeating: "B", count: 40), "B again"),
                           torrent("broken", "Broken")])
        XCTAssertEqual(DebridStreamLogic.hashes(in: list), [hashB, hashA], "direct links, duplicates and invalid hashes are not asked")
    }

    func testTorrentsInCacheComeFirstAmongTorrentsAndDirectLinksKeepTheirPlace() {
        let list = ranked([direct("D1"), torrent(hashA, "A"), torrent(hashB, "B"), direct("D2"), torrent(hashC, "C")])
        XCTAssertEqual(names(list), ["D1", "D2", "A", "B", "C"], "precondition: direct links ahead of torrents")
        let reordered = DebridStreamLogic.cachedFirst(list, statuses: [hashC: DebridCacheStatus.cached, hashA: DebridCacheStatus.notCached])
        XCTAssertEqual(names(reordered), ["D1", "D2", "C", "A", "B"])
    }

    func testNothingMovesWhenNoTorrentIsKnownToBeCached() {
        let list = ranked([direct("D1"), torrent(hashA, "A"), torrent(hashB, "B")])
        let unchanged = DebridStreamLogic.cachedFirst(list, statuses: [hashA: DebridCacheStatus.notCached, hashB: DebridCacheStatus.unknown])
        XCTAssertEqual(names(unchanged), names(list))
        XCTAssertEqual(names(DebridStreamLogic.cachedFirst(list, statuses: [:])), names(list))
    }

    func testWithoutTorBoxAutomaticChoiceIsNotFiltered() {
        let list = ranked([direct("D"), torrent(hashA, "A")])
        let kept = DebridStreamLogic.autoSelectable(list, statuses: [:], debridConfigured: false)
        XCTAssertEqual(names(kept), names(list))
    }

    func testWithTorBoxAutomaticChoiceNeverPicksATorrentThatIsNotKnownToBeCached() {
        let list = ranked([direct("D"), torrent(hashA, "A"), torrent(hashB, "B"), torrent(hashC, "C"), torrent("broken", "X")])
        let statuses: [String: DebridCacheStatus] = [hashA: DebridCacheStatus.cached, hashB: DebridCacheStatus.notCached,
                                                    hashC: DebridCacheStatus.unknown]
        let kept = DebridStreamLogic.autoSelectable(list, statuses: statuses, debridConfigured: true)
        XCTAssertEqual(names(kept), ["D", "A"], "not cached, unknown (the check failed) and invalid torrents are left to the user")
        let none = DebridStreamLogic.autoSelectable(list, statuses: [:], debridConfigured: true)
        XCTAssertEqual(names(none), ["D"], "before the check has answered nothing is guessed")
    }

    func testTheFileMatcherGetsTheVideoIdOfAnEpisodeAndTheTitleIdOfAMovie() {
        let meta = MetaItem(id: "tt9400003", type: "series", name: "Serie")
        let episode = Video(id: "tt9400003:1:2", title: "Secondo")
        XCTAssertEqual(DebridStreamLogic.stremioID(meta: meta, video: episode), "tt9400003:1:2")
        let movie = MetaItem(id: "tt9400001", type: "movie", name: "Film")
        XCTAssertEqual(DebridStreamLogic.stremioID(meta: movie, video: nil), "tt9400001")
    }

    func testProgressReportsAreNumberedInOrder() {
        let relay = DebridProgressRelay()
        XCTAssertEqual(relay.next(), 1)
        XCTAssertEqual(relay.next(), 2)
        XCTAssertEqual(relay.next(), 3)
    }

    func testAPickerRowShowsOnlyWhatWasReported() {
        let waiting = DebridRowResolution(itemID: "x", mode: DebridMode.cachedOnly, progress: nil)
        XCTAssertEqual(waiting.message, "Controllo TorBox…")
        XCTAssertNil(waiting.detail)
        XCTAssertNil(waiting.determinateFraction)
        let confirmed = DebridRowResolution(itemID: "x", mode: DebridMode.startIfNeeded, progress: nil)
        XCTAssertEqual(confirmed.message, "Avvio il download su TorBox…")

        let adding = DebridRowResolution(itemID: "x", mode: DebridMode.startIfNeeded,
                                         progress: DebridProgress(phase: DebridProgress.Phase.adding, fraction: 0.5))
        XCTAssertNil(adding.determinateFraction, "a bar only while TorBox itself is downloading")

        let downloading = DebridRowResolution(itemID: "x", mode: DebridMode.startIfNeeded,
                                              progress: DebridProgress(phase: DebridProgress.Phase.downloading, fraction: 0.42,
                                                                       downloadSpeed: 15_000_000, etaSeconds: 90, state: "downloading"))
        XCTAssertEqual(downloading.determinateFraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertTrue(downloading.detail?.hasPrefix("42%") == true)
        let overshoot = DebridRowResolution(itemID: "x", mode: DebridMode.startIfNeeded,
                                            progress: DebridProgress(phase: DebridProgress.Phase.downloading, fraction: 7))
        XCTAssertEqual(overshoot.determinateFraction ?? -1, 1, accuracy: 0.0001)
    }
}

final class DebridPresentationTests: XCTestCase {
    func testPercentIsClampedAndMissingWhenUnknown() {
        XCTAssertEqual(DebridFormat.percent(0.424), "42%")
        XCTAssertEqual(DebridFormat.percent(1.4), "100%")
        XCTAssertEqual(DebridFormat.percent(-1), "0%")
        XCTAssertNil(DebridFormat.percent(nil))
        XCTAssertNil(DebridFormat.percent(Double.nan))
    }

    func testSpeedIsShownOnlyWhenThereIsOne() {
        XCTAssertTrue(DebridFormat.speed(15_000_000)?.hasSuffix("/s") == true)
        XCTAssertNil(DebridFormat.speed(0))
        XCTAssertNil(DebridFormat.speed(nil))
    }

    func testTimeLeftIsRoundedUpToTheNextMinute() {
        XCTAssertEqual(DebridFormat.eta(12), "12 s")
        XCTAssertEqual(DebridFormat.eta(59), "59 s")
        XCTAssertEqual(DebridFormat.eta(60), "1 min")
        XCTAssertEqual(DebridFormat.eta(61), "2 min")
        XCTAssertEqual(DebridFormat.eta(3600), "1 h 00 min")
        XCTAssertEqual(DebridFormat.eta(3661), "1 h 02 min")
        XCTAssertNil(DebridFormat.eta(0))
        XCTAssertNil(DebridFormat.eta(nil))
    }

    func testTheDetailLineHasOnlyWhatTorBoxSaid() {
        let full = DebridProgress(phase: DebridProgress.Phase.downloading, fraction: 0.42, downloadSpeed: 15_000_000, etaSeconds: 90,
                                  state: "downloading")
        let line = DebridFormat.detail(for: full)
        XCTAssertTrue(line?.hasPrefix("42%") == true)
        XCTAssertTrue(line?.contains("ancora 2 min") == true)

        let queued = DebridProgress(phase: DebridProgress.Phase.queued, fraction: 0.3)
        XCTAssertNil(DebridFormat.detail(for: queued), "a percentage that does not describe a download is not shown")
        XCTAssertNil(DebridFormat.detail(for: DebridProgress(phase: DebridProgress.Phase.downloading)))
        XCTAssertNil(DebridFormat.detail(for: nil))
    }

    func testTheStatusLineAddsThePercentageOnlyWhileDownloading() {
        let downloading = DebridProgress(phase: DebridProgress.Phase.downloading, fraction: 0.5, state: "downloading")
        XCTAssertTrue(DebridFormat.statusLine(for: downloading).hasSuffix("50%"))
        let adding = DebridProgress(phase: DebridProgress.Phase.adding, fraction: 0.5)
        XCTAssertEqual(DebridFormat.statusLine(for: adding), adding.message)
    }

    func testAnUnknownCacheStatusIsNeverShownAsNotInCache() {
        XCTAssertEqual(DebridCacheBadge.badge(status: DebridCacheStatus.cached, isChecking: true), DebridCacheBadge.cached)
        XCTAssertEqual(DebridCacheBadge.badge(status: DebridCacheStatus.notCached, isChecking: false), DebridCacheBadge.notCached)
        XCTAssertNil(DebridCacheBadge.badge(status: DebridCacheStatus.unknown, isChecking: false))
        XCTAssertNil(DebridCacheBadge.badge(status: nil, isChecking: false))
        XCTAssertEqual(DebridCacheBadge.badge(status: nil, isChecking: true), DebridCacheBadge.checking)
        XCTAssertEqual(DebridCacheBadge.badge(status: DebridCacheStatus.unknown, isChecking: true), DebridCacheBadge.checking)
    }

    func testTheBadgeWordingIsTheOneTheOwnerAsked() {
        XCTAssertEqual(DebridCacheBadge.cached.label, "In cache")
        XCTAssertEqual(DebridCacheBadge.notCached.label, "Non in cache")
        XCTAssertEqual(DebridCacheBadge.checking.label, "Verifica…")
        XCTAssertEqual(DebridUserText.downloadConfirmationTitle, "Avvia il download su TorBox?")
        XCTAssertTrue(DebridUserText.configureHint.contains("Impostazioni › Servizi"))
        XCTAssertTrue(DebridUserText.downloadConfirmationMessage.contains("non cancella mai"), "the promise of never deleting is part of the question")
    }

    func testErrorsPointTheUserToTheSettingsWhereTheyCanBeFixed() {
        XCTAssertTrue(DebridErrorText.message(for: DebridError.notConfigured).contains(DebridErrorText.settingsPath))
        XCTAssertTrue(DebridErrorText.message(for: DebridError.authFailed).contains(DebridErrorText.settingsPath))
        XCTAssertEqual(DebridErrorText.message(for: DebridError.timeout), DebridError.timeout.message)
        XCTAssertEqual(DebridErrorText.describe(CancellationError()), "Operazione annullata.")
        let foreign = NSError(domain: "SomeDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "https://x.test/?token=abc123abc123abc123abc123abc123abc"])
        XCTAssertFalse(DebridErrorText.describe(foreign).contains("abc123"), "the text of a foreign error is never shown")
    }

    func testProviderSpecificErrorsNeverMislabelRealDebridAsTorBox() {
        let realDebridAuth = DebridErrorText.message(for: .authFailed, provider: .realdebrid)
        XCTAssertTrue(realDebridAuth.contains("Real-Debrid"))
        XCTAssertFalse(realDebridAuth.contains("TorBox"))
        XCTAssertTrue(realDebridAuth.contains(DebridErrorText.settingsPath))

        let realDebridCache = DebridErrorText.message(for: .notCached, provider: .realdebrid)
        XCTAssertTrue(realDebridCache.contains("Real-Debrid"))
        XCTAssertFalse(realDebridCache.contains("TorBox"))
    }

    func testTheConnectionReasonsAreSpecific() {
        XCTAssertTrue(DebridErrorText.connectionMessage(for: DebridError.authFailed).contains("Chiave non valida"))
        XCTAssertTrue(DebridErrorText.connectionMessage(for: DebridError.planRestricted).contains("piano"))
        XCTAssertTrue(DebridErrorText.connectionMessage(for: DebridError.rateLimited(retryAfter: 30)).contains("30"))
        XCTAssertTrue(DebridErrorText.connectionMessage(for: DebridError.serviceUnavailable(statusCode: 502)).contains("502"))
        XCTAssertTrue(DebridErrorText.connectionMessage(for: DebridError.unreachable).contains("raggiungere"))
        XCTAssertFalse(DebridErrorText.connectionMessage(forAny: NSError(domain: "x", code: 1)).isEmpty)
    }
}

final class DebridPlaybackFailureTests: XCTestCase {
    func testConnectivityProblemsKeepTheirOwnKindSoThatRecoveryStillApplies() {
        XCTAssertEqual(DebridPlayback.failure(for: DebridError.offline).kind, PlaybackFailureKind.offline)
        XCTAssertEqual(DebridPlayback.failure(for: DebridError.timeout).kind, PlaybackFailureKind.timeout)
        XCTAssertEqual(DebridPlayback.failure(for: DebridError.unreachable).kind, PlaybackFailureKind.unreachable)
        XCTAssertTrue(DebridPlayback.failure(for: DebridError.offline).isNetworkRelated)
    }

    func testEverythingElseIsExplainedInItalianInsideAnUnknownFailure() {
        let notCached = DebridPlayback.failure(for: DebridError.notCached)
        XCTAssertEqual(notCached.kind, PlaybackFailureKind.unknown)
        XCTAssertEqual(notCached.detail, DebridPlayback.notCachedInPlayer)
        XCTAssertTrue(notCached.message.contains("cache di TorBox"))

        let choice = DebridPlayback.failure(for: DebridError.noMatchingFile(candidates: []))
        XCTAssertEqual(choice.detail, DebridPlayback.fileChoiceInPlayer)

        let refused = DebridPlayback.failure(for: DebridError.authFailed)
        XCTAssertTrue(refused.detail.contains(DebridErrorText.settingsPath))

        let limited = DebridPlayback.failure(for: DebridError.rateLimited(retryAfter: nil))
        XCTAssertEqual(limited.detail, DebridError.rateLimited(retryAfter: nil).message)
        XCTAssertFalse(DebridPlayback.failure(forAny: NSError(domain: "x", code: 1)).detail.isEmpty)
    }

    func testTheAddressOfAFileNeverSurvivesInAFailure() {
        let leaked = PlaybackFailure(kind: PlaybackFailureKind.unknown,
                                     detail: "Impossibile aprire https://store-1.cdn.example.com/dl/file.mkv?token=0123456789abcdef0123456789abcdef0123 per errore")
        let safe = DebridPlayback.redacted(leaked)
        XCTAssertEqual(safe.kind, PlaybackFailureKind.unknown)
        XCTAssertFalse(safe.detail.contains("0123456789abcdef"))
        XCTAssertFalse(safe.detail.contains("file.mkv"))
        XCTAssertFalse(safe.detail.contains("token="))
        XCTAssertTrue(safe.detail.contains("cdn.example.com"), "the host stays: it helps to understand what failed")
    }

    func testOnlyAnAddressThatTheCDNRefusedIsThrownAway() {
        XCTAssertTrue(DebridPlayback.invalidatesResolvedLink(PlaybackFailure(kind: PlaybackFailureKind.forbidden, detail: "")))
        XCTAssertTrue(DebridPlayback.invalidatesResolvedLink(PlaybackFailure(kind: PlaybackFailureKind.notFound, detail: "")))
        XCTAssertFalse(DebridPlayback.invalidatesResolvedLink(PlaybackFailure(kind: PlaybackFailureKind.timeout, detail: "")))
        XCTAssertFalse(DebridPlayback.invalidatesResolvedLink(PlaybackFailure(kind: PlaybackFailureKind.offline, detail: "")))
        XCTAssertFalse(DebridPlayback.invalidatesResolvedLink(PlaybackFailure(kind: PlaybackFailureKind.unknown, detail: "")))
    }
}
