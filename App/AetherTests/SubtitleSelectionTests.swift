import XCTest
import AetherCore
@testable import Aether

/// The decisions behind subtitles and audio in the player: which language wins, what the viewer's own choices change,
/// how the sheet words each row, and when the hash of the video is worth computing. No player, no network.
final class SubtitleSelectionTests: XCTestCase {
    // MARK: Helpers

    private func subtitles(_ entries: [(lang: String, label: String?)], addon: String = "Test addon") -> [AddonSubtitle] {
        var result: [AddonSubtitle] = []
        for (index, entry) in entries.enumerated() {
            result.append(AddonSubtitle(id: "s\(index)", url: "https://subs.example/\(index).srt", lang: entry.lang,
                                        label: entry.label, addonName: addon))
        }
        return result
    }

    private func candidates(_ entries: [(lang: String, label: String?)]) -> [SubtitleCandidate] {
        return SubtitleCatalog.candidates(from: subtitles(entries))
    }

    private func track(_ id: String, _ title: String, language: String?, selected: Bool = false) -> EngineTrack {
        return EngineTrack(id: id, title: title, language: language, isSelected: selected)
    }

    // MARK: Language wishes

    func testOrderedLanguagesDropsOffBlanksAndRepetitions() {
        let result = TrackPreferences.orderedLanguages(["it", nil, "off", "  ", "ita", "en-US", "Italiano"])
        XCTAssertEqual(result, ["it", "en"])
    }

    func testTheLanguagePickedByHandRanksFirstForTheList() {
        let ranking = TrackPreferences.subtitleRanking(remembered: .language("en"), primary: "it", secondary: "fr")
        XCTAssertEqual(ranking, ["en", "it", "fr"])
    }

    func testTurningSubtitlesOffByHandStopsTheAutomaticChoiceButNotTheRanking() {
        let automatic = TrackPreferences.automaticSubtitleLanguages(remembered: .off, primary: "it", secondary: "en")
        XCTAssertEqual(automatic, [])
        let ranking = TrackPreferences.subtitleRanking(remembered: .off, primary: "it", secondary: "en")
        XCTAssertEqual(ranking, ["it", "en"])
    }

    func testBothSettingsOffMeansNothingIsSwitchedOn() {
        XCTAssertEqual(TrackPreferences.automaticSubtitleLanguages(remembered: nil, primary: nil, secondary: nil), [])
    }

    func testOnlyTheSecondarySettingStillCounts() {
        XCTAssertEqual(TrackPreferences.automaticSubtitleLanguages(remembered: nil, primary: nil, secondary: "en"), ["en"])
    }

    func testRegionalVariantsKeepTheirOwnCode() {
        let result = TrackPreferences.orderedLanguages(["pob", "pt-PT", "pt-BR"])
        XCTAssertEqual(result, ["pt-BR", "pt-PT"])
    }

    // MARK: Audio

    func testAudioFallsBackToTheSecondaryLanguage() {
        let tracks = [track("0", "Italiano", language: "ita"), track("1", "English", language: "eng")]
        let languages = TrackPreferences.audioLanguages(remembered: nil, primary: "fr", secondary: "en")
        XCTAssertEqual(TrackPreferences.pickAudio(languages: languages, tracks: tracks)?.id, "1")
    }

    func testAudioPrefersThePrimaryLanguageWhenItExists() {
        let tracks = [track("0", "English", language: "eng"), track("1", "Italiano", language: "ita")]
        let languages = TrackPreferences.audioLanguages(remembered: nil, primary: "it", secondary: "en")
        XCTAssertEqual(TrackPreferences.pickAudio(languages: languages, tracks: tracks)?.id, "1")
    }

    func testAudioPickedByHandForTheTitleBeatsTheSettings() {
        let tracks = [track("0", "Italiano", language: "ita"), track("1", "日本語", language: "jpn")]
        let languages = TrackPreferences.audioLanguages(remembered: "ja", primary: "it", secondary: nil)
        XCTAssertEqual(languages, ["ja", "it"])
        XCTAssertEqual(TrackPreferences.pickAudio(languages: languages, tracks: tracks)?.id, "1")
    }

