import XCTest
@testable import AetherCore

final class ReleaseLanguageDetectorTests: XCTestCase {
    func testItalianAndEnglishDualAudioPrefersRequestedLanguage() {
        let title = "How.I.Met.Your.Mother.1x01.Pilot.ITA.ENG.1080p.DLMux.x264.mkv"
        XCTAssertEqual(ReleaseLanguageDetector.languages(in: title), ["it", "en"])
        XCTAssertEqual(ReleaseLanguageDetector.language(in: title, preferred: "en"), "en")
        XCTAssertEqual(ReleaseLanguageDetector.language(in: title, preferred: "it"), "it")
    }

    func testItalianOnlyRelease() {
        XCTAssertEqual(ReleaseLanguageDetector.language(in: "Una.lunga.storia.ITA.DLMUX.x264.mkv"), "it")
    }

    func testSubtitleOnlyTagsDoNotCountAsAudio() {
        XCTAssertTrue(ReleaseLanguageDetector.languages(in: "Show.S01E01.SUBITA.1080p.mkv").isEmpty)
        XCTAssertTrue(ReleaseLanguageDetector.languages(in: "Show S01E01 SUB ENG 1080p.mkv").isEmpty)
        XCTAssertTrue(ReleaseLanguageDetector.languages(in: "Show.S01E01.VOSTFR.1080p.mkv").isEmpty)
    }

    func testIndependentAudioTagStillCountsWhenSubtitleTagIsPresent() {
        XCTAssertEqual(ReleaseLanguageDetector.languages(in: "Show.S01E01.ITA.SUBENG.1080p.mkv"), ["it"])
    }

    func testCommonSpanishAndGermanReleaseTags() {
        XCTAssertEqual(ReleaseLanguageDetector.language(in: "Show.S01E01.ESP.WEB-DL"), "es")
        XCTAssertEqual(ReleaseLanguageDetector.language(in: "Show.S01E01.GER.1080p"), "de")
    }

    func testDoesNotMatchLanguageInsideOrdinaryWords() {
        XCTAssertTrue(ReleaseLanguageDetector.languages(in: "The.Italian.Job.2003.1080p").isEmpty)
        XCTAssertTrue(ReleaseLanguageDetector.languages(in: "Show.ENGAGEMENT.S01E01").isEmpty)
    }
}
