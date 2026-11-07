import XCTest
@testable import AetherCore

final class AddonBodyCleaningTests: XCTestCase {
    func testByteOrderMarkAndBlanksAreRemoved() {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("  \n{\"metas\":[]}".utf8))
        XCTAssertEqual(String(data: AddonClient.cleanedJSON(data), encoding: .utf8), "{\"metas\":[]}")
    }

    func testAShortPrefixBeforeTheObjectIsDropped() {
        let data = Data("callback({\"metas\":[]})".utf8)
        XCTAssertEqual(String(data: AddonClient.cleanedJSON(data), encoding: .utf8), "{\"metas\":[]}")
    }

    func testHtmlIsRecognisedAndLeftAlone() {
        let page = Data("\n<!DOCTYPE html><html></html>".utf8)
        XCTAssertTrue(AddonClient.looksLikeHTML(page))
        XCTAssertTrue(AddonClient.looksLikeHTML(AddonClient.cleanedJSON(page)))
        XCTAssertFalse(AddonClient.looksLikeHTML(Data("{\"a\":1}".utf8)))
    }
}
