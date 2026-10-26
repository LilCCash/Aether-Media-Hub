import XCTest
@testable import AetherCore

final class StreamAnalyzerTests: XCTestCase {
    private func stream(_ url: String, name: String? = nil, details: String? = nil,
                        hints: StreamBehaviorHints = StreamBehaviorHints()) -> AddonStream {
        return AddonStream(source: .url(url), name: name, details: details, behaviorHints: hints)
    }

    func testParsesQualityCodecHDRAudioLanguageAndSize() {
        let info = StreamAnalyzer.analyze(stream("https://cdn.test/a.mp4", name: "Addon 4K",
                                                 details: "Movie.2160p.UHD.BluRay.x265.HDR10.DV.Atmos.ITA.ENG 12.5 GB"))
        XCTAssertEqual(info.quality, .uhd2160)
        XCTAssertEqual(info.codec, .hevc)
        XCTAssertEqual(info.hdr, [.dolbyVision, .hdr10])
        XCTAssertTrue(info.audio.contains(.atmos))
        XCTAssertEqual(info.languages, ["en", "it"])
        XCTAssertEqual(info.sizeBytes, Int64(12.5 * 1_073_741_824))
        XCTAssertEqual(info.sizeLabel, "12.5 GB")
        XCTAssertEqual(info.badges.prefix(3), ["4K", "HEVC", "Dolby Vision (nel nome)"], "name-derived HDR must be labelled as unverified")
    }

    func testTheFormatLabelNamesTheFileFormat() {
        let cases: [(String, String)] = [("mkv", "MKV"), ("avi", "AVI"), ("mp4", "MP4"), ("mov", "MOV"), ("m4v", "M4V"), ("ts", "TS"), ("webm", "WEBM")]
        for (ext, label) in cases {
            XCTAssertEqual(StreamAnalyzer.analyze(stream("https://cdn.test/file.\(ext)?sig=1")).formatLabel, label, ext)
        }
        XCTAssertEqual(StreamAnalyzer.analyze(stream("https://cdn.test/master.m3u8?token=1")).formatLabel, "HLS", "HLS is shown as HLS, not as m3u8")
        XCTAssertEqual(StreamAnalyzer.analyze(stream("https://cdn.test/manifest.mpd")).formatLabel, "DASH")
    }

