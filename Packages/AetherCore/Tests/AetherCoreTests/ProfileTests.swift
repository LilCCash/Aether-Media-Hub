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
        XCTAssertEqual(try JSONDecoder().decode(ProfileSettings.self, from: Data("{\"invitesPerDay\":99}".utf8)).invitesPerDay, 6)
        XCTAssertEqual(try JSONDecoder().decode(ProfileSettings.self, from: Data("{\"invitesPerWeek\":2}".utf8)).invitesPerDay, 4, "an old file falls back to the default")
    }
}

final class InvitePlannerTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    // Monday 2 November 2026, 08:00.
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-02T08:00:00Z")! }

    func testFourADayAreSpreadOverTheDayAndFillTheHorizon() {
        let early = ISO8601DateFormatter().date(from: "2026-11-02T07:00:00Z")!
        let alerts = InvitePlanner.plan(now: early, name: nil, perDay: 4, suggestions: [], calendar: utc)
        // 10 days × 4 slots; the first slot is 2.5 hours away.
        XCTAssertEqual(alerts.count, 40)
        let hours = Set(alerts.prefix(4).map { utc.component(.hour, from: $0.fire) })
        XCTAssertEqual(hours, [9, 13, 18, 21])
        XCTAssertLessThanOrEqual(alerts.count, 60, "the system keeps 64 pending notifications")
        XCTAssertEqual(Set(alerts.map { $0.id }).count, alerts.count)
    }

    func testTheLinesFitTheHourOfTheDay() {
        let alerts = InvitePlanner.plan(now: now, name: nil, perDay: 4, suggestions: [], calendar: utc)
        let morning = alerts.filter { utc.component(.hour, from: $0.fire) == 9 }
        XCTAssertTrue(morning.allSatisfy { !$0.body.lowercased().contains("stasera") && !$0.body.lowercased().contains("dormire") })
        let night = alerts.filter { utc.component(.hour, from: $0.fire) == 21 }
        XCTAssertTrue(night.allSatisfy { !$0.body.lowercased().contains("buongiorno") && !$0.body.lowercased().contains("pausa pranzo") })
        XCTAssertGreaterThan(Set(alerts.map { $0.body }).count, 6, "not always the same words")
    }

    func testTheNameNeverAppearsWithoutOne() {
        let nameless = InvitePlanner.plan(now: now, name: nil, perDay: 6, suggestions: [], calendar: utc)
        XCTAssertFalse(nameless.contains { ($0.title + $0.body).contains("Ehi") || $0.title.contains(",") })
        let named = InvitePlanner.plan(now: now, name: "Sara", perDay: 6, suggestions: [], calendar: utc)
        XCTAssertTrue(named.contains { $0.title == "Ehi Sara" && $0.body == "Cosa guardiamo?" })
    }

    func testAJustOpenedAppSkipsTheNextHourAndAHalf() {
        let evening = ISO8601DateFormatter().date(from: "2026-11-06T20:00:00Z")!
        let alerts = InvitePlanner.plan(now: evening, name: nil, perDay: 1, suggestions: [], days: 1, calendar: utc)
        XCTAssertTrue(alerts.isEmpty, "the 20:30 slot is under 90 minutes away")
        let weekend = InvitePlanner.plan(now: now, name: nil, perDay: 4, suggestions: [], days: 10, calendar: utc)
        XCTAssertTrue(weekend.contains { $0.body.contains("binge") })
    }

    func testEveryOtherInvitationSuggestsATitleWithItsGenre() {
        let suggestions = [InviteSuggestion(id: "tt1", type: "movie", name: "Alien", genre: "Fantascienza")]
        let alerts = InvitePlanner.plan(now: now, name: "Sara", perDay: 4, suggestions: suggestions, days: 5, calendar: utc)
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
