import XCTest
@testable import AetherCore

final class OpenSubtitlesCatalogTests: XCTestCase {
    func testTheSearchAddressForAFilmAndAnEpisode() {
        XCTAssertEqual(OpenSubtitlesCatalog.searchURL(videoID: "tt0111161", language: "ita")?.absoluteString,
                       "https://rest.opensubtitles.org/search/imdbid-0111161/sublanguageid-ita")
        XCTAssertEqual(OpenSubtitlesCatalog.searchURL(videoID: "tt0944947:1:3", language: "ita")?.absoluteString,
                       "https://rest.opensubtitles.org/search/episode-3/imdbid-0944947/season-1/sublanguageid-ita",
                       "the catalogue wants its parameters in alphabetical order")
        XCTAssertNil(OpenSubtitlesCatalog.searchURL(videoID: "kitsu:123", language: "ita"))
        XCTAssertNil(OpenSubtitlesCatalog.searchURL(videoID: "tt", language: "ita"))
    }

    func testLanguagesBecomeTheCatalogueCodes() {
        XCTAssertEqual(OpenSubtitlesCatalog.catalogLanguage("it"), "ita")
        XCTAssertEqual(OpenSubtitlesCatalog.catalogLanguage("ita"), "ita")
        XCTAssertEqual(OpenSubtitlesCatalog.catalogLanguage("en"), "eng")
        XCTAssertEqual(OpenSubtitlesCatalog.catalogLanguage("de"), "ger")
        XCTAssertEqual(OpenSubtitlesCatalog.catalogLanguage("fr"), "fre")
        XCTAssertEqual(OpenSubtitlesCatalog.catalogLanguage("pt-BR"), "pob")
        XCTAssertNil(OpenSubtitlesCatalog.catalogLanguage(""))
    }

    func testAnAnswerBecomesSubtitlesMostDownloadedFirst() throws {
        let json = """
        [{"IDSubtitleFile": "1957373110", "SubFileName": "The.Shawshank.Redemption.srt", "SubFormat": "srt", "SubDownloadLink": "https://dl.opensubtitles.org/en/download/src-api/vrf-19bd0c4e/filead/1957373110.gz", "SubLanguageID": "ita", "MovieReleaseName": "The.Shawshank.Redemption.1994.2160p.UHD.BluRay.x265-REDANDY", "SubDownloadsCnt": "1119", "SubHearingImpaired": "0"},
         {"IDSubtitleFile": "1956455267", "SubFileName": "Tigole.ita.srt", "SubFormat": "srt", "SubDownloadLink": "https://dl.opensubtitles.org/en/download/src-api/vrf-19ce0c5b/filead/1956455267.gz", "SubLanguageID": "ita", "MovieReleaseName": "The Shawshank Redemption (1994) (1080p BluRay x265 10bit Tigole).mkv", "SubDownloadsCnt": "1225", "SubHearingImpaired": "1"},
         {"IDSubtitleFile": "1956455267", "SubFileName": "dup.srt", "SubFormat": "srt", "SubDownloadLink": "https://dl.opensubtitles.org/x.gz", "SubLanguageID": "ita", "SubDownloadsCnt": "5"},
         {"IDSubtitleFile": "9", "SubFileName": "image.idx", "SubFormat": "idx", "SubDownloadLink": "https://dl.opensubtitles.org/y.gz", "SubLanguageID": "ita", "SubDownloadsCnt": "9999"},
         {"IDSubtitleFile": "10", "SubFormat": "srt", "SubDownloadLink": "http://insecure.example/z.gz", "SubLanguageID": "ita", "SubDownloadsCnt": "1"}]
        """
        let subtitles = OpenSubtitlesCatalog.parse(Data(json.utf8))
        XCTAssertEqual(subtitles.map { $0.id }, ["osorg-1956455267", "osorg-1957373110"], "one per file, readable formats, https only")
        XCTAssertEqual(subtitles.first?.lang, "ita")
        XCTAssertEqual(subtitles.first?.addonName, "OpenSubtitles.org")
        XCTAssertTrue(subtitles.first?.label?.contains("non udenti") == true)
        XCTAssertTrue(OpenSubtitlesCatalog.parse(Data("{\"error\":1}".utf8)).isEmpty)
        XCTAssertTrue(OpenSubtitlesCatalog.parse(Data("[]".utf8)).isEmpty)
    }

    func testAGzipSubtitleIsUnpacked() throws {
        let packed = try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAAC/zPkMjCwAiFDHQMDAwVdXTsFqICRjqmBAZdzZmK+jkJufl5KPheXEUyxMbpiE5AAV3BqMlBhokJRZnoiFwB4BVNeWgAAAA=="))
        XCTAssertTrue(GzipData.isGzip(packed))
        XCTAssertFalse(GzipData.isGzip(Data("1\n00:00:01,000 --> 00:00:02,000\nCiao\n".utf8)))
        #if canImport(Compression)
        let text = String(decoding: try XCTUnwrap(GzipData.decompress(packed)), as: UTF8.self)
        XCTAssertTrue(text.contains("Ciao, mondo"), text)
        XCTAssertTrue(text.contains("Seconda riga"), text)
        let cues = try SubtitleParser.parse(try XCTUnwrap(GzipData.decompress(packed)), languageHint: "ita", encodingHint: nil)
        XCTAssertEqual(cues.count, 2)
        #else
        throw XCTSkip("no Compression framework on this platform")
        #endif
    }
}