    func testTheFormatLabelFallsBackToTheDeclaredFileName() {
        let hints = StreamBehaviorHints(filename: "Movie.2160p.x265.mkv")
        XCTAssertEqual(StreamAnalyzer.analyze(stream("https://cdn.test/download/123", hints: hints)).formatLabel, "MKV")
        let torrent = AddonStream(source: .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: nil, trackers: []),
                                  name: "T", details: nil, behaviorHints: hints)
        XCTAssertEqual(StreamAnalyzer.analyze(torrent).formatLabel, "MKV", "a torrent's declared file name says what the file is")
    }

    func testTheFormatLabelIsAbsentWhenTheFormatIsNotKnown() {
        XCTAssertNil(StreamAnalyzer.analyze(stream("https://cdn.test/stream/123")).formatLabel)
        XCTAssertNil(StreamAnalyzer.analyze(stream("https://cdn.test/play.php")).formatLabel, "an extension that is not a video format says nothing")
        XCTAssertNil(StreamAnalyzer.analyze(stream("https://cdn.test/x", hints: StreamBehaviorHints(filename: "Movie.2160p"))).formatLabel,
                     "a quality tag after the last dot is not an extension")
        let torrent = AddonStream(source: .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: nil, trackers: []),
                                  name: "T", details: nil, behaviorHints: StreamBehaviorHints())
        XCTAssertNil(StreamAnalyzer.analyze(torrent).formatLabel)
        XCTAssertNil(StreamAnalyzer.analyze(AddonStream(source: .external("https://x.test"), name: "E", details: nil,
                                                        behaviorHints: StreamBehaviorHints(filename: "a.mkv"))).formatLabel)
    }

    func testTheFormatIsNotPartOfTheBadgesSoTheirOrderIsUnchanged() {
        let info = StreamAnalyzer.analyze(stream("https://cdn.test/a.mkv", details: "2160p x265 DV"))
        XCTAssertFalse(info.badges.contains("MKV"))
        XCTAssertEqual(info.badges.prefix(3), ["4K", "HEVC", "Dolby Vision (nel nome)"])
    }

    func testDolbyVisionDoesNotImplyDolbyDigitalAudio() {
        let info = StreamAnalyzer.analyze(stream("https://cdn.test/a.mp4", details: "1080p Dolby Vision HEVC"))
        XCTAssertFalse(info.audio.contains(.ac3))
    }

    func testFlagEmojiLanguageAndMulti() {
        let info = StreamAnalyzer.analyze(stream("https://cdn.test/a.mp4", name: "🇮🇹 🇬🇧 MULTI 720p"))
        XCTAssertEqual(info.languages, ["en", "it", "multi"])
        XCTAssertEqual(info.quality, .hd720)
    }

    func testNativelySupportedContainers() {
        for ext in ["mp4", "m4v", "mov"] {
            let info = StreamAnalyzer.analyze(stream("https://cdn.test/file.\(ext)"))
            XCTAssertEqual(info.support, .supported, ext)
            XCTAssertEqual(info.kind, .file)
        }
        let hls = StreamAnalyzer.analyze(stream("https://cdn.test/master.m3u8?token=1"))
        XCTAssertEqual(hls.support, .supported)
        XCTAssertEqual(hls.kind, .hls)
    }

    func testUnsupportedContainersAreDetectedUpFront() {
        for ext in ["mkv", "avi", "webm", "wmv", "flv", "ts"] {
            let info = StreamAnalyzer.analyze(stream("https://cdn.test/file.\(ext)"))
            XCTAssertEqual(info.support, .unsupported(.container(ext)), ext)
            XCTAssertFalse(info.support.isPlayable)
        }
        XCTAssertEqual(StreamAnalyzer.analyze(stream("https://cdn.test/manifest.mpd")).support, .unsupported(.dash))
    }

    func testMatroskaAndFriendsArePlayableWhenTheMPVEngineIsPresent() {
        let withMPV = PlaybackCapabilities(mpvAvailable: true)
        for ext in ["mkv", "avi", "webm", "wmv", "flv", "ts", "m2ts"] {
            let info = StreamAnalyzer.analyze(stream("https://cdn.test/file.\(ext)"), capabilities: withMPV)
            XCTAssertEqual(info.support, .supported, ext)
            XCTAssertEqual(info.requiredEngine, .mpv, ext)
        }
        let mp4 = StreamAnalyzer.analyze(stream("https://cdn.test/file.mp4"), capabilities: withMPV)
        XCTAssertNil(mp4.requiredEngine, "native containers keep the default engine")
        XCTAssertEqual(StreamAnalyzer.analyze(stream("https://cdn.test/manifest.mpd"), capabilities: withMPV).support, .unsupported(.dash),
                       "DASH stays unsupported until it has been tested")
        XCTAssertEqual(StreamAnalyzer.analyze(AddonStream(source: .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: nil, trackers: [])), capabilities: withMPV).support,
                       .unsupported(.torrent), "MPV does not resolve torrents")
    }

    func testFilenameHintDecidesWhenTheURLHasNoExtension() {
        let hinted = StreamAnalyzer.analyze(stream("https://debrid.test/dl/abc123",
                                                   hints: StreamBehaviorHints(filename: "Movie.2020.mkv")))
        XCTAssertEqual(hinted.support, .unsupported(.container("mkv")))
        let mp4 = StreamAnalyzer.analyze(stream("https://debrid.test/dl/abc123",
                                                hints: StreamBehaviorHints(filename: "Movie.2020.mp4")))
        XCTAssertEqual(mp4.support, .supported)
        let unknown = StreamAnalyzer.analyze(stream("https://debrid.test/dl/abc123"))
        XCTAssertEqual(unknown.support, .unknown)
        XCTAssertTrue(unknown.support.isPlayable, "unknown formats are tried, not refused")
    }

    func testNonHTTPAndLocalServerSources() {
        XCTAssertEqual(StreamAnalyzer.analyze(stream("rtmp://live.test/app/stream")).support, .unsupported(.transport("rtmp")))
        XCTAssertEqual(StreamAnalyzer.analyze(stream("ftp://files.test/a.mp4")).support, .unsupported(.transport("ftp")))
        XCTAssertEqual(StreamAnalyzer.analyze(stream("http://127.0.0.1:11470/abc/0")).support, .unsupported(.localStreamingServer))
        XCTAssertEqual(StreamAnalyzer.analyze(AddonStream(source: .youtube("x"))).support, .unsupported(.youtube))
        XCTAssertEqual(StreamAnalyzer.analyze(AddonStream(source: .external("https://x.test"))).support, .unsupported(.externalPage))
        XCTAssertEqual(StreamAnalyzer.analyze(AddonStream(source: .archive(kind: "rar"))).support, .unsupported(.archive("rar")))
        XCTAssertEqual(StreamAnalyzer.analyze(AddonStream(source: .unknown)).support, .unsupported(.invalidURL))
    }

    func testTorrentNeedsAnExternalServer() {
        let torrent = AddonStream(source: .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: 2, trackers: ["tracker:udp://t.test:80"]))
        XCTAssertEqual(StreamAnalyzer.analyze(torrent).support, .unsupported(.torrent))
        let withServer = StreamAnalyzer.analyze(torrent, streamingServer: URL(string: "http://192.168.1.5:11470")!)
        XCTAssertEqual(withServer.support, .unknown)
        XCTAssertFalse(withServer.warnings.isEmpty, "experimental path is flagged")
    }

    func testTorrentURLMappingMatchesCoreShape() {
        let torrent = AddonStream(source: .torrent(infoHash: "0123456789ABCDEF0123456789abcdef01234567", fileIndex: nil, trackers: ["udp://a.test:80", "http://b.test/announce"]))
        let url = StreamResolver.playbackURL(for: torrent, streamingServer: URL(string: "http://192.168.1.5:11470/")!)
        XCTAssertEqual(url?.path, "/0123456789abcdef0123456789abcdef01234567/-1", "no file index means -1 (largest file)")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "tr" }.count, 2)
        XCTAssertNil(StreamResolver.playbackURL(for: torrent, streamingServer: nil))
        let bad = AddonStream(source: .torrent(infoHash: "zz", fileIndex: 0, trackers: []))
        XCTAssertNil(StreamResolver.playbackURL(for: bad, streamingServer: URL(string: "http://s:1")!), "invalid info hashes are refused")
        XCTAssertEqual(StreamResolver.playbackURL(for: stream("https://cdn.test/a.mp4"), streamingServer: nil)?.absoluteString, "https://cdn.test/a.mp4")
        XCTAssertNil(StreamResolver.playbackURL(for: stream("javascript:alert(1)"), streamingServer: nil))
    }

    func testWarningsForAudioAndCodecs() {
        let dts = StreamAnalyzer.analyze(stream("https://cdn.test/a.mp4", details: "1080p DTS-HD x264"))
        XCTAssertTrue(dts.warnings.contains(where: { $0.contains("DTS") }))
        let withFallback = StreamAnalyzer.analyze(stream("https://cdn.test/a.mp4", details: "1080p DTS AC3 x264"))
        XCTAssertTrue(withFallback.warnings.isEmpty)
        let av1 = StreamAnalyzer.analyze(stream("https://cdn.test/a.mp4", details: "AV1 1080p"))
        XCTAssertTrue(av1.warnings.contains(where: { $0.contains("AV1") }))
    }

    func testProxyHeadersAreFlagged() {
        let hints = StreamBehaviorHints(notWebReady: true, proxyRequestHeaders: ["Referer": "https://x.test"])
        XCTAssertTrue(StreamAnalyzer.analyze(stream("https://cdn.test/a.mp4", hints: hints)).needsHeaders)
    }
}

