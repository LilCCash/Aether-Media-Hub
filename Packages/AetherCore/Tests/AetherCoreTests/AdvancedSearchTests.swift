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

    func testSimilarTo() {
        let a = parser.parse("film simili a Toy Story")
        XCTAssertEqual(a.intent.similarTo, "Toy Story")
        XCTAssertEqual(a.intent.kind, .movie)
        let b = parser.parse("film tipo Scary Movie")
        XCTAssertEqual(b.intent.similarTo, "Scary Movie")
        let c = parser.parse("serie come Lost")
        XCTAssertEqual(c.intent.similarTo, "Lost")
        XCTAssertEqual(c.intent.kind, .series)
        XCTAssertNil(parser.parse("come eravamo").intent.similarTo)
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

    func testSuggestedTitlesParsing() {
        let text = "{\"similar_to\":\"A Haunted House\",\"titles\":[{\"title\":\"Scary Movie\",\"year\":2000,\"type\":\"movie\"},{\"title\":\"Paranormal Activity\",\"year\":2007},{\"title\":\"\"}]}"
        let intent = AIIntentCodec.parse(text)
        XCTAssertEqual(intent?.suggestions.count, 2)
        XCTAssertEqual(intent?.suggestions.first, SuggestedTitle(title: "Scary Movie", year: 2000, kind: .movie))
        XCTAssertEqual(intent?.similarTo, "A Haunted House")
        XCTAssertTrue(AIIntentCodec.systemPrompt(year: 2026, count: 12).contains("up to 12"))
        XCTAssertFalse(AIIntentCodec.systemPrompt(year: 2026, count: 12, suggestTitles: false).contains("\"titles\""))
    }

    func testModelCatalogParsing() {
        let anthropic = Data("{\"data\":[{\"id\":\"claude-sonnet-5-5\",\"display_name\":\"Claude Sonnet 5.5\"},{\"id\":\"claude-haiku-5-5\",\"display_name\":\"Claude Haiku 5.5\"}]}".utf8)
        let a = AIModelCatalog.parse(provider: .anthropic, data: anthropic)
        XCTAssertEqual(a.map { $0.id }, ["claude-haiku-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(a.first?.note, "veloce ed economico")
        let openai = Data("{\"data\":[{\"id\":\"text-embedding-3-small\"},{\"id\":\"gpt-4o\"},{\"id\":\"gpt-4o-mini\"},{\"id\":\"whisper-1\"}]}".utf8)
        XCTAssertEqual(AIModelCatalog.parse(provider: .openai, data: openai).map { $0.id }, ["gpt-4o-mini", "gpt-4o"])
        let google = Data("{\"models\":[{\"name\":\"models/gemini-2.0-flash\",\"supportedGenerationMethods\":[\"generateContent\"]},{\"name\":\"models/embedding-001\",\"supportedGenerationMethods\":[\"embedContent\"]}]}".utf8)
        XCTAssertEqual(AIModelCatalog.parse(provider: .google, data: google).map { $0.id }, ["gemini-2.0-flash"])
        let router = Data("{\"data\":[{\"id\":\"a/b:free\",\"name\":\"B\"},{\"id\":\"c/d\",\"name\":\"D\",\"architecture\":{\"output_modalities\":[\"image\"]}}]}".utf8)
        let r = AIModelCatalog.parse(provider: .openrouter, data: router)
        XCTAssertEqual(r.map { $0.id }, ["a/b:free"])
        XCTAssertEqual(r.first?.note, "gratuito")
    }

    func testListRequests() throws {
        let anthropic = try AISearchClient.listRequest(provider: .anthropic, key: "k", customBase: "")
        XCTAssertEqual(anthropic.headers["x-api-key"], "k")
        XCTAssertTrue(anthropic.url.absoluteString.hasPrefix("https://api.anthropic.com/v1/models"))
        let google = try AISearchClient.listRequest(provider: .google, key: "g", customBase: "")
        XCTAssertEqual(google.headers["x-goog-api-key"], "g")
        XCTAssertThrowsError(try AISearchClient.listRequest(provider: .custom, key: nil, customBase: "http://x"))
    }

    func testAnswerText() {
        let data = Data("{\"choices\":[{\"message\":{\"content\":\"{}\"}}]}".utf8)
        XCTAssertEqual(AISearchClient.answerText(provider: .openai, data: data), "{}")
    }

    func testSettingsDefaultsAndModel() {
        var settings = AdvancedSearchSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.aiEngine, .networkOnly)
        XCTAssertTrue(settings.aiSuggestsTitles)
        XCTAssertEqual(settings.model(for: .anthropic), "claude-haiku-5-5")
        settings.setModel("  custom ", for: .anthropic)
        XCTAssertEqual(settings.model(for: .anthropic), "custom")
    }
}
