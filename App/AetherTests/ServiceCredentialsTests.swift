import XCTest
import AetherCore
@testable import Aether

@MainActor
final class ServiceCredentialsTests: XCTestCase {
    func testNothingIsConfiguredAtFirst() {
        let credentials = ServiceCredentials(secrets: InMemorySecretStore())
        XCTAssertTrue(credentials.configured.isEmpty)
        XCTAssertNil(credentials.secret(for: .torbox))
    }

    func testSavingStoresTheKeyInTheSecretStoreOnlyAndPublishesJustThePresence() throws {
        let store = InMemorySecretStore()
        let credentials = ServiceCredentials(secrets: store)
        try credentials.save("  abc-key  ", for: .torbox)
        XCTAssertTrue(credentials.isConfigured(.torbox))
        XCTAssertEqual(credentials.secret(for: .torbox), "abc-key", "the key is trimmed")
        XCTAssertEqual(try store.get(ServiceKind.torbox.keychainKey), "abc-key")
        XCTAssertFalse(credentials.isConfigured(.tmdb))
    }

    func testEmptyKeysAreRejected() {
        let credentials = ServiceCredentials(secrets: InMemorySecretStore())
        XCTAssertThrowsError(try credentials.save("   ", for: .tmdb))
        XCTAssertFalse(credentials.isConfigured(.tmdb))
    }

    func testRemovingTakesEffectImmediatelyEvenForAnAlreadyHandedOutProvider() throws {
        let credentials = ServiceCredentials(secrets: InMemorySecretStore())
        try credentials.save("k1", for: .tmdb)
        let provider = credentials.provider(for: .tmdb)
        XCTAssertEqual(provider(), "k1")
        credentials.remove(.tmdb)
        XCTAssertNil(provider(), "a provider reads the store every time, so a removed key is gone at once")
        XCTAssertFalse(credentials.isConfigured(.tmdb))
    }

    func testThePinIsOptionalAndRemovedWithTheKey() throws {
        let store = InMemorySecretStore()
        let credentials = ServiceCredentials(secrets: store)
        try credentials.save("key", for: .tvdb, pin: "1234")
        XCTAssertEqual(credentials.pin(for: .tvdb), "1234")
        try credentials.save("key", for: .tvdb)
        XCTAssertNil(credentials.pin(for: .tvdb), "saving without a pin clears the old one")
        try credentials.save("key", for: .tvdb, pin: "999")
        credentials.remove(.tvdb)
        XCTAssertNil(try store.get(ServiceKind.tvdb.pinKeychainKey))
    }

    func testKeychainAccountsAreDistinctAndOutsideTheAddonNamespace() {
        let accounts = ServiceKind.allCases.flatMap { [$0.keychainKey, $0.pinKeychainKey] }
        XCTAssertEqual(Set(accounts).count, accounts.count)
        XCTAssertFalse(accounts.contains(where: { $0.hasPrefix("addon.") }), "addon backups enumerate the addon. prefix: service keys must stay out of it")
    }
}