final class ReleaseLanguageDetectorTests: XCTestCase {
    func testRecognizesItalianReleaseMarkers() {
        XCTAssertEqual(ReleaseLanguageDetector.language(in: "Example.S01E01.1080p.ITA.WEB-DL"), "it")
        XCTAssertEqual(ReleaseLanguageDetector.language(in: "Example S01E01 [IT] 1080p"), "it")
        XCTAssertEqual(ReleaseLanguageDetector.language(in: "Example - Italian Audio"), "it")
    }

    func testRecognizesOtherLanguagesAndMultiAudio() {
        XCTAssertEqual(ReleaseLanguageDetector.language(in: "Show.S01E01.ENG.1080p"), "en")
        XCTAssertEqual(ReleaseLanguageDetector.language(in: "Show.S01E01.FRA.WEB-DL"), "fr")
        XCTAssertEqual(ReleaseLanguageDetector.language(in: "Show.S01E01.DUAL-AUDIO"), "multi")
    }

    func testDoesNotTreatOrdinaryEnglishWordsAsLanguageTags() {
        XCTAssertNil(ReleaseLanguageDetector.language(in: "It was a good episode"))
        XCTAssertNil(ReleaseLanguageDetector.language(in: "Show.S01E01.1080p.WEB-DL"))
    }
}

