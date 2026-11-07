import XCTest
@testable import AetherCore

final class PersonProfileTests: XCTestCase {
    private func credits() throws -> TMDBPersonCredits {
        let json = """
        {"cast":[{"id":1,"media_type":"movie","title":"Iron Man","character":"Tony Stark","poster_path":"/a.jpg","release_date":"2008-04-30","popularity":90,"genre_ids":[28,878],"vote_average":7.6},
                 {"id":9,"media_type":"tv","name":"Late Show","character":"Self","poster_path":"/z.jpg","first_air_date":"2015-01-01","popularity":99,"genre_ids":[10767]},
                 {"id":3,"media_type":"movie","title":"No role","poster_path":"/n.jpg","release_date":"2001-01-01","popularity":5,"genre_ids":[18]}],
         "crew":[{"id":1,"media_type":"movie","title":"Iron Man","job":"Executive Producer","department":"Production","poster_path":"/a.jpg","release_date":"2008-04-30","popularity":90,"genre_ids":[28,878]},
                 {"id":2,"media_type":"movie","title":"Locke","job":"Director","department":"Directing","poster_path":"/b.jpg","release_date":"2013-04-25","popularity":40,"genre_ids":[18]},
                 {"id":4,"media_type":"movie","title":"Best boy","job":"Gaffer","department":"Lighting","poster_path":"/g.jpg","release_date":"2012-04-25","popularity":10,"genre_ids":[18]}]}
        """
        return try JSONDecoder().decode(TMDBPersonCredits.self, from: Data(json.utf8))
    }

    func testRolesAreMergedAndNoiseIsLeftOut() throws {
        let details = try JSONDecoder().decode(TMDBPersonDetails.self, from: Data(#"{"name":"R","biography":" Bio ","birthday":"1965-04-04","profile_path":"/p.jpg","known_for_department":"Acting"}"#.utf8))
        let profile = PersonProfile.make(details: details, credits: try credits(), fallbackName: "x")
        XCTAssertEqual(profile.filmography.map { $0.title }, ["Iron Man", "Locke"])
        XCTAssertEqual(profile.filmography[0].roles, [.actor, .producer])
        XCTAssertEqual(profile.filmography[0].character, "Tony Stark")
        XCTAssertEqual(profile.filmography[0].genres, ["Azione", "Fantascienza"])
        XCTAssertEqual(profile.roles, [.actor, .director, .producer])
        XCTAssertEqual(profile.biography, "Bio")
        XCTAssertEqual(profile.profession, "Attore/attrice")
        XCTAssertEqual(profile.photoURL, "https://image.tmdb.org/t/p/w500/p.jpg")
    }

    func testFilters() throws {
        let details = try JSONDecoder().decode(TMDBPersonDetails.self, from: Data("{}".utf8))
        let all = PersonProfile.make(details: details, credits: try credits(), fallbackName: "Nome").filmography
        XCTAssertEqual(PersonFilter(role: .director).apply(all).map { $0.title }, ["Locke"])
        XCTAssertEqual(PersonFilter(genre: "Fantascienza").apply(all).map { $0.title }, ["Iron Man"])
        XCTAssertEqual(PersonFilter(fromYear: 2010).apply(all).map { $0.title }, ["Locke"])
        XCTAssertEqual(PersonFilter(onlyMovies: false).apply(all).count, 0)
        XCTAssertEqual(PersonFilter.genres(in: all), ["Azione", "Dramma", "Fantascienza"])
    }

    func testLifeLine() {
        let profile = PersonProfile(name: "A", photoURL: nil, biography: "", birthday: "1965-04-04", deathday: nil, placeOfBirth: nil, profession: nil, filmography: [])
        let now = ISO8601DateFormatter().date(from: "2026-11-07T10:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertTrue(profile.lifeLine(calendar: calendar, now: now)?.hasSuffix("(61 anni)") ?? false)
    }
}
