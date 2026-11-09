import XCTest
@testable import AetherCore

final class SeriesRecapTests: XCTestCase {
    private func series() -> MetaItem {
        var meta = MetaItem(id: "tt1", type: "series", name: "Serie")
        meta.videos = (1...12).map { number in
            Video(id: "tt1:1:\(number)", title: "Episodio \(number)", season: 1, episode: number,
                  overview: number == 3 ? "breve" : "Trama dell'episodio numero \(number), con abbastanza parole.")
        }
        return meta
    }

    func testOnlyWatchedEpisodesWithAPlotInOrderAndAtMostTheLatestEight() {
        let watched = Set((1...11).map { "tt1:1:\($0)" })
        let episodes = SeriesRecap.episodes(of: series(), watched: watched)
        XCTAssertEqual(episodes.count, SeriesRecap.maxEpisodes)
        XCTAssertEqual(episodes.last?.label, "S01E11")
        XCTAssertFalse(episodes.contains(where: { $0.label == "S01E12" }), "an episode not watched must never be summarised")
        XCTAssertFalse(episodes.contains(where: { $0.label == "S01E03" }), "a plot too short says nothing")
    }

    func testOfferedOnlyAfterAPauseAndEnoughEpisodes() {
        let now = Date()
        XCTAssertTrue(SeriesRecap.shouldOffer(watchedCount: 5, lastWatched: now.addingTimeInterval(-30 * 86_400), now: now))
        XCTAssertFalse(SeriesRecap.shouldOffer(watchedCount: 5, lastWatched: now.addingTimeInterval(-2 * 86_400), now: now))
        XCTAssertFalse(SeriesRecap.shouldOffer(watchedCount: 2, lastWatched: now.addingTimeInterval(-90 * 86_400), now: now))
        XCTAssertFalse(SeriesRecap.shouldOffer(watchedCount: 5, lastWatched: nil, now: now))
    }

    func testThePromptCarriesTheEpisodesAndNothingElse() {
        let episodes = [SeriesRecap.Episode(label: "S01E01", title: "Pilota", overview: "Tutto comincia.")]
        let prompt = SeriesRecap.prompt(series: "Serie", episodes: episodes)
        XCTAssertTrue(prompt.contains("S01E01 «Pilota»: Tutto comincia."))
        XCTAssertTrue(SeriesRecap.instructions.contains("SOLO"))
    }
}