final class StreamSelectorTests: XCTestCase {
    private func make(_ name: String, _ url: String, details: String = "", addon: String? = nil, binge: String? = nil) -> AddonStream {
        return AddonStream(source: .url(url), name: name, details: details,
                           behaviorHints: StreamBehaviorHints(bingeGroup: binge), addonID: addon, addonName: addon)
    }

    func testRanksPlayableFirstThenQuality() {
        let streams = [
            make("mkv", "https://c.test/a.mkv", details: "2160p"),
            make("sd", "https://c.test/a.mp4", details: "480p"),
            make("fhd", "https://c.test/b.mp4", details: "1080p"),
            make("uhd", "https://c.test/c.mp4", details: "2160p")
        ]
        let ranked = StreamSelector.rank(streams, preferences: StreamPreferences())
        XCTAssertEqual(ranked.map { $0.stream.name }, ["uhd", "fhd", "sd", "mkv"], "unplayable streams stay visible at the bottom")
    }

    func testQualityCapPrefersWithinCap() {
        let streams = [make("uhd", "https://c.test/c.mp4", details: "2160p"), make("fhd", "https://c.test/b.mp4", details: "1080p")]
        let ranked = StreamSelector.rank(streams, preferences: StreamPreferences(qualityCap: .p1080))
        XCTAssertEqual(ranked.first?.stream.name, "fhd")
        let uncapped = StreamSelector.rank(streams, preferences: StreamPreferences(qualityCap: .auto))
        XCTAssertEqual(uncapped.first?.stream.name, "uhd")
    }

    func testPreferredLanguageBeatsQualityWhenEnabled() {
        let streams = [make("eng4k", "https://c.test/a.mp4", details: "2160p ENG"), make("ita1080", "https://c.test/b.mp4", details: "1080p ITA")]
        let prefer = StreamSelector.rank(streams, preferences: StreamPreferences(preferredLanguage: "it", preferLanguage: true))
        XCTAssertEqual(prefer.first?.stream.name, "ita1080")
        let ignore = StreamSelector.rank(streams, preferences: StreamPreferences(preferredLanguage: "it", preferLanguage: false))
        XCTAssertEqual(ignore.first?.stream.name, "eng4k")
    }

    func testAddonOrderBreaksTies() {
        let streams = [make("b", "https://c.test/b.mp4", details: "1080p", addon: "B"), make("a", "https://c.test/a.mp4", details: "1080p", addon: "A")]
        let ranked = StreamSelector.rank(streams, preferences: StreamPreferences(addonOrder: ["A", "B"]))
        XCTAssertEqual(ranked.first?.stream.name, "a")
    }

    // MARK: Order by addon

    /// Two addons: "A" (listed first) offers weaker files than "B". The 2160p file is B's.
    private func twoAddons() -> [AddonStream] {
        return [
            make("b-4k", "https://c.test/b1.mp4", details: "2160p", addon: "B"),
            make("a-720", "https://c.test/a1.mp4", details: "720p", addon: "A"),
            make("b-1080", "https://c.test/b2.mp4", details: "1080p", addon: "B"),
            make("a-480", "https://c.test/a2.mp4", details: "480p", addon: "A")
        ]
    }

