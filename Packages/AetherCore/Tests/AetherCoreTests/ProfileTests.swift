import XCTest
@testable import AetherCore

final class ProfileTests: XCTestCase {
    private func vote(_ id: String, _ verdict: TasteVerdict, genres: [String] = [], at: TimeInterval = 0) -> TasteVote {
        TasteVote(id: id, type: "movie", name: "T" + id, genres: genres, verdict: verdict, votedAt: Date(timeIntervalSince1970: at))
    }

    func testAVoteReplacesTheOldOneAndCanBeRemoved() {
        var profile = ProfileSettings()
        profile.vote(vote("a", .like, at: 1))
        profile.vote(vote("b", .dislike, at: 2))
        profile.vote(vote("a", .dislike, at: 3))
        XCTAssertEqual(profile.verdict(for: "a"), .dislike)
        XCTAssertEqual(profile.likes.count, 0)
        XCTAssertEqual(profile.dislikes.map { $0.id }, ["a", "b"], "newest first")
        profile.removeVote(id: "a")
        XCTAssertNil(profile.verdict(for: "a"))
    }

    func testSkippingKeepsAnOrderedBoundedList() {
        var profile = ProfileSettings()
        for index in 0..<450 { profile.skip("t\(index)") }
        XCTAssertEqual(profile.skipped.count, 400)
        XCTAssertEqual(profile.skipped.last, "t449")
        profile.skip("t100")
        XCTAssertEqual(profile.skipped.last, "t100")
        profile.vote(vote("t100", .like))
        XCTAssertFalse(profile.skipped.contains("t100"), "a vote ends the skip")
    }

    func testTheDeckLeavesOutWhatWasJudgedPassedOrHasNoPoster() {
        var profile = ProfileSettings()
        profile.vote(vote("seen", .like))
        profile.skip("passed")
        let items = [TasteCandidate(id: "seen", type: "movie", name: "A", poster: "p"), TasteCandidate(id: "passed", type: "movie", name: "B", poster: "p"),
                     TasteCandidate(id: "new", type: "movie", name: "C", poster: "p"), TasteCandidate(id: "new", type: "movie", name: "C", poster: "p"),
                     TasteCandidate(id: "nopic", type: "movie", name: "D"), TasteCandidate(id: "inlib", type: "movie", name: "E", poster: "p")]
        XCTAssertEqual(TasteEngine.deck(items, profile: profile, excluding: ["inlib"]).map { $0.id }, ["new"])
    }

    func testTopGenresCombineChoicesAndVotes() {
        var profile = ProfileSettings()
        profile.toggleGenre(.comedy)
        profile.vote(vote("a", .like, genres: ["Sci-Fi", "Action"]))
        profile.vote(vote("b", .like, genres: ["Sci-Fi"]))
        profile.vote(vote("c", .dislike, genres: ["Action", "Horror"]))
        XCTAssertEqual(TasteEngine.topGenres(profile), ["comedy", "scifi"], "comedy is chosen (+3), scifi liked twice, action nets 0, horror is negative")
        profile.toggleGenre(.comedy)
        XCTAssertFalse(profile.genres.contains("comedy"))
    }

    func testGenresAndAvatars() {
        XCTAssertEqual(ProfileGenre.from(cinemeta: "sci-fi"), .scifi)
        XCTAssertEqual(ProfileGenre.scifi.cinemeta, "Sci-Fi")
        XCTAssertEqual(ProfileGenre.action.cinemeta, "Action")
        XCTAssertGreaterThanOrEqual(ProfileAvatars.all.count, 16)
        XCTAssertEqual(Set(ProfileAvatars.all.map { $0.id }).count, ProfileAvatars.all.count)
        XCTAssertEqual(ProfileAvatars.avatar(id: "nonexistent").id, ProfileAvatars.all[0].id)
    }

