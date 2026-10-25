import XCTest
@testable import AetherCore

private final class RatingsStubHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [HTTPRequest] = []
    private let body: String
    private let status: Int

    init(body: String, status: Int = 200) {
        self.body = body
        self.status = status
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        seen.append(request)
        lock.unlock()
        return HTTPResponse(data: Data(body.utf8), statusCode: status, headers: [:], url: request.url)
    }
}

final class ExperienceSettingsTests: XCTestCase {
    // MARK: Catalog layout

    func testCatalogsFollowTheViewersOrderAndTheRestKeepsItsPlace() {
        var layout = CatalogLayoutSettings()
        let ids = ["a/top", "b/popular", "c/new", "d/old"]
        XCTAssertEqual(layout.sorted(ids, id: { $0 }), ids)
        layout.move(id: "c/new", by: -1, among: ids)
        XCTAssertEqual(layout.sorted(ids, id: { $0 }), ["a/top", "c/new", "b/popular", "d/old"])
        layout.move(id: "d/old", by: -1, among: ids)
        XCTAssertEqual(layout.sorted(ids, id: { $0 }), ["a/top", "c/new", "d/old", "b/popular"])
        XCTAssertFalse(layout.canMove(id: "a/top", by: -1, among: ids))
        XCTAssertTrue(layout.canMove(id: "a/top", by: 1, among: ids))
        // A catalog that is not there any more does not disturb the others, and a new one goes last.
        XCTAssertEqual(layout.sorted(["x/new", "c/new", "a/top"], id: { $0 }), ["a/top", "c/new", "x/new"])
    }

    func testACatalogCanBeRenamedAndTheNameRemoved() {
        var layout = CatalogLayoutSettings()
        XCTAssertEqual(layout.title(forID: "a/top", fallback: "Top"), "Top")
        layout.setTitle("  I miei film  ", forID: "a/top")
        XCTAssertEqual(layout.title(forID: "a/top", fallback: "Top"), "I miei film")
        layout.setTitle("   ", forID: "a/top")
        XCTAssertEqual(layout.title(forID: "a/top", fallback: "Top"), "Top")
        layout.setTitle(String(repeating: "x", count: 100), forID: "b/x")
        XCTAssertEqual(layout.customTitle(forID: "b/x")?.count, CatalogLayoutSettings.maxTitleLength)
    }

    func testOldSettingsFilesStillLoadWithTheNewDefaults() throws {
        let json = #"{"content":{"preferredLanguage":"it"}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.content.preferredLanguage, "it")
        XCTAssertTrue(settings.content.catalogLayout.order.isEmpty)
        XCTAssertTrue(settings.content.titleModules.collection)
        XCTAssertTrue(settings.content.ratings.enabled)
        XCTAssertEqual(settings.content.ratings.sources, ["imdb", "tomatoes", "metacritic", "tmdb"])
        XCTAssertFalse(settings.content.streamDisplay.showAddonLogo)
        XCTAssertNil(settings.appearance.customBackgroundHex)
        XCTAssertEqual(settings.appearance.backdropIntensity, 1)
    }