    func testAudioTrackWithoutALanguageTagIsMatchedByItsTitle() {
        let tracks = [track("0", "Deutsch", language: nil), track("1", "Italiano", language: nil)]
        XCTAssertEqual(TrackPreferences.pickAudio(languages: ["it"], tracks: tracks)?.id, "1")
    }

    func testNoAudioTrackWhenNoWishedLanguageIsPresent() {
        let tracks = [track("0", "Deutsch", language: "deu")]
        XCTAssertNil(TrackPreferences.pickAudio(languages: ["it", "en"], tracks: tracks))
        XCTAssertNil(TrackPreferences.pickAudio(languages: [], tracks: tracks))
    }

    func testAudioLanguageToRememberComesFromTheTagThenFromASingleWordTitle() {
        XCTAssertEqual(TrackPreferences.audioLanguageToRemember(for: track("0", "Qualunque", language: "jpn")), "ja")
        XCTAssertEqual(TrackPreferences.audioLanguageToRemember(for: track("0", "Italiano", language: nil)), "it")
        XCTAssertNil(TrackPreferences.audioLanguageToRemember(for: track("0", "Traccia 2", language: nil)))
        XCTAssertNil(TrackPreferences.audioLanguageToRemember(for: track("0", "Italiano · AC3", language: nil)))
    }

    // MARK: Automatic subtitle choice

    private func embedded(_ id: String, _ title: String, _ language: String?) -> EmbeddedSubtitleInfo {
        return EmbeddedSubtitleInfo(optionID: id, title: title, language: language)
    }

    func testAnEmbeddedTrackInThePreferredLanguageBeatsAnAddonSubtitle() {
        let decision = TrackPreferences.decide(languages: ["it"], embedded: [embedded("embedded-1", "Italiano", "ita")],
                                               candidates: candidates([("ita", nil)]), listIsFinal: true)
        XCTAssertEqual(decision, .embedded(optionID: "embedded-1"))
    }

    func testAnAddonSubtitleIsUsedWhenNothingEmbeddedMatches() {
        let decision = TrackPreferences.decide(languages: ["it"], embedded: [embedded("embedded-1", "English", "eng")],
                                               candidates: candidates([("eng", nil), ("ita", nil)]), listIsFinal: true)
        guard case .addon(let candidate) = decision else { return XCTFail("expected an addon subtitle, got \(decision)") }
        XCTAssertEqual(candidate.language, "it")
    }

    func testTheSecondaryLanguageIsUsedWhenThePrimaryIsMissing() {
        let decision = TrackPreferences.decide(languages: ["fr", "en"], embedded: [],
                                               candidates: candidates([("ita", nil), ("eng", nil)]), listIsFinal: true)
        guard case .addon(let candidate) = decision else { return XCTFail("expected an addon subtitle, got \(decision)") }
        XCTAssertEqual(candidate.language, "en")
    }

    func testAnAddonSubtitleInThePrimaryLanguageBeatsAnEmbeddedTrackInTheSecondary() {
        let decision = TrackPreferences.decide(languages: ["it", "en"], embedded: [embedded("embedded-2", "English", "eng")],
                                               candidates: candidates([("ita", nil)]), listIsFinal: true)
        guard case .addon(let candidate) = decision else { return XCTFail("expected the Italian addon subtitle, got \(decision)") }
        XCTAssertEqual(candidate.language, "it")
    }

    func testItWaitsForTheAddonsBeforeFallingBackToALaterLanguage() {
        let english = [embedded("embedded-2", "English", "eng")]
        XCTAssertEqual(TrackPreferences.decide(languages: ["it", "en"], embedded: english, candidates: [], listIsFinal: false), .wait)
        XCTAssertEqual(TrackPreferences.decide(languages: ["it", "en"], embedded: english, candidates: [], listIsFinal: true),
                       .embedded(optionID: "embedded-2"))
    }

