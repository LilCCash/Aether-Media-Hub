import XCTest
@testable import AetherCore

final class AdvancedSearchTests: XCTestCase {
    private let parser = NaturalQueryParser(currentYear: 2026)

    func testFunnyRecentMovies() {
        let out = parser.parse("film divertenti degli ultimi anni")
        XCTAssertEqual(out.intent.kind, .movie)
        XCTAssertEqual(out.intent.genres, [.comedy])
        XCTAssertEqual(out.intent.yearFrom, 2021)
    }

    func testSillyFamousComedies() {
        let out = parser.parse("commedie demenziali famose")
        XCTAssertEqual(out.intent.genres, [.comedy])
        XCTAssertTrue(out.intent.keywords.contains("slapstick"))
        XCTAssertEqual(out.intent.sort, .popularity)
    }

    func testDecadeAndCountry() {
        let out = parser.parse("horror italiani anni 80")
        XCTAssertEqual(out.intent.genres, [.horror])
        XCTAssertEqual(out.intent.countries, ["IT"])
        XCTAssertEqual(out.intent.yearFrom, 1980)
        XCTAssertEqual(out.intent.yearTo, 1989)
    }

    func testBestSeriesSetsRating() {
        let out = parser.parse("migliori serie thriller")
        XCTAssertEqual(out.intent.kind, .series)
        XCTAssertEqual(out.intent.sort, .rating)
        XCTAssertNotNil(out.intent.minRating)
    }

    func testPlainTitleHasNoFilters() {
        let out = parser.parse("Inception")
        XCTAssertFalse(out.intent.hasFilters)
        XCTAssertEqual(out.leftovers, ["inception"])
    }

    func testAIResponseParsing() {
        let text = "```json\n{\"kind\":\"movie\",\"genres\":[\"comedy\",\"Horror\"],\"keywords\":[\"Parody\"],\"year_from\":2018,\"sort\":\"rating\",\"countries\":[\"it\"]}\n```"
        let intent = AIIntentCodec.parse(text)
        XCTAssertEqual(intent?.kind, .movie)
        XCTAssertEqual(intent?.genres, [.comedy, .horror])
        XCTAssertEqual(intent?.keywords, ["parody"])
        XCTAssertEqual(intent?.yearFrom, 2018)
        XCTAssertEqual(intent?.sort, .rating)
        XCTAssertEqual(intent?.countries, ["IT"])
        XCTAssertNil(AIIntentCodec.parse("non lo so"))
    }

    func testRequestShapes() throws {
        let anthropic = try AISearchClient.request(provider: .anthropic, model: "m", key: "k", customBase: "", system: "s", user: "u", timeout: 5)
        XCTAssertEqual(anthropic.headers["x-api-key"], "k")
        XCTAssertEqual(anthropic.url.host, "api.anthropic.com")
        XCTAssertThrowsError(try AISearchClient.request(provider: .custom, model: "m", key: nil, customBase: "http://x.example", system: "s", user: "u", timeout: 5))
        let custom = try AISearchClient.request(provider: .custom, model: "m", key: nil, customBase: "https://x.example/v1/", system: "s", user: "u", timeout: 5)
        XCTAssertEqual(custom.url.absoluteString, "https://x.example/v1/chat/completions")
    }

    func testAnswerText() {
        let data = Data("{\"choices\":[{\"message\":{\"content\":\"{}\"}}]}".utf8)
        XCTAssertEqual(AISearchClient.answerText(provider: .openai, data: data), "{}")
    }

    func testSettingsDefaultsAndModel() {
        var settings = AdvancedSearchSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.model(for: .anthropic), "claude-haiku-5-5")
        settings.setModel("  custom ", for: .anthropic)
        XCTAssertEqual(settings.model(for: .anthropic), "custom")
    }
}
