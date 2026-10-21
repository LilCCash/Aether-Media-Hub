import XCTest
import CoreGraphics
@testable import Aether

final class LogoTapTrackerTests: XCTestCase {
    private func series(_ count: Int, start: TimeInterval = 100, gap: TimeInterval = 0.2,
                        tracker: inout LogoTapTracker) -> [LogoTapTracker.Outcome] {
        var outcomes: [LogoTapTracker.Outcome] = []
        for index in 0..<count {
            outcomes.append(tracker.register(at: start + Double(index) * gap))
        }
        return outcomes
    }

    func testSevenQuickTapsPopOnTheSeventh() {
        var tracker = LogoTapTracker()
        let outcomes = series(7, tracker: &tracker)
        XCTAssertEqual(outcomes, [.heat(level: 1), .heat(level: 2), .heat(level: 3), .heat(level: 4), .heat(level: 5), .heat(level: 6),
                                  .pop(popCount: 1)])
    }

    func testAGapJustUnderTheWindowKeepsCounting() {
        var tracker = LogoTapTracker()
        _ = tracker.register(at: 10)
        XCTAssertEqual(tracker.register(at: 10 + LogoTapTracker.resetWindow - 0.01), .heat(level: 2))
    }

    func testAGapOfTheWindowOrMoreStartsOver() {
        var tracker = LogoTapTracker()
        _ = tracker.register(at: 10)
        _ = tracker.register(at: 10.2)
        XCTAssertEqual(tracker.register(at: 10.2 + LogoTapTracker.resetWindow), .heat(level: 1))
        XCTAssertEqual(tracker.register(at: 10.2 + LogoTapTracker.resetWindow + 0.2), .heat(level: 2))
    }

    func testAClockThatGoesBackwardsStartsOver() {
        var tracker = LogoTapTracker()
        _ = tracker.register(at: 50)
        _ = tracker.register(at: 50.1)
        XCTAssertEqual(tracker.register(at: 20), .heat(level: 1))
    }

    func testTheVoiceOverWindowAcceptsASlowPress() {
        var normal = LogoTapTracker()
        _ = normal.register(at: 10)
        XCTAssertEqual(normal.register(at: 13), .heat(level: 1), "3 s is a pause with the default window")
        var slow = LogoTapTracker()
        _ = slow.register(at: 10, window: LogoTapTracker.voiceOverWindow)
        XCTAssertEqual(slow.register(at: 13, window: LogoTapTracker.voiceOverWindow), .heat(level: 2))
    }

    func testTapsDuringTheRestAfterAPopAreIgnored() {
        var tracker = LogoTapTracker()
        _ = series(7, start: 100, tracker: &tracker)          // pops at 101.2
        XCTAssertEqual(tracker.register(at: 101.4), .ignored)
        XCTAssertEqual(tracker.register(at: 101.6), .ignored)
        XCTAssertEqual(tracker.register(at: 101.2 + LogoTapTracker.cooldown - 0.01), .ignored)
    }

    func testANewSeriesWorksAfterTheRest() {
        var tracker = LogoTapTracker()
        _ = series(7, start: 100, tracker: &tracker)
        let later = 101.2 + LogoTapTracker.cooldown + 0.5
        XCTAssertEqual(tracker.register(at: later), .heat(level: 1))
        let second = series(6, start: later + 0.2, tracker: &tracker)
        XCTAssertEqual(second.last, .pop(popCount: 2))
        XCTAssertEqual(tracker.popCount, 2)
    }

    func testHammeringDoesNotPopTwice() {
        var tracker = LogoTapTracker()
        let outcomes = series(40, start: 100, gap: 0.05, tracker: &tracker)
        let pops = outcomes.filter { if case .pop = $0 { return true } else { return false } }
        XCTAssertEqual(pops.count, 1, "40 taps in two seconds fall inside the rest after the first pop")
    }

    func testCoolingDownForgetsTheTaps() {
        var tracker = LogoTapTracker()
        _ = series(4, tracker: &tracker)
        tracker.cooldownElapsed()
        XCTAssertEqual(tracker.taps, 0)
        XCTAssertEqual(tracker.register(at: 100.9), .heat(level: 1))
    }

    func testHapticsGrowWithTheHeat() {
        let values = (1...6).map { LogoHaptics.intensity(forHeat: $0) }
        XCTAssertEqual(values, values.sorted())
        XCTAssertTrue(values.allSatisfy { $0 > 0 && $0 <= 1 })
        XCTAssertEqual(LogoHaptics.intensity(forHeat: 0), values.first)
        XCTAssertEqual(LogoHaptics.intensity(forHeat: 99), values.last)
    }
}