    func testAnEmbeddedTrackInTheFirstLanguageNeverWaitsForTheAddons() {
        let decision = TrackPreferences.decide(languages: ["it"], embedded: [embedded("embedded-1", "Italiano", "ita")],
                                               candidates: [], listIsFinal: false)
        XCTAssertEqual(decision, .embedded(optionID: "embedded-1"))
    }

    func testNothingIsChosenWhenNoLanguageMatches() {
        let decision = TrackPreferences.decide(languages: ["it", "en"], embedded: [embedded("embedded-1", "Deutsch", "deu")],
                                               candidates: candidates([("fra", nil)]), listIsFinal: true)
        XCTAssertEqual(decision, .nothing)
    }

    func testNothingIsChosenWithoutWishedLanguages() {
        let decision = TrackPreferences.decide(languages: [], embedded: [embedded("embedded-1", "Italiano", "ita")],
                                               candidates: candidates([("ita", nil)]), listIsFinal: true)
        XCTAssertEqual(decision, .nothing)
    }

    func testForcedEmbeddedTracksAreNeverSwitchedOnAutomatically() {
        let decision = TrackPreferences.decide(languages: ["it"], embedded: [embedded("embedded-1", "Italiano · forzati", "ita")],
                                               candidates: [], listIsFinal: true)
        XCTAssertEqual(decision, .nothing)
    }

    func testForcedAddonSubtitlesAreNeverSwitchedOnAutomatically() {
        let decision = TrackPreferences.decide(languages: ["it"], embedded: [],
                                               candidates: candidates([("ita", "Italiano forced")]), listIsFinal: true)
        XCTAssertEqual(decision, .nothing)
    }

    func testAPlainSubtitleIsPreferredToAHearingImpairedOne() {
        let decision = TrackPreferences.decide(languages: ["en"], embedded: [],
                                               candidates: candidates([("eng", "English SDH"), ("eng", nil)]), listIsFinal: true)
        guard case .addon(let candidate) = decision else { return XCTFail("expected an addon subtitle, got \(decision)") }
        XCTAssertFalse(candidate.isHearingImpaired)
    }

    // MARK: Memory of the session

    func testChoicesMadeByHandApplyToTheSameTitleOnly() {
        var memory = SessionTrackMemory()
        XCTAssertTrue(memory.isEmpty)
        memory.rememberAudio(language: "jpn", metaID: "tt1")
        memory.rememberSubtitle(.language("en"), metaID: "tt1")
        XCTAssertEqual(memory.audioLanguageToApply(forMeta: "tt1"), "ja")
        XCTAssertEqual(memory.subtitleChoiceToApply(forMeta: "tt1"), .language("en"))
        XCTAssertNil(memory.audioLanguageToApply(forMeta: "tt2"))
        XCTAssertNil(memory.subtitleChoiceToApply(forMeta: "tt2"))
    }

    func testAnotherTitleStartsFromACleanSlate() {
        var memory = SessionTrackMemory()
        memory.rememberAudio(language: "jpn", metaID: "tt1")
        memory.rememberSubtitle(.off, metaID: "tt2")
        XCTAssertNil(memory.audioLanguageToApply(forMeta: "tt1"), "the audio choice belonged to the previous title")
        XCTAssertNil(memory.audioLanguageToApply(forMeta: "tt2"))
        XCTAssertEqual(memory.subtitleChoiceToApply(forMeta: "tt2"), .off)
    }

    func testResetForgetsEverything() {
        var memory = SessionTrackMemory()
        memory.rememberAudio(language: "it", metaID: "tt1")
        memory.rememberSubtitle(.off, metaID: "tt1")
        memory.reset()
        XCTAssertTrue(memory.isEmpty)
        XCTAssertNil(memory.subtitleChoiceToApply(forMeta: "tt1"))
    }

    func testAnAudioTrackWithoutALanguageLeavesTheMemoryAlone() {
        var memory = SessionTrackMemory()
        memory.rememberAudio(language: "ita", metaID: "tt1")
        memory.rememberAudio(language: nil, metaID: "tt1")
        memory.rememberAudio(language: "und", metaID: "tt1")
        XCTAssertEqual(memory.audioLanguageToApply(forMeta: "tt1"), "it")
    }

