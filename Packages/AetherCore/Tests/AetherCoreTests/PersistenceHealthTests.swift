import XCTest
@testable import AetherCore

final class PersistenceHealthTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("health-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAFailedLibraryWriteIsKeptPendingReportedAndWrittenLater() async throws {
        // A file where the store's folder should be: the folder cannot be created, so the write fails.
        let blocker = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let health = PersistenceHealth()
        let file = JSONFileStore<LibraryState>(url: blocker.appendingPathComponent("library.json"), label: "la libreria", health: health)
        let store = LibraryStore(store: file, saveDelaySeconds: 0.01, retryDelaySeconds: 60)
        let meta = MetaItem(id: "tt0000001", type: "movie", name: "Film Uno")
        await store.setWatchlist(true, meta: meta)
        await store.flush()
        let problem = await store.saveProblem
        XCTAssertNotNil(problem)
        XCTAssertNotNil(health.current["la libreria"])

        // The folder becomes writable: the pending change is written at the next flush, nothing was lost.
        try FileManager.default.removeItem(at: blocker)
        await store.flush()
        let cleared = await store.saveProblem
        XCTAssertNil(cleared)
        XCTAssertNil(health.current["la libreria"])
        let saved = try XCTUnwrap(file.load())
        XCTAssertEqual(saved.entries["tt0000001"]?.inWatchlist, true)
    }

    func testTheHandlerHearsOnlyChanges() {
        let health = PersistenceHealth()
        let calls = Counter()
        health.onChange { _ in calls.increment() }
        health.report("gli addon", error: nil)
        XCTAssertEqual(calls.value, 0)
        health.report("gli addon", error: CocoaError(.fileWriteOutOfSpace))
        health.report("gli addon", error: CocoaError(.fileWriteOutOfSpace))
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(health.current["gli addon"], "spazio esaurito sul telefono")
        health.report("gli addon", error: nil)
        XCTAssertEqual(calls.value, 2)
        XCTAssertTrue(health.current.isEmpty)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}
