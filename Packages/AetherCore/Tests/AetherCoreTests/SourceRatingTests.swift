import XCTest
@testable import AetherCore

final class SourceRatingTests: XCTestCase {
    private let preferences = StreamPreferences(preferredLanguage: "it", capabilities: .avPlayerOnly)

    private func rating(_ url: String) -> SourceRating {
        let info = StreamAnalyzer.analyze(AddonStream(source: .url(url), name: "Test"), streamingServer: nil, capabilities: .avPlayerOnly)
        return SourceRating.rate(info, preferences: preferences)
    }

    func testARichSourceRatesHighWithReasons() {
        let good = rating("https://example.org/Film.2160p.HEVC.DV.Atmos.ITA.mp4")
        XCTAssertGreaterThanOrEqual(good.score, 80, "\(good)")
        XCTAssertTrue(good.reasons.contains(where: { $0.isPositive }))
        XCTAssertFalse(good.verdict.isEmpty)
    }

    func testAPoorerSourceRatesLower() {
        let good = rating("https://example.org/Film.1080p.H264.ITA.mp4")
        let weak = rating("https://example.org/Film.720p.H264.ENG.mp4")
        XCTAssertGreaterThan(good.score, weak.score)
        XCTAssertTrue(weak.reasons.contains(where: { !$0.isPositive }))
    }

    func testScoresStayBetweenZeroAndHundred() {
        for url in ["https://example.org/a.mp4", "https://example.org/Film.2160p.HEVC.DV.Atmos.ITA.mp4", "https://example.org/x"] {
            let value = rating(url).score
            XCTAssertTrue((0...100).contains(value), "\(url): \(value)")
        }
    }
}
