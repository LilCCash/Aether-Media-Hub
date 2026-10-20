import XCTest
@testable import AetherCore

final class SubtitleCleanerTests: XCTestCase {
    private func clean(_ text: String) -> String { SubtitleCleaner.stripHearingImpaired(text) }

    func testSquareBracketAnnotationsAreRemoved() {
        XCTAssertEqual(clean("[door slams]"), "")
        XCTAssertEqual(clean("[door slams] Who's there?"), "Who's there?")
        XCTAssertEqual(clean("Hello [laughs] there"), "Hello there")
        XCTAssertEqual(clean("{music playing}\nHello"), "Hello")
    }

    func testParenthesesAtTheEdgesOfALineAreAnnotations() {
        XCTAssertEqual(clean("(sighs)"), "")
        XCTAssertEqual(clean("- (SIGHS) Fine."), "Fine.")
        XCTAssertEqual(clean("I'm leaving. (door closes)"), "I'm leaving.")
    }

    func testCapitalisedParenthesesInTheMiddleAreAnnotationsButNormalOnesAreNot() {
        XCTAssertEqual(clean("He said (LAUGHING) no"), "He said no")
        XCTAssertEqual(clean("Call me (maybe) tomorrow"), "Call me (maybe) tomorrow")
    }

    func testMusicSymbols() {
        XCTAssertEqual(clean("♪ ♪"), "")
        XCTAssertEqual(clean("♪ la la la ♪"), "la la la")
    }

    func testSpeakerLabels() {
        XCTAssertEqual(clean("JOHN: Where were you?"), "Where were you?")
        XCTAssertEqual(clean("- MARY JANE: Home."), "Home.")
        XCTAssertEqual(clean("Note: this stays"), "Note: this stays", "mixed case is ordinary text")
    }

    func testMultiLineCuesKeepTheirSpokenLines() {
        XCTAssertEqual(clean("[phone rings]\n- Hello?\n- (CLICK)"), "- Hello?")
    }

    func testPlainTextIsUntouched() {
        XCTAssertEqual(clean("Just a normal line."), "Just a normal line.")
        XCTAssertEqual(clean(""), "")
    }
}