    func testTheNewSettingsSurviveEncoding() throws {
        var settings = AppSettings()
        settings.content.catalogLayout.setTitle("Mio", forID: "a/top")
        settings.content.catalogLayout.order = ["b", "a"]
        settings.content.streamDisplay.showAddonLogo = true
        settings.content.streamDisplay.setShown(false, .size)
        settings.content.streamDisplay.template = "{quality} · {size}"
        settings.content.titleModules.similar = false
        settings.content.ratings.setShown(false, .imdb)
        settings.appearance.customBackgroundHex = "#112233"
        settings.appearance.backdropIntensity = 0.4
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.content.catalogLayout.customTitle(forID: "a/top"), "Mio")
        XCTAssertEqual(back.content.catalogLayout.order, ["b", "a"])
        XCTAssertTrue(back.content.streamDisplay.showAddonLogo)
        XCTAssertFalse(back.content.streamDisplay.isShown(.size))
        XCTAssertEqual(back.content.streamDisplay.template, "{quality} · {size}")
        XCTAssertFalse(back.content.titleModules.similar)
        XCTAssertFalse(back.content.ratings.isShown(.imdb))
        XCTAssertEqual(back.appearance.customBackgroundHex, "#112233")
        XCTAssertEqual(back.appearance.backdropIntensity, 0.4, accuracy: 0.0001)
    }

    func testAMalformedBackgroundColourIsDropped() throws {
        let json = #"{"appearance":{"customBackgroundHex":"not a colour","backdropIntensity":7}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertNil(settings.appearance.customBackgroundHex)
        XCTAssertEqual(settings.appearance.backdropIntensity, 1)
    }

    // MARK: Sources

    private func analysed(_ name: String, details: String? = nil) -> (StreamInfo, AddonStream) {
        let stream = AddonStream(source: .url("https://cdn.test/movie.mkv"), name: name, details: details, behaviorHints: StreamBehaviorHints())
        return (StreamAnalyzer.analyze(stream), stream)
    }

    func testTheTemplateIsFilledAndEmptyWordsLeaveNoStraySeparators() {
        let (info, stream) = analysed("Film 2160p HEVC HDR10 DDP5.1")
        let line = StreamFormatter.line(template: "{quality} · {hdr} · {audio} · {size}", info: info, stream: stream)
        XCTAssertFalse(line.hasSuffix("·"))
        XCTAssertFalse(line.contains("·  ·"))
        XCTAssertFalse(line.contains("{"))
        XCTAssertEqual(StreamFormatter.tidy("1080p ·  · EAC3 · "), "1080p · EAC3")
        XCTAssertEqual(StreamFormatter.tidy(" / HEVC"), "HEVC")
        XCTAssertEqual(StreamFormatter.tidy("A - B"), "A - B")
        XCTAssertEqual(StreamFormatter.line(template: "{addon}", info: info, stream: stream), "")
    }

    func testBadgesCanBeSwitchedOffOneKindAtATime() {
        let (info, _) = analysed("Film 1080p HEVC")
        var settings = StreamDisplaySettings()
        let all = StreamFormatter.badges(for: info, settings: settings)
        XCTAssertTrue(all.contains(where: { $0.kind == .quality }))
        XCTAssertTrue(all.contains(where: { $0.kind == .codec }))
        settings.setShown(false, .codec)
        let fewer = StreamFormatter.badges(for: info, settings: settings)
        XCTAssertFalse(fewer.contains(where: { $0.kind == .codec }))
        XCTAssertTrue(fewer.contains(where: { $0.kind == .quality }))
        settings.setShown(true, .codec)
        XCTAssertTrue(settings.hiddenBadges.isEmpty)
    }

    // MARK: Ratings (MDBList)

    private let ratingsJSON = """
    {"title":"Film","ratings":[
      {"source":"imdb","value":7.7,"score":77,"votes":1000},
      {"source":"tomatoes","value":92,"score":92},
      {"source":"popcorn","value":88,"score":88},
      {"source":"metacritic","value":81,"score":81},
      {"source":"letterboxd","value":3.9,"score":78},
      {"source":"trakt","value":null,"score":null},
      {"source":"imdb","value":1,"score":10}]}
    """

    func testRatingsAreReadWrittenInTheirOwnScaleAndDeduplicated() async throws {
        let http = RatingsStubHTTP(body: ratingsJSON)
        let client = MDBListClient(http: http, credentials: { "secret" })
        let ratings = await client.ratings(tmdbID: 27205, isMovie: true)
        let byID = Dictionary(uniqueKeysWithValues: ratings.map { ($0.source, $0.display ?? "") })
        XCTAssertEqual(byID["imdb"], "7.7")
        XCTAssertEqual(byID["tomatoes"], "92%")
        XCTAssertEqual(byID["tomatoesaudience"], "88%")
        XCTAssertEqual(byID["metacritic"], "81")
        XCTAssertEqual(byID["letterboxd"], "3.9")
        XCTAssertNil(byID["trakt"], "a rating without a number is not shown")
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.path, "/tmdb/movie/27205")
        XCTAssertTrue(request.url.query?.contains("apikey=secret") == true)
        let show = MDBListClient(http: http, credentials: { "secret" })
        _ = await show.ratings(tmdbID: 1399, isMovie: false)
        XCTAssertEqual(http.requests.last?.url.path, "/tmdb/show/1399")
    }

    func testWithoutAKeyOrOnAFailureThereAreNoRatings() async {
        let http = RatingsStubHTTP(body: ratingsJSON)
        let noKey = MDBListClient(http: http, credentials: { nil })
        XCTAssertFalse(noKey.isConfigured)
        let none = await noKey.ratings(tmdbID: 1, isMovie: true)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
        let failing = MDBListClient(http: RatingsStubHTTP(body: "{}", status: 403), credentials: { "k" })
        let nothing = await failing.ratings(tmdbID: 1, isMovie: true)
        XCTAssertTrue(nothing.isEmpty)
        let result = await failing.check()
        XCTAssertFalse(result.isOK)
    }

    // MARK: Sagas

    func testASagaReadsItsPartsAndPosterURLs() throws {
        let json = #"{"name":"Saga","parts":[{"id":2,"title":"Due","poster_path":"/b.jpg","release_date":"2005-01-01","vote_average":7.1},{"id":1,"title":"Uno","poster_path":"/a.jpg","release_date":"2001-01-01"}]}"#
        let collection = try JSONDecoder().decode(TMDBCollection.self, from: Data(json.utf8))
        XCTAssertEqual(collection.parts.count, 2)
        XCTAssertEqual(PersonCredit.posterURL(collection.parts[0].posterPath), "https://image.tmdb.org/t/p/w342/b.jpg")
        XCTAssertNil(PersonCredit.posterURL("../x"))
        let details = try JSONDecoder().decode(TMDBRichDetails.self, from: Data(#"{"id":1,"belongs_to_collection":{"id":10,"name":"Saga"}}"#.utf8))
        XCTAssertEqual(details.collection?.id, 10)
        XCTAssertEqual(details.collection?.name, "Saga")
    }

    func testCinematicAndAmoledDefaultOffAndSurviveARoundTrip() throws {
        var settings = AppSettings()
        XCTAssertFalse(settings.appearance.dynamicCinematic)
        XCTAssertFalse(settings.appearance.amoled)
        settings.appearance.dynamicCinematic = true
        settings.appearance.amoled = true
        settings.appearance.cinematicMotion = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.appearance.dynamicCinematic)
        XCTAssertTrue(decoded.appearance.amoled)
        XCTAssertFalse(decoded.appearance.cinematicMotion)
        XCTAssertTrue(decoded.appearance.cinematicMood)
    }

    func testImportedBadgesParseAndMatchSources() {
        let json = #"{"badges":[{"name":"Remux","keywords":["remux"],"colour":"ff9500"},{"label":"Broken"},{"label":"HDR","match":"re:hdr10\\+?"}]}"#
        let rules = CustomBadgePack.parse(Data(json.utf8))
        XCTAssertEqual(rules.map { $0.label }, ["Remux", "HDR"])
        XCTAssertEqual(rules.first?.colorHex, "#FF9500")
        let stream = AddonStream(source: StreamSource.url("https://cdn.example.com/a.mkv"), name: "Film 2160p REMUX HDR10+")
        XCTAssertEqual(CustomBadgePack.badges(for: stream, rules: rules).count, 2)
        XCTAssertTrue(CustomBadgePack.parse(Data("nope".utf8)).isEmpty)
    }
}
