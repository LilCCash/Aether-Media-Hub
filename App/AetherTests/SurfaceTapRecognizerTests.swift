import XCTest
@testable import Aether

/// What a tap on the video does: the first tap answers at once, a double tap is two quick taps.
final class SurfaceTapRecognizerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testTheFirstTapOnHiddenControlsShowsThemAtOnce() {
        var recognizer = SurfaceTapRecognizer()
        XCTAssertEqual(recognizer.register(at: start, canDoubleTap: true, isLocked: false, controlsVisible: false), .toggleNow)
    }

    func testATapOnVisibleControlsHidesThemAfterTheDoubleTapWindow() {
        var recognizer = SurfaceTapRecognizer()
        XCTAssertEqual(recognizer.register(at: start, canDoubleTap: true, isLocked: false, controlsVisible: true), .hideAfterWindow)
    }

    func testTwoQuickTapsAreADoubleTapThatPutsAwayControlsTheFirstTapShowed() {
        var recognizer = SurfaceTapRecognizer()
        XCTAssertEqual(recognizer.register(at: start, canDoubleTap: true, isLocked: false, controlsVisible: false), .toggleNow)
        // the first tap showed the controls; the second tap finds them visible
        XCTAssertEqual(recognizer.register(at: start.addingTimeInterval(0.1), canDoubleTap: true, isLocked: false, controlsVisible: true),
                       .doubleTap(restoreHidden: true))
    }

    func testADoubleTapOnVisibleControlsLeavesThemAlone() {
        var recognizer = SurfaceTapRecognizer()
        _ = recognizer.register(at: start, canDoubleTap: true, isLocked: false, controlsVisible: true)
        XCTAssertEqual(recognizer.register(at: start.addingTimeInterval(0.1), canDoubleTap: true, isLocked: false, controlsVisible: true),
                       .doubleTap(restoreHidden: false))
    }

    func testASecondTapAfterTheWindowIsANewFirstTap() {
        var recognizer = SurfaceTapRecognizer()
        _ = recognizer.register(at: start, canDoubleTap: true, isLocked: false, controlsVisible: false)
        XCTAssertEqual(recognizer.register(at: start.addingTimeInterval(SurfaceTapRecognizer.doubleTapWindow + 0.05),
                                           canDoubleTap: true, isLocked: false, controlsVisible: true),
                       .hideAfterWindow)
    }

    func testAThirdQuickTapStartsOverInsteadOfBeingAnotherDoubleTap() {
        var recognizer = SurfaceTapRecognizer()
        _ = recognizer.register(at: start, canDoubleTap: true, isLocked: false, controlsVisible: true)
        _ = recognizer.register(at: start.addingTimeInterval(0.1), canDoubleTap: true, isLocked: false, controlsVisible: true)
        XCTAssertEqual(recognizer.register(at: start.addingTimeInterval(0.2), canDoubleTap: true, isLocked: false, controlsVisible: true),
                       .hideAfterWindow)
    }

    func testWithGesturesOffEveryTapActsAtOnceAndNeverCountsAsADoubleTap() {
        var recognizer = SurfaceTapRecognizer()
        XCTAssertEqual(recognizer.register(at: start, canDoubleTap: false, isLocked: false, controlsVisible: true), .hideNow)
        XCTAssertEqual(recognizer.register(at: start.addingTimeInterval(0.05), canDoubleTap: false, isLocked: false, controlsVisible: false), .toggleNow)
    }

    func testWhileLockedATapOnlyAsksForTheUnlockHint() {
        var recognizer = SurfaceTapRecognizer()
        XCTAssertEqual(recognizer.register(at: start, canDoubleTap: false, isLocked: true, controlsVisible: false), .toggleNow)
        XCTAssertEqual(recognizer.register(at: start.addingTimeInterval(0.05), canDoubleTap: false, isLocked: true, controlsVisible: false), .toggleNow)
    }
}
