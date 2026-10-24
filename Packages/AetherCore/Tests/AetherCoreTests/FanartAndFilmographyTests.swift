import XCTest
@testable import AetherCore

private final class FanartStubHTTP: HTTPClient, @unchecked Sendable {
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

final class FanartAndFilmographyTests: XCTestCase {
    private let logos = """
    {"name":"Film","hdmovielogo":[
      {"id":"1","url":"https://assets.fanart.tv/fanart/movies/1/hdmovielogo/en.png","lang":"en","likes":"9"},
      {"id":"2","url":"https://assets.fanart.tv/fanart/movies/1/hdmovielogo/it.png","lang":"it","likes":"1"},
      {"id":"3","url":"http://assets.fanart.tv/insecure.png","lang":"it","likes":"50"},
      {"id":"4","url":"https://evil.example.com/it.png","lang":"it","likes":"99"}]}
    """

    func testTheLogoPrefersTheViewersLanguageAndOnlyComesFromFanartOverHTTPS() async throws {
        let http = FanartStubHTTP(body: logos)
        let client = FanartClient(http: http, credentials: { "my-key" })
        let url = await client.logoURL(kind: .movie, id: "tt0133093", language: "it-IT")
        XCTAssertEqual(url?.absoluteString, "https://assets.fanart.tv/fanart/movies/1/hdmovielogo/it.png")
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.path, "/v3/movies/tt0133093")
        XCTAssertTrue(request.url.query?.contains("api_key=my-key") == true)
    }

    func testWithoutAKeyNothingIsRequested() async {
        let http = FanartStubHTTP(body: logos)
        let client = FanartClient(http: http, credentials: { nil })
        XCTAssertFalse(client.isConfigured)
        let url = await client.logoURL(kind: .movie, id: "tt0133093", language: "it")
        XCTAssertNil(url)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAFailureOrAnOddAnswerMeansNoLogo() async {
        let failing = FanartClient(http: FanartStubHTTP(body: "{}", status: 401), credentials: { "k" })
        let none = await failing.logoURL(kind: .tv, id: "81189", language: "en")
        XCTAssertNil(none)
        let odd = FanartClient(http: FanartStubHTTP(body: "not json"), credentials: { "k" })
        let nothing = await odd.logoURL(kind: .tv, id: "81189", language: "en")
        XCTAssertNil(nothing)
    }

    func testAnIdThatIsNotPlainIsNeverPutInTheAddress() async {
        let http = FanartStubHTTP(body: logos)
        let client = FanartClient(http: http, credentials: { "k" })
        let url = await client.logoURL(kind: .movie, id: "../../etc", language: "it")
        XCTAssertNil(url)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAPersonsFilmographyKeepsTheRoleAndDropsTalkShowsAndEntriesWithoutRole() throws {
        let json = """
        {"cast":[
         {"id":1,"media_type":"movie","title":"Film A","character":"Bella","poster_path":"/a.jpg","release_date":"2023-12-08","popularity":50,"genre_ids":[18]},
         {"id":2,"media_type":"tv","name":"Talk","character":"Self","poster_path":"/t.jpg","popularity":90,"genre_ids":[10767]},
         {"id":3,"media_type":"movie","title":"Senza ruolo","character":"","poster_path":"/b.jpg","popularity":10,"genre_ids":[]},
         {"id":4,"media_type":"tv","name":"Serie B","character":"Anna","poster_path":"/c.jpg","first_air_date":"2020-01-01","popularity":70,"genre_ids":[18]},
         {"id":5,"media_type":"movie","title":"Senza locandina","character":"X","popularity":99,"genre_ids":[]}]}
        """
        let credits = try JSONDecoder().decode(TMDBPersonCredits.self, from: Data(json.utf8))
        let list = PersonCredit.make(from: credits)
        XCTAssertEqual(list.map { $0.title }, ["Serie B", "Film A"])
        XCTAssertEqual(list.first?.character, "Anna")
        XCTAssertEqual(list.first?.metaType, "series")
        XCTAssertEqual(list.last?.year, "2023")
        XCTAssertEqual(list.last?.posterURL, "https://image.tmdb.org/t/p/w342/a.jpg")
    }

    func testTheProvidersTextWinsOnlyWhenTheViewerAsksForIt() {
        let base = MetaItem(id: "tt1", type: "movie", name: "X", description: "English plot")
        var base2 = base
        base2.genres = ["Comedy"]
        let enrichment = MetadataEnrichment(overview: "Trama italiana", genres: ["Commedia"])
        XCTAssertEqual(base2.merging(enrichment: enrichment).description, "English plot")
        XCTAssertEqual(base2.merging(enrichment: enrichment).genres, ["Comedy"])
        let preferred = base2.merging(enrichment: enrichment, preferProviderText: true)
        XCTAssertEqual(preferred.description, "Trama italiana")
        XCTAssertEqual(preferred.genres, ["Commedia"])
        let empty = base2.merging(enrichment: MetadataEnrichment(), preferProviderText: true)
        XCTAssertEqual(empty.description, "English plot")
    }

    func testABackupCarriesTheServiceKeysOnlyWhenAsked() throws {
        let plain = AetherBackup(appVersion: "1.4", library: LibraryState(), settings: nil, addons: [], includesAddonURLs: false)
        let decodedPlain = try BackupCodec.decode(try BackupCodec.encode(plain))
        XCTAssertNil(decodedPlain.serviceKeys)
        let withKeys = AetherBackup(appVersion: "1.4", library: LibraryState(), settings: nil, addons: [], includesAddonURLs: false,
                                    serviceKeys: ["tmdb": "k1", "torbox": "k2"])
        let decoded = try BackupCodec.decode(try BackupCodec.encode(withKeys))
        XCTAssertEqual(decoded.serviceKeys, ["tmdb": "k1", "torbox": "k2"])
    }
}