    func testByAddonPutsEverySourceOfTheFirstAddonFirst() {
        let ranked = StreamSelector.rank(twoAddons(), preferences: StreamPreferences(addonOrder: ["A", "B"], ordering: .byAddon))
        XCTAssertEqual(ranked.map { $0.stream.name }, ["a-720", "a-480", "b-4k", "b-1080"],
                       "the addon list decides, Aether's ranking only orders the sources inside one addon")
        let reversed = StreamSelector.rank(twoAddons(), preferences: StreamPreferences(addonOrder: ["B", "A"], ordering: .byAddon))
        XCTAssertEqual(reversed.map { $0.stream.name }, ["b-4k", "b-1080", "a-720", "a-480"])
    }

    func testBestOrderingIgnoresTheAddonList() {
        let ranked = StreamSelector.rank(twoAddons(), preferences: StreamPreferences(addonOrder: ["A", "B"], ordering: .best))
        XCTAssertEqual(ranked.map { $0.stream.name }, ["b-4k", "b-1080", "a-720", "a-480"])
    }

    func testByAddonSendsUnknownAddonsAndUnplayableSourcesToTheBottom() {
        let streams = [
            make("stranger", "https://c.test/s.mp4", details: "2160p", addon: "Z"),
            make("a-broken", "https://c.test/a.mkv", details: "1080p", addon: "A"),
            make("none", "https://c.test/n.mp4", details: "1080p", addon: nil),
            make("a-ok", "https://c.test/a.mp4", details: "480p", addon: "A")
        ]
        let ranked = StreamSelector.rank(streams, preferences: StreamPreferences(addonOrder: ["A"], ordering: .byAddon))
        XCTAssertEqual(ranked.map { $0.stream.name }, ["a-ok", "stranger", "none", "a-broken"],
                       "addons outside the list follow the listed ones; a file that cannot be played stays below every playable one")
    }

    func testByAddonKeepsTheLanguageRankingInsideOneAddon() {
        let streams = [
            make("a-eng", "https://c.test/e.mp4", details: "2160p ENG", addon: "A"),
            make("a-ita", "https://c.test/i.mp4", details: "1080p ITA", addon: "A"),
            make("b-ita", "https://c.test/b.mp4", details: "2160p ITA", addon: "B")
        ]
        let preferences = StreamPreferences(preferredLanguage: "it", preferLanguage: true, addonOrder: ["A", "B"], ordering: .byAddon)
        XCTAssertEqual(StreamSelector.rank(streams, preferences: preferences).map { $0.stream.name }, ["a-ita", "a-eng", "b-ita"])
    }

    func testAutoSelectFollowsTheFirstAddonWithSomethingPlayable() {
        let ranked = StreamSelector.rank(twoAddons(), preferences: StreamPreferences(addonOrder: ["A", "B"], ordering: .byAddon))
        XCTAssertEqual(StreamSelector.autoSelect(ranked, ordering: .byAddon)?.stream.name, "a-720")
        // The binge group of the previous episode lives in the second addon: the first addon still wins.
        var streams = twoAddons()
        streams[0] = make("b-4k", "https://c.test/b1.mp4", details: "2160p", addon: "B", binge: "grp-b")
        let withGroup = StreamSelector.rank(streams, preferences: StreamPreferences(addonOrder: ["A", "B"], ordering: .byAddon))
        XCTAssertEqual(StreamSelector.autoSelect(withGroup, previousBingeGroup: "grp-b", ordering: .byAddon)?.stream.name, "a-720")
        XCTAssertEqual(StreamSelector.autoSelect(withGroup, previousBingeGroup: "grp-b", ordering: .best)?.stream.name, "b-4k",
                       "with the plain ranking the continuity match still wins")
    }

    func testAutoSelectSkipsAFirstAddonWhoseSourcesCannotBePlayed() {
        let streams = [make("a-broken", "https://c.test/a.mkv", details: "1080p", addon: "A"),
                       make("b-ok", "https://c.test/b.mp4", details: "720p", addon: "B")]
        let ranked = StreamSelector.rank(streams, preferences: StreamPreferences(addonOrder: ["A", "B"], ordering: .byAddon))
        XCTAssertEqual(StreamSelector.autoSelect(ranked, ordering: .byAddon)?.stream.name, "b-ok")
    }

