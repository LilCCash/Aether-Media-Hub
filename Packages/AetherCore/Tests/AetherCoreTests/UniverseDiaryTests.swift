import XCTest
@testable import AetherCore

final class UniverseDiaryTests: XCTestCase {
    func testTheDataIsConsistent() {
        XCTAssertGreaterThanOrEqual(UniverseCatalog.all.count, 12)
        XCTAssertEqual(Set(UniverseCatalog.all.map { $0.id }).count, UniverseCatalog.all.count)
        for universe in UniverseCatalog.all {
            let ids = universe.entries.map { $0.id }
            XCTAssertEqual(Set(ids).count, ids.count, "duplicates in \(universe.id)")
            XCTAssertTrue(ids.contains(universe.hero), "hero of \(universe.id)")
            for id in ids { XCTAssertNotNil(id.range(of: "^tt[0-9]{7,9}$", options: .regularExpression), id) }
            for id in universe.chronological ?? [] { XCTAssertTrue(ids.contains(id), "\(universe.id) \(id)") }
            XCTAssertEqual(universe.ordered(.chronological).count, ids.count)
            XCTAssertEqual(Set(universe.ordered(.chronological).map { $0.id }), Set(ids))
        }
    }

    func testOrdersAndTrust() throws {
        let mcu = try XCTUnwrap(UniverseCatalog.universe(id: "mcu"))
        XCTAssertEqual(mcu.ordered(.release).first?.name, "Iron Man")
        XCTAssertEqual(mcu.ordered(.chronological).first?.name, "Captain America: The First Avenger")
        XCTAssertEqual(mcu.trust(of: .release), .release)
        XCTAssertEqual(mcu.trust(of: .chronological), .editorial)
        let jurassic = try XCTUnwrap(UniverseCatalog.universe(id: "jurassic"))
        XCTAssertEqual(jurassic.trust(of: .chronological), .release)
        // A custom order lists what was arranged and the other titles follow.
        let ids = mcu.entries.map { $0.id }
        let custom = mcu.ordered(.custom, custom: [ids[5], ids[0]])
        XCTAssertEqual(custom.prefix(2).map { $0.id }, [ids[5], ids[0]])
        XCTAssertEqual(custom.count, ids.count)
    }

    func testProgress() throws {
        let potter = try XCTUnwrap(UniverseCatalog.universe(id: "hp"))
        let ids = potter.entries.map { $0.id }
        let progress = UniverseProgress.compute(potter, order: .release, watchedIDs: Set(ids.prefix(3)))
        XCTAssertEqual(progress.watched, 3)
        XCTAssertEqual(progress.next?.id, ids[3])
        XCTAssertEqual(progress.missing.count, ids.count - 3)
        XCTAssertFalse(progress.isComplete)
        XCTAssertTrue(UniverseProgress.compute(potter, order: .release, watchedIDs: Set(ids)).isComplete)
    }

    func testUniverseLookupByTitle() {
        XCTAssertEqual(UniverseCatalog.universes(containing: "tt0371746").map { $0.id }, ["mcu"])
        XCTAssertTrue(UniverseCatalog.universes(containing: "tt0000001").isEmpty)
    }

    func testDiaryStatsAndRewatch() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date: (Int, Int) -> Date = { calendar.date(from: DateComponents(year: $0, month: $1, day: 10, hour: 12))! }
        var diary = DiarySettings()
        diary.add(DiaryEntry(metaID: "tt1", type: "movie", name: "A", genres: ["Sci-Fi", "Azione"], watchedAt: date(2026, 1), rating: 8, runtimeMinutes: 120, people: ["X", "Y"]))
        diary.add(DiaryEntry(metaID: "tt1", type: "movie", name: "A", genres: ["Sci-Fi"], watchedAt: date(2026, 3), rating: 10, runtimeMinutes: 120, people: ["X"]))
        diary.add(DiaryEntry(metaID: "tt2", type: "series", name: "B", genres: ["Sci-Fi"], watchedAt: date(2025, 3), runtimeMinutes: 50))
        XCTAssertEqual(diary.entries.filter { $0.rewatch }.count, 1)
        let stats = DiaryStats.compute(diary.entries, year: 2026, calendar: calendar)
        XCTAssertEqual(stats.films, 2)
        XCTAssertEqual(stats.episodesAndSeries, 0)
        XCTAssertEqual(stats.hours, 4)
        XCTAssertEqual(stats.rewatches, 1)
        XCTAssertEqual(stats.averageRating, 4.5)
        XCTAssertEqual(stats.topGenres.first, DiaryStats.Count(name: "Sci-Fi", count: 2))
        XCTAssertEqual(stats.topPeople.first?.name, "X")
        XCTAssertEqual(stats.perMonth[0], 1)
        XCTAssertEqual(stats.perMonth[2], 1)
        XCTAssertEqual(DiaryStats.years(diary.entries, calendar: calendar), [2026, 2025])
        XCTAssertEqual(diary.timeline.first?.watchedAt, date(2026, 3))
    }

    func testSettingsRoundTripAndOldFilesStillDecode() throws {
        var content = ContentSettings()
        content.diary.add(DiaryEntry(metaID: "tt1", type: "movie", name: "A"))
        content.universes.toggleFollow("mcu")
        content.universes.customOrders["mcu"] = ["tt1"]
        let back = try JSONDecoder().decode(ContentSettings.self, from: JSONEncoder().encode(content))
        XCTAssertEqual(back.diary.entries.count, 1)
        XCTAssertEqual(back.universes.followed, ["mcu"])
        let old = try JSONDecoder().decode(ContentSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.diary.entries.isEmpty)
        XCTAssertTrue(old.universes.followed.isEmpty)
    }
}