    func testAnUnlabelledSubtitleReplacesAnEarlierOffChoice() {
        var memory = SessionTrackMemory()
        memory.rememberSubtitle(.off, metaID: "tt1")
        memory.forgetSubtitle()
        XCTAssertNil(memory.subtitleChoiceToApply(forMeta: "tt1"))
    }

    // MARK: Rows of the sheet

    func testGroupsAreNamedInItalianAndUnknownLanguagesSayso() {
        let list = candidates([("ita", nil), ("und", nil)])
        let groups = SubtitleCatalog.groups(from: list)
        let names = groups.map { SubtitleRowText.groupName($0) }
        XCTAssertTrue(names.contains("Italiano"), "\(names)")
        XCTAssertTrue(names.contains("Lingua non specificata"), "\(names)")
    }

    func testEntriesThatWouldReadTheSameAreNumbered() throws {
        let list = candidates([("ita", nil), ("ita", nil), ("ita", "Italiano (ripulito)"), ("eng", nil)])
        let groups = SubtitleCatalog.groups(from: list)
        let italian = try XCTUnwrap(groups.first(where: { $0.language == "it" }))
        let rows = SubtitleRowText.rows(for: italian)
        XCTAssertEqual(rows.map { $0.title }, ["Italiano (ripulito)", "Italiano 1", "Italiano 2"])
        let english = try XCTUnwrap(groups.first(where: { $0.language == "en" }))
        XCTAssertEqual(SubtitleRowText.rows(for: english).map { $0.title }, ["Inglese"])
    }