    func testStreamOrderingSettingDefaultsToByAddonAndSurvivesRoundTrip() throws {
        XCTAssertEqual(PlaybackSettings().streamOrdering, .byAddon)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8)).streamOrdering, .byAddon,
                       "settings saved before the option existed get the new default")
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: Data("{\"streamOrdering\":\"surprise\"}".utf8)).streamOrdering, .byAddon,
                       "an unknown value falls back instead of failing the whole file")
        var settings = PlaybackSettings()
        settings.streamOrdering = .best
        let loaded = try JSONDecoder().decode(PlaybackSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.streamOrdering, .best)
    }

    func testAutoSelectUsesBingeGroupThenBestPlayable() {
        let streams = [
            make("best", "https://c.test/a.mp4", details: "2160p", binge: "grp-4k"),
            make("same-release", "https://c.test/b.mp4", details: "1080p", binge: "grp-1080"),
            make("broken", "https://c.test/c.mkv", details: "4320p", binge: "grp-mkv")
        ]
        let ranked = StreamSelector.rank(streams, preferences: StreamPreferences())
        XCTAssertEqual(StreamSelector.autoSelect(ranked)?.stream.name, "best")
        XCTAssertEqual(StreamSelector.autoSelect(ranked, previousBingeGroup: "grp-1080")?.stream.name, "same-release")
        XCTAssertEqual(StreamSelector.autoSelect(ranked, previousBingeGroup: "grp-mkv")?.stream.name, "best", "never auto-select an unplayable stream")
        XCTAssertNil(StreamSelector.autoSelect([]))
    }

    func testLanguageHelpers() {
        XCTAssertEqual(LanguageCodes.normalise("ita"), "it")
        XCTAssertEqual(LanguageCodes.normalise("pt-BR"), "pt-BR", "Brazilian Portuguese is no longer folded into plain Portuguese")
        XCTAssertEqual(LanguageCodes.normalise("Italian"), "it")
        XCTAssertEqual(LanguageCodes.normalise("xx"), "xx")
        XCTAssertTrue(LanguageCodes.matches("fre", "fr"))
        XCTAssertEqual(StreamSelector.resolveLanguage("off", systemLanguage: "it"), nil)
        XCTAssertEqual(StreamSelector.resolveLanguage("system", systemLanguage: "it"), "it")
        XCTAssertEqual(StreamSelector.resolveLanguage("de", systemLanguage: "it"), "de")
        XCTAssertFalse(LanguageCodes.displayName("it").isEmpty)
    }
}