final class SourceScoringTests: XCTestCase {
    private func stream(_ name: String, size: Int64? = nil) -> AddonStream {
        return AddonStream(source: .url("https://example.com/\(name.replacingOccurrences(of: " ", with: "_")).mp4"), name: name, details: name,
                           behaviorHints: StreamBehaviorHints(videoSize: size))
    }

    func testNeutralScoringChangesNothing() {
        let a = stream("Film 1080p"), b = stream("Film 2160p HDR10")
        let base = StreamSelector.rank([a, b], preferences: StreamPreferences())
        let same = StreamSelector.rank([a, b], preferences: StreamPreferences(scoring: SourceScoring()))
        XCTAssertEqual(base.map { $0.stream.name }, same.map { $0.stream.name })
        XCTAssertTrue(SourceScoring().isNeutral)
    }

    func testHDRWeightPromotesAHDRSource() {
        let plain = stream("Film 1080p x264"), dv = stream("Film 1080p DV HDR10 x265")
        var scoring = SourceScoring()
        scoring.hdr = 3
        let ranked = StreamSelector.rank([plain, dv], preferences: StreamPreferences(scoring: scoring))
        XCTAssertEqual(ranked.first?.stream.name, "Film 1080p DV HDR10 x265")
    }

    func testSizeAndCodecPreferences() {
        let big = stream("Film 1080p x264", size: 20 * 1_073_741_824), small = stream("Film 1080p x264 b", size: 2 * 1_073_741_824)
        var scoring = SourceScoring()
        scoring.size = .smaller
        scoring.sizeWeight = 3
        XCTAssertEqual(StreamSelector.rank([big, small], preferences: StreamPreferences(scoring: scoring)).first?.stream.name, "Film 1080p x264 b")
        scoring.size = .larger
        XCTAssertEqual(StreamSelector.rank([small, big], preferences: StreamPreferences(scoring: scoring)).first?.stream.name, "Film 1080p x264")
    }

    func testOldSettingsStillDecodeAndBadWeightsAreClamped() throws {
        let old = try JSONDecoder().decode(SourceScoring.self, from: Data(#"{"video":9,"hdr":-2,"size":"nonsense"}"#.utf8))
        XCTAssertEqual(old.video, 3)
        XCTAssertEqual(old.hdr, 0)
        XCTAssertEqual(old.size, .none)
    }
}

final class UniverseSearchTests: XCTestCase {
    func testSearchByUniverseOrTitle() {
        XCTAssertEqual(UniverseCatalog.search("marvel").first?.id, "mcu")
        XCTAssertEqual(UniverseCatalog.search("Prométhéus").first?.id, "alien")
        XCTAssertTrue(UniverseCatalog.search("x").isEmpty)
        XCTAssertTrue(UniverseCatalog.search("zzzzzz").isEmpty)
        XCTAssertEqual(UniverseCatalog.search("star wars").first?.id, "starwars")
    }

    func testPeopleSearchKeepsTheBestKnownWithAPhoto() throws {
        let json = #"{"results":[{"id":1,"name":"A","profile_path":"/a.jpg","known_for_department":"Acting","popularity":5},{"id":2,"name":"B","profile_path":null,"popularity":90},{"id":3,"name":"C","profile_path":"/c.jpg","known_for_department":"Directing","popularity":50}]}"#
        let found = PersonSearchResult.make(from: try JSONDecoder().decode(TMDBPersonSearch.self, from: Data(json.utf8)))
        XCTAssertEqual(found.map { $0.name }, ["C", "A"])
        XCTAssertEqual(found.first?.profession, "Regista")
    }
}

final class CollectionsTests: XCTestCase {
    func testCreateAddRemoveRename() throws {
        var settings = CollectionsSettings()
        let list = try XCTUnwrap(settings.create(name: "  Horror anni 80 "))
        XCTAssertEqual(list.name, "Horror anni 80")
        XCTAssertEqual(settings.create(name: "horror ANNI 80")?.id, list.id, "same name, same list")
        XCTAssertNil(settings.create(name: "   "))
        let item = CollectionItem(id: "tt1", type: "movie", name: "A")
        settings.add(item, to: list.id)
        settings.add(item, to: list.id)
        XCTAssertEqual(settings.collections[0].items.count, 1)
        XCTAssertEqual(settings.collections(containing: "tt1").map { $0.id }, [list.id])
        settings.rename(id: list.id, to: "Notte")
        XCTAssertEqual(settings.collections[0].name, "Notte")
        settings.remove(itemID: "tt1", from: list.id)
        XCTAssertTrue(settings.collections[0].items.isEmpty)
        settings.delete(id: list.id)
        XCTAssertTrue(settings.collections.isEmpty)
    }
}
