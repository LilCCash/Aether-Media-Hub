import XCTest
@testable import Aether

final class KeychainSecretStoreTests: XCTestCase {
    private var store: KeychainSecretStore!

    override func setUp() {
        super.setUp()
        store = KeychainSecretStore(service: "app.aether.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        for key in (try? store.allKeys(prefix: "")) ?? [] { try? store.remove(key) }
        super.tearDown()
    }

    func testRoundTripUpdateAndRemove() throws {
        try store.set("https://addon.example/SECRET/manifest.json", for: "addon.1")
        XCTAssertEqual(try store.get("addon.1"), "https://addon.example/SECRET/manifest.json")
        try store.set("https://addon.example/OTHER/manifest.json", for: "addon.1")
        XCTAssertEqual(try store.get("addon.1"), "https://addon.example/OTHER/manifest.json")
        try store.remove("addon.1")
        XCTAssertNil(try store.get("addon.1"))
    }

    func testMissingKeyIsNilAndRemovingTwiceIsFine() throws {
        XCTAssertNil(try store.get("nope"))
        try store.remove("nope")
    }

    func testListsKeysByPrefix() throws {
        try store.set("a", for: "addon.1")
        try store.set("b", for: "addon.2")
        try store.set("c", for: "other.1")
        XCTAssertEqual(Set(try store.allKeys(prefix: "addon.")), ["addon.1", "addon.2"])
    }
}