    func testTheNameIsOnlyUsedWhenThereIsOne() throws {
        var profile = ProfileSettings()
        XCTAssertNil(profile.displayName)
        profile.name = "   "
        XCTAssertNil(profile.displayName)
        profile.name = " Sara "
        XCTAssertEqual(profile.displayName, "Sara")
        let decoded = try JSONDecoder().decode(ProfileSettings.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(try JSONDecoder().decode(ContentSettings.self, from: Data("{}".utf8)).profile, ProfileSettings())
        XCTAssertEqual(try JSONDecoder().decode(ProfileSettings.self, from: Data("{\"invitesPerWeek\":99}".utf8)).invitesPerWeek, 4)
    }
}

final class InvitePlannerTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    // Monday 2 November 2026, 08:00.
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-02T08:00:00Z")! }

    func testTwoAWeekFallOnFridayAndSunday() {
        let alerts = InvitePlanner.plan(now: now, name: nil, perWeek: 2, suggestions: [], days: 14, calendar: utc)
        XCTAssertEqual(alerts.count, 4)
        XCTAssertEqual(alerts.map { utc.component(.weekday, from: $0.fire) }, [6, 1, 6, 1])
        XCTAssertEqual(utc.component(.hour, from: alerts[0].fire), 20)
    }

    func testTheNameNeverAppearsWithoutOne() {
        let nameless = InvitePlanner.plan(now: now, name: nil, perWeek: 4, suggestions: [], calendar: utc)
        XCTAssertFalse(nameless.contains { ($0.title + $0.body).contains("Ehi") || $0.title.contains(",") })
        let named = InvitePlanner.plan(now: now, name: "Sara", perWeek: 4, suggestions: [], calendar: utc)
        XCTAssertTrue(named.contains { $0.title == "Ehi Sara" && $0.body == "Cosa guardiamo?" })
        XCTAssertFalse(nameless.map { $0.body }.isEmpty)
    }

    func testAJustOpenedAppSkipsTheNextFewHoursAndWeekendsGetTheBingeLine() {
        let friday = ISO8601DateFormatter().date(from: "2026-11-06T19:00:00Z")!    // slot 20:30 is under three hours away
        let alerts = InvitePlanner.plan(now: friday, name: nil, perWeek: 1, suggestions: [], days: 2, calendar: utc)
        XCTAssertTrue(alerts.isEmpty)
        let all = InvitePlanner.plan(now: now, name: nil, perWeek: 4, suggestions: [], days: 14, calendar: utc)
        XCTAssertTrue(all.contains { $0.body.contains("binge") })
    }

    func testEveryOtherInvitationSuggestsATitleWithItsGenre() {
        let suggestions = [InviteSuggestion(id: "tt1", type: "movie", name: "Alien", genre: "Fantascienza")]
        let alerts = InvitePlanner.plan(now: now, name: "Sara", perWeek: 4, suggestions: suggestions, days: 14, calendar: utc)
        let suggested = alerts.filter { $0.metaID != nil }
        XCTAssertFalse(suggested.isEmpty)
        XCTAssertEqual(suggested[0].metaID, "tt1")
        XCTAssertTrue(suggested[0].body.contains("«Alien»") && suggested[0].body.contains("fantascienza"))
        XCTAssertTrue(alerts.contains { $0.metaID == nil })
    }
}

final class YouTubeLinkTests: XCTestCase {
    func testTheIdIsFoundInTheCommonShapes() {
        XCTAssertEqual(YouTubeLink.id(from: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeLink.id(from: URL(string: "https://youtu.be/dQw4w9WgXcQ?t=3")!), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeLink.id(from: URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ")!), "dQw4w9WgXcQ")
        XCTAssertNil(YouTubeLink.id(from: URL(string: "https://evil.example/watch?v=dQw4w9WgXcQ")!))
        XCTAssertNil(YouTubeLink.id(from: URL(string: "https://www.youtube.com/watch?v=../x")!))
    }
}
