import XCTest
import SwiftUI
@testable import Aether

final class ColorHexTests: XCTestCase {
    func testRoundTrip() {
        for hex in ["#FFFFFF", "#000000", "#FF8800", "#1E90FF", "#7F7F7F"] {
            XCTAssertEqual(Color(hex: hex).hexString, hex, hex)
        }
    }

    func testPrefixIsOptionalAndCaseInsensitive() {
        XCTAssertEqual(Color(hex: "ff8800").hexString, "#FF8800")
    }

    func testGarbageFallsBackToWhite() {
        XCTAssertEqual(Color(hex: "not a colour").hexString, "#FFFFFF")
        XCTAssertEqual(Color(hex: "#12").hexString, "#FFFFFF")
    }
}