final class NextEpisodeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func video(_ season: Int, _ episode: Int, released: TimeInterval? = -1000) -> Video {
        return Video(id: "s:\(season):\(episode)", title: "E\(episode)", released: released.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) },
                     season: season, episode: episode)
    }

    private func meta(_ videos: [Video], type: String = "series") -> MetaItem {
        return MetaItem(id: "s", type: type, name: "S", videos: videos)
    }

    func testNextAndPreviousWithinAndAcrossSeasons() {
        let m = meta([video(0, 1), video(1, 1), video(1, 2), video(2, 1)])
        XCTAssertEqual(NextEpisodeResolver.next(after: "s:1:1", in: m, now: now)?.id, "s:1:2")
        XCTAssertEqual(NextEpisodeResolver.next(after: "s:1:2", in: m, now: now)?.id, "s:2:1", "season change is allowed")
        XCTAssertEqual(NextEpisodeResolver.next(after: "s:0:1", in: m, now: now)?.id, "s:1:1", "specials lead into season 1")
        XCTAssertNil(NextEpisodeResolver.next(after: "s:2:1", in: m, now: now), "end of the series")
        XCTAssertNil(NextEpisodeResolver.next(after: "missing", in: m, now: now))
        XCTAssertEqual(NextEpisodeResolver.previous(before: "s:1:2", in: m)?.id, "s:1:1")
        XCTAssertNil(NextEpisodeResolver.previous(before: "s:0:1", in: m))
    }

    func testUnreleasedEpisodesAreNotOffered() {
        let m = meta([video(1, 1), video(1, 2, released: 100_000)])
        XCTAssertNil(NextEpisodeResolver.next(after: "s:1:1", in: m, now: now))
    }

    func testLiveItemsNeverAdvance() {
        let m = meta([video(1, 1), video(1, 2)], type: "tv")
        XCTAssertNil(NextEpisodeResolver.next(after: "s:1:1", in: m, now: now))
    }

    func testNextUnwatchedSkipsWatchedEpisodes() {
        let m = meta([video(1, 1), video(1, 2), video(1, 3), video(1, 4)])
        XCTAssertEqual(NextEpisodeResolver.nextUnwatched(after: "s:1:1", in: m, watched: ["s:1:2"], now: now)?.id, "s:1:3")
        XCTAssertNil(NextEpisodeResolver.nextUnwatched(after: "s:1:1", in: m, watched: ["s:1:2", "s:1:3", "s:1:4"], now: now))
    }

    func testEpisodeToPlayPolicy() {
        let m = meta([video(0, 1), video(1, 1), video(1, 2), video(1, 3)])
        XCTAssertEqual(NextEpisodeResolver.episodeToPlay(in: m, watched: [], lastWatchedID: nil, inProgressID: nil, now: now)?.id, "s:1:1",
                       "fresh start skips specials")
        XCTAssertEqual(NextEpisodeResolver.episodeToPlay(in: m, watched: ["s:1:1"], lastWatchedID: "s:1:1", inProgressID: nil, now: now)?.id, "s:1:2")
        XCTAssertEqual(NextEpisodeResolver.episodeToPlay(in: m, watched: ["s:1:1"], lastWatchedID: "s:1:1", inProgressID: "s:1:3", now: now)?.id, "s:1:3",
                       "an episode in progress wins")
    }
}

final class SubtitleParserTests: XCTestCase {
    func testParsesSRTWithMarkupAndEntities() throws {
        let cues = try SubtitleParser.parse(Fixture.data("sample.srt"))
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Ciao mondo!", "tags are stripped")
        XCTAssertEqual(cues[1].text, "Seconda riga\ncon due linee")
        XCTAssertEqual(cues[2].start, 62.5, accuracy: 0.001)
        XCTAssertEqual(cues[2].text, "& fine", "entities are decoded")
    }

