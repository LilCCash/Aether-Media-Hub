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

final class WikidataAndCollaboratorsTests: XCTestCase {
    func testAwardsAreReadWithYearsAndNames() throws {
        let claims = #"""
        {"entities":{"Q1":{"claims":{"P166":[
          {"mainsnak":{"datavalue":{"value":{"id":"Q10"}}},"qualifiers":{"P585":[{"datavalue":{"value":{"time":"+2005-02-27T00:00:00Z"}}}]}},
          {"mainsnak":{"datavalue":{"value":{"id":"Q11"}}}},
          {"mainsnak":{"datavalue":{"value":{"id":"not-an-id"}}}}]}}}}
        """#
        let found = WikidataClient.awardClaims(Data(claims.utf8), personID: "Q1")
        XCTAssertEqual(found.map { $0.id }, ["Q10", "Q11"])
        XCTAssertEqual(found[0].year, 2005)
        let labels = #"{"entities":{"Q10":{"labels":{"it":{"value":"Premio Oscar"},"en":{"value":"Academy Award"}}},"Q11":{"labels":{"en":{"value":"Golden Globe"}}}}}"#
        let awards = WikidataClient.awards(from: found, labels: Data(labels.utf8), preferring: ["it", "en"], limit: 10)
        XCTAssertEqual(awards.map { $0.line }, ["Premio Oscar (2005)", "Golden Globe"])
        XCTAssertEqual(WikidataClient.awards(from: found, labels: Data(labels.utf8), preferring: ["it"], limit: 10).map { $0.title }, ["Premio Oscar"])
    }

    func testCollaboratorsNeedTwoSharedTitlesAndAPhoto() throws {
        func credits(_ json: String) throws -> TMDBCredits { return try JSONDecoder().decode(TMDBCredits.self, from: Data(json.utf8)) }
        let a = try credits(#"{"cast":[{"id":1,"name":"Lui"},{"id":2,"name":"Amica","profile_path":"/a.jpg"},{"id":3,"name":"Una volta","profile_path":"/b.jpg"}]}"#)
        let b = try credits(#"{"cast":[{"id":2,"name":"Amica","profile_path":"/a.jpg"},{"id":1,"name":"Lui"}]}"#)
        let c = try credits(#"{"cast":[{"id":9,"name":"Altro","profile_path":"/z.jpg"}]}"#)
        let found = PersonProfile.collaborators(of: 1, titles: [("Film A", a), ("Film B", b), ("Film C", c)])
        XCTAssertEqual(found.map { $0.name }, ["Amica"])
        XCTAssertEqual(found[0].shared, ["Film A", "Film B"])
        XCTAssertEqual(found[0].photoURL, "https://image.tmdb.org/t/p/w185/a.jpg")
    }

    func testWikidataIDsAreValidated() throws {
        let ok = try JSONDecoder().decode(TMDBPersonExternalIDs.self, from: Data(#"{"wikidata_id":"Q37175"}"#.utf8))
        XCTAssertEqual(ok.wikidataID, "Q37175")
        let bad = try JSONDecoder().decode(TMDBPersonExternalIDs.self, from: Data(#"{"wikidata_id":"Q1&x=y"}"#.utf8))
        XCTAssertNil(bad.wikidataID)
    }
}

final class AIAskRequestTests: XCTestCase {
    func testOnlyTheSearchAsksForJSON() throws {
        func body(_ jsonMode: Bool) throws -> [String: Any] {
            let request = try AISearchClient.request(provider: .openai, model: "m", key: "k", customBase: "", system: "s", user: "u", timeout: 10, jsonMode: jsonMode)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        }
        XCTAssertNotNil(try body(true)["response_format"])
        XCTAssertNil(try body(false)["response_format"], "a chat answer is free text")
    }
}