    func testTheDetailLineNamesTheFlagsAndTheAddon() throws {
        let list = candidates([("eng", "English SDH"), ("eng", "English forced")])
        let group = try XCTUnwrap(SubtitleCatalog.groups(from: list).first)
        let rows = SubtitleRowText.rows(for: group)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].detail, "Non udenti · Test addon")
        XCTAssertEqual(rows[1].detail, "Forzati · Test addon")
    }

    func testVoiceOverHearsTheLanguageEvenWhenTheLabelDoesNotSayIt() throws {
        let list = candidates([("ita", "Release 2160p"), ("eng", "Inglese")])
        let groups = SubtitleCatalog.groups(from: list)
        let italian = try XCTUnwrap(groups.first(where: { $0.language == "it" }))
        XCTAssertEqual(SubtitleRowText.rows(for: italian).first?.accessibilityLabel, "Italiano, Release 2160p, Test addon")
        let english = try XCTUnwrap(groups.first(where: { $0.language == "en" }))
        XCTAssertEqual(SubtitleRowText.rows(for: english).first?.accessibilityLabel, "Inglese, Test addon",
                       "the label already says the language")
    }

    func testAddonOptionsHaveStableIdentifiersAndKeepTheEncodingHint() throws {
        let list = SubtitleCatalog.candidates(from: [
            AddonSubtitle(id: "a", url: "https://subs.example/file/1?senc=cp1250", lang: "pol", label: nil, addonName: "X")
        ])
        let candidate = try XCTUnwrap(list.first)
        let option = SubtitleOption.addon(candidate)
        XCTAssertEqual(option.id, "addon-https://subs.example/file/1?senc=cp1250")
        XCTAssertEqual(option.id, SubtitleOption.optionID(for: candidate))
        XCTAssertEqual(option.languageCode, "pl")
        XCTAssertEqual(option.encodingHint, "cp1250")
        XCTAssertFalse(option.isEmbedded)
        XCTAssertFalse(option.isLocalFile)
    }

    // MARK: Empty states

    func testTheEmptyStatesAreHonest() {
        XCTAssertNil(SubtitleEmptyState.resolve(phase: .loading, hasProvider: true, externalCount: 0), "still asking")
        XCTAssertNil(SubtitleEmptyState.resolve(phase: .ready, hasProvider: true, externalCount: 3), "there is a list")
        XCTAssertNil(SubtitleEmptyState.resolve(phase: .ready, hasProvider: false, externalCount: 1), "the stream carried its own")
        XCTAssertEqual(SubtitleEmptyState.resolve(phase: .ready, hasProvider: true, externalCount: 0), .nothingFound)
        XCTAssertEqual(SubtitleEmptyState.resolve(phase: .ready, hasProvider: false, externalCount: 0), .noProvider)
    }

    // MARK: Hash of the video

    private func stream(_ source: StreamSource, hints: StreamBehaviorHints = StreamBehaviorHints()) -> AddonStream {
        return AddonStream(source: source, name: "Test", behaviorHints: hints)
    }

    func testThePlainHTTPSFileIsHashedOnThisDevice() {
        XCTAssertTrue(SubtitleHashPlan.shouldProbe(stream: stream(.url("https://cdn.example.com/Film.2021.mkv")), isDownload: false))
        XCTAssertTrue(SubtitleHashPlan.shouldProbe(stream: stream(.url("http://192.168.1.20:8080/film.mp4")), isDownload: false),
                      "plain http is decided by the probe itself (local network yes, public host no)")
    }

    func testDownloadsAreNeverHashed() {
        XCTAssertFalse(SubtitleHashPlan.shouldProbe(stream: stream(.url("https://cdn.example.com/Film.mkv")), isDownload: true))
        XCTAssertFalse(SubtitleHashPlan.shouldProbe(stream: nil, isDownload: true))
        XCTAssertFalse(SubtitleHashPlan.shouldProbe(stream: nil, isDownload: false))
    }

    func testAdaptiveStreamsAreNeverHashed() {
        for url in ["https://cdn.example.com/master.m3u8", "https://cdn.example.com/master.m3u8?token=abc",
                    "https://cdn.example.com/manifest.mpd", "https://cdn.example.com/v.ism/manifest",
                    "https://cdn.example.com/list.m3u", "https://cdn.example.com/list.m3u?x=1"] {
            XCTAssertFalse(SubtitleHashPlan.shouldProbe(stream: stream(.url(url)), isDownload: false), url)
        }
    }

    func testSourcesThatAreNotOnePlainFileAreNeverHashed() {
        let sources: [StreamSource] = [
            .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: nil, trackers: []),
            .youtube("dQw4w9WgXcQ"), .external("https://example.com/watch"), .playerFrame("https://example.com/frame"),
            .archive(kind: "rar"), .unknown, .url("ftp://example.com/film.mp4"), .url("rtmp://example.com/live")
        ]
        for source in sources {
            XCTAssertFalse(SubtitleHashPlan.shouldProbe(stream: stream(source), isDownload: false), "\(source)")
        }
    }

    func testAStreamThatAnnouncesTheHashAndTheSizeIsNotProbed() {
        let complete = StreamBehaviorHints(videoHash: "8e245d9679d31e12", videoSize: 12_909_756)
        XCTAssertFalse(SubtitleHashPlan.shouldProbe(stream: stream(.url("https://cdn.example.com/a.mp4"), hints: complete), isDownload: false))
        let partial = StreamBehaviorHints(videoHash: "8e245d9679d31e12")
        XCTAssertTrue(SubtitleHashPlan.shouldProbe(stream: stream(.url("https://cdn.example.com/a.mp4"), hints: partial), isDownload: false),
                      "a hash without the size is not a pair")
    }

    // MARK: Addons that serve subtitles

    private func manifest(id: String = "test.addon", resources: [ManifestResource], prefixes: [String]? = ["tt"],
                          types: [String] = ["movie", "series"]) -> AddonManifest {
        return AddonManifest(id: id, version: "1.0.0", name: "Test addon", types: types, resources: resources, idPrefixes: prefixes)
    }

    func testAnAddonServesSubtitlesForItsTypesAndIdPrefixes() {
        let subtitlesAddon = manifest(resources: [ManifestResource(name: "subtitles")])
        XCTAssertTrue(SubtitleAddonSupport.canServe(subtitlesAddon, type: "movie", videoID: "tt0111161"))
        XCTAssertTrue(SubtitleAddonSupport.canServe(subtitlesAddon, type: "series", videoID: "tt0944947:1:1"))
        XCTAssertFalse(SubtitleAddonSupport.canServe(subtitlesAddon, type: "movie", videoID: "kitsu:1234"), "wrong id prefix")
        XCTAssertFalse(SubtitleAddonSupport.canServe(subtitlesAddon, type: "tv", videoID: "tt0111161"), "wrong type")
    }

    func testAnAddonWithoutTheSubtitlesResourceNeverServesThem() {
        let streamsOnly = manifest(resources: [ManifestResource(name: "stream"), ManifestResource(name: "catalog")])
        XCTAssertFalse(SubtitleAddonSupport.canServe(streamsOnly, type: "movie", videoID: "tt0111161"))
    }

    func testTheResourcePrefixesWinOverTheManifestOnes() {
        let own = manifest(resources: [ManifestResource(name: "subtitles", types: ["movie"], idPrefixes: ["kitsu:"])], prefixes: ["tt"])
        XCTAssertTrue(SubtitleAddonSupport.canServe(own, type: "movie", videoID: "kitsu:1"))
        XCTAssertFalse(SubtitleAddonSupport.canServe(own, type: "movie", videoID: "tt1"))
    }

    func testAnAddonWithoutPrefixesServesEveryId() {
        let open = manifest(resources: [ManifestResource(name: "subtitles")], prefixes: nil)
        XCTAssertTrue(SubtitleAddonSupport.canServe(open, type: "movie", videoID: "anything:1"))
    }

    func testProvidersAreTheEnabledAddonsThatCanServeTheVideo() throws {
        let transport = try XCTUnwrap(URL(string: "https://addon.example/manifest.json"))
        func handle(_ manifest: AddonManifest) -> AddonHandle {
            return AddonHandle(addon: InstalledAddon(manifest: manifest, host: "addon.example", fingerprint: "f"), transportURL: transport)
        }
        let handles = [
            handle(manifest(id: "a", resources: [ManifestResource(name: "stream")])),
            handle(manifest(id: "b", resources: [ManifestResource(name: "subtitles")])),
            handle(manifest(id: "c", resources: [ManifestResource(name: "subtitles")], prefixes: ["yt_id:"]))
        ]
        let providers = SubtitleAddonSupport.providers(in: handles, type: "movie", videoID: "tt0111161")
        XCTAssertEqual(providers.map { $0.addon.manifest.id }, ["b"])
        XCTAssertTrue(SubtitleAddonSupport.providers(in: [], type: "movie", videoID: "tt0111161").isEmpty)
    }

    // MARK: Recommended addon

    func testTheRecommendedSubtitleAddonIsTheOfficialOpenSubtitlesOne() {
        XCTAssertEqual(RecommendedSubtitleAddon.manifestURL.absoluteString, "https://opensubtitles-v3.strem.io/manifest.json")
        XCTAssertEqual(RecommendedSubtitleAddon.addonID, "org.stremio.opensubtitlesv3")
        XCTAssertEqual(RecommendedSubtitleAddon.name, "OpenSubtitles v3")
    }

    func testTheRecommendationDisappearsOnceAnAddonWithThatIdIsInstalled() {
        func installed(_ id: String, enabled: Bool = true) -> InstalledAddon {
            let manifest = AddonManifest(id: id, version: "1.0.0", name: "X", types: ["movie"], resources: [ManifestResource(name: "subtitles")])
            return InstalledAddon(manifest: manifest, host: "x.example", fingerprint: "f", isEnabled: enabled)
        }
        XCTAssertFalse(RecommendedSubtitleAddon.isInstalled(in: []))
        XCTAssertFalse(RecommendedSubtitleAddon.isInstalled(in: [installed("com.linvo.cinemeta")]))
        XCTAssertTrue(RecommendedSubtitleAddon.isInstalled(in: [installed("com.linvo.cinemeta"), installed("org.stremio.opensubtitlesv3")]))
        XCTAssertTrue(RecommendedSubtitleAddon.isInstalled(in: [installed("org.stremio.opensubtitlesv3", enabled: false)]),
                      "a disabled copy is still installed: the entry must not offer it again")
    }
}