    func testParsesWebVTTWithSettingsNotesAndShortTimestamps() throws {
        let cues = try SubtitleParser.parse(Fixture.data("sample.vtt"))
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Ciao mondo", "voice and class tags are removed")
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001, "cue settings after the end time are ignored")
        XCTAssertEqual(cues[1].start, 4.0, accuracy: 0.001, "MM:SS.mmm timestamps are accepted")
    }

    func testParsesASSDialogueIgnoringOverridesAndCommas() throws {
        let cues = try SubtitleParser.parse(Fixture.data("sample.ass"))
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Ciao, mondo\nsecondo rigo", "override blocks removed, commas in text kept, \\N is a newline")
        XCTAssertEqual(cues[1].start, 62.5, accuracy: 0.001)
    }

    func testDetectsLegacyEncodings() throws {
        let data = try Fixture.data("sample_cp1252.srt")
        XCTAssertNil(String(data: data, encoding: .utf8), "fixture really is not UTF-8")
        let cues = try SubtitleParser.parse(data, languageHint: "ita")
        XCTAssertEqual(cues.first?.text, "È già così perché sì")
    }

    func testBOMAndUTF16() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("1\n00:00:01,000 --> 00:00:02,000\nOK\n".utf8)
        XCTAssertEqual(try SubtitleParser.parse(bom).first?.text, "OK")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("1\n00:00:01,000 --> 00:00:02,000\nUTF16\n".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try SubtitleParser.parse(utf16).first?.text, "UTF16")
    }

    func testRejectsEmptyAndUnknownFormats() {
        XCTAssertThrowsError(try SubtitleParser.parse(Data())) { XCTAssertEqual($0 as? SubtitleError, .empty) }
        XCTAssertThrowsError(try SubtitleParser.parse(Data("hello world".utf8))) { XCTAssertEqual($0 as? SubtitleError, .unsupportedFormat) }
        XCTAssertThrowsError(try SubtitleParser.parse(Data("WEBVTT\n\n".utf8))) { XCTAssertEqual($0 as? SubtitleError, .noCues) }
    }

    func testTimelineLookupAndDelay() throws {
        let timeline = SubtitleTimeline(cues: try SubtitleParser.parse(Fixture.data("sample.srt")))
        XCTAssertTrue(timeline.active(at: 0.5).isEmpty)
        XCTAssertEqual(timeline.active(at: 1.0).map { $0.text }, ["Ciao mondo!"])
        XCTAssertEqual(timeline.active(at: 3.4).count, 1)
        XCTAssertTrue(timeline.active(at: 3.6).isEmpty, "gap between cues")
        XCTAssertEqual(timeline.active(at: 5.0).first?.text, "Seconda riga\ncon due linee")
        XCTAssertEqual(timeline.active(at: 62.9).first?.text, "& fine")
        XCTAssertTrue(timeline.active(at: 100).isEmpty)
        // Positive delay shifts cues later: at t=1.5 with +1s delay the first cue has not started yet.
        XCTAssertTrue(timeline.active(at: 1.5, delay: 1.0).isEmpty)
        XCTAssertEqual(timeline.active(at: 2.2, delay: 1.0).count, 1)
        // Negative delay shifts earlier.
        XCTAssertEqual(timeline.active(at: 0.2, delay: -1.0).count, 1)
    }

    func testOverlappingCuesAreBothActive() {
        let timeline = SubtitleTimeline(cues: [SubtitleCue(start: 0, end: 10, text: "long"), SubtitleCue(start: 2, end: 4, text: "short")])
        XCTAssertEqual(timeline.active(at: 3).map { $0.text }, ["long", "short"])
        XCTAssertEqual(timeline.active(at: 6).map { $0.text }, ["long"])
    }
}

final class PlaybackErrorMapperTests: XCTestCase {
    func testNetworkErrors() {
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "NSURLErrorDomain", code: -1009).kind, .offline)
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "NSURLErrorDomain", code: -1001).kind, .timeout)
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "NSURLErrorDomain", code: -1004).kind, .unreachable)
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "NSURLErrorDomain", code: -1022).kind, .atsBlocked)
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "NSURLErrorDomain", code: -1202).kind, .tlsFailure)
        XCTAssertTrue(PlaybackErrorMapper.map(domain: "NSURLErrorDomain", code: -1009).isNetworkRelated)
        XCTAssertFalse(PlaybackErrorMapper.map(domain: "NSURLErrorDomain", code: -1009).suggestsAnotherSource)
    }

    func testHTTPAndFormatErrors() {
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "CoreMediaErrorDomain", code: -12660).kind, .forbidden)
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "CoreMediaErrorDomain", code: -12938).kind, .notFound)
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "AVFoundationErrorDomain", code: -11828).kind, .formatUnsupported)
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "AVFoundationErrorDomain", code: -11833).kind, .codecUnsupported)
        XCTAssertEqual(PlaybackErrorMapper.map(domain: "AVFoundationErrorDomain", code: -11850).kind, .serverMisconfigured)
        XCTAssertTrue(PlaybackErrorMapper.map(domain: "CoreMediaErrorDomain", code: -12660).suggestsAnotherSource)
    }

    func testUnderlyingErrorWinsOverAGenericWrapper() {
        let failure = PlaybackErrorMapper.map(domain: "AVFoundationErrorDomain", code: -11800, description: "The operation could not be completed",
                                              underlying: [(domain: "NSURLErrorDomain", code: -1009)])
        XCTAssertEqual(failure.kind, .offline)
        let unknown = PlaybackErrorMapper.map(domain: "SomethingElse", code: 7, description: "boom")
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertTrue(unknown.message.contains("boom"))
        XCTAssertFalse(PlaybackFailure(kind: .formatUnsupported, detail: "").message.isEmpty)
    }
}