final class LogoEasterEggTextTests: XCTestCase {
    func testOnlySomeHeatLevelsTalk() {
        XCTAssertNotNil(LogoEasterEggText.heat(level: 3))
        XCTAssertNotNil(LogoEasterEggText.heat(level: 5))
        for level in [1, 2, 4, 6] { XCTAssertNil(LogoEasterEggText.heat(level: level)) }
    }

    func testThePopMessagesRotateAndAreNeverEmpty() {
        let pool = LogoEasterEggText.pops
        XCTAssertGreaterThan(pool.count, 3)
        XCTAssertEqual(Set(pool).count, pool.count)
        for count in 1...(pool.count * 2 + 1) {
            let text = LogoEasterEggText.pop(count: count, unlockedNow: false)
            XCTAssertFalse(text.isEmpty)
            XCTAssertEqual(text, pool[(count - 1) % pool.count])
        }
    }

    func testTheFirstUnlockSaysWhereTheThemeWent() {
        let first = LogoEasterEggText.pop(count: 1, unlockedNow: true)
        XCTAssertTrue(first.hasSuffix(LogoEasterEggText.unlockLine))
        XCTAssertTrue(first.contains("Popcorn"))
        XCTAssertFalse(LogoEasterEggText.pop(count: 2, unlockedNow: false).contains("sbloccato"))
    }

    func testMessagesAreShortEnoughForABanner() {
        for text in LogoEasterEggText.pops { XCTAssertLessThan(text.count, 60) }
    }
}

final class PopcornShowerTests: XCTestCase {
    private let screen = CGSize(width: 393, height: 852)
    private let origin = CGPoint(x: 196, y: 180)

    func testTheSameSeedGivesTheSamePieces() {
        XCTAssertEqual(PopcornShower(seed: 42, count: 30).pieces, PopcornShower(seed: 42, count: 30).pieces)
        XCTAssertNotEqual(PopcornShower(seed: 42, count: 30).pieces, PopcornShower(seed: 43, count: 30).pieces)
    }

    func testTheCountIsClamped() {
        XCTAssertEqual(PopcornShower(seed: 1, count: -5).pieces.count, 0)
        XCTAssertEqual(PopcornShower(seed: 1, count: 500).pieces.count, 60)
        XCTAssertEqual(PopcornShower(seed: 0, count: 12).pieces.count, 12, "seed zero is allowed")
    }

    func testPiecesLeaveTheLogoUpwardsAndAreFinite() {
        let shower = PopcornShower(seed: 7, count: 40)
        for piece in shower.pieces {
            XCTAssertLessThan(piece.vy, 0, "every piece is thrown upwards")
            XCTAssertGreaterThanOrEqual(piece.delay, 0)
            XCTAssertLessThan(piece.delay, 0.5)
            XCTAssertTrue((0.7...1.3).contains(piece.scale))
            XCTAssertTrue(PopcornShower.glyphs.indices.contains(piece.glyph))
            let start = shower.position(of: piece, at: piece.delay, origin: origin, in: screen)
            XCTAssertEqual(start?.x ?? .nan, origin.x, accuracy: 0.001, "a piece starts at the logo")
            XCTAssertEqual(start?.y ?? .nan, origin.y, accuracy: 0.001)
        }
    }

    func testNothingIsDrawnBeforeAPieceLeaves() {
        let shower = PopcornShower(seed: 7, count: 40)
        for piece in shower.pieces where piece.delay > 0.05 {
            XCTAssertNil(shower.position(of: piece, at: piece.delay - 0.01, origin: origin, in: screen))
        }
    }

    func testPositionsStayInsideTheSidesAndEverythingIsGoneByTheEnd() {
        let shower = PopcornShower(seed: 99, count: 60)
        var t = 0.0
        while t <= PopcornShower.duration {
            for piece in shower.pieces {
                if let point = shower.position(of: piece, at: t, origin: origin, in: screen) {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                    XCTAssertGreaterThanOrEqual(point.x, 0)
                    XCTAssertLessThanOrEqual(point.x, screen.width)
                }
            }
            t += 0.05
        }
        for piece in shower.pieces {
            // By the end of the show every piece has fallen out of the bottom of the screen.
            XCTAssertNil(shower.position(of: piece, at: PopcornShower.duration - 0.001, origin: origin, in: screen),
                         "a piece is still on screen at the end")
            XCTAssertNil(shower.position(of: piece, at: PopcornShower.duration + 1, origin: origin, in: screen))
        }
    }

    func testPiecesRiseAboveTheLogoBeforeFalling() {
        let shower = PopcornShower(seed: 5, count: 30)
        var rose = 0
        for piece in shower.pieces {
            if let point = shower.position(of: piece, at: piece.delay + 0.15, origin: origin, in: screen), point.y < origin.y { rose += 1 }
        }
        XCTAssertEqual(rose, shower.pieces.count)
    }
}
