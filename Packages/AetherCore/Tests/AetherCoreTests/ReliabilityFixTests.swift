import XCTest
@testable import AetherCore

/// Regression tests for the next-gen reliability fixes (limiter cancellation, queue deadline, cache budgets).
final class ReliabilityFixTests: XCTestCase {
    private actor Gate {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() { open = true; waiting.forEach { $0.resume() }; waiting.removeAll() }
    }

    private actor Counter {
        var value = 0
        func bump() { value += 1 }
    }

    func testCancelledWaitersLeaveTheQueueWithoutRunning() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let gate = Gate()
        let ran = Counter()
        let holder = Task { try await limiter.withPermit { await gate.wait() } }
        while await limiter.activeCount == 0 { await Task.yield() }

        var waiters: [Task<Void, Error>] = []
        for _ in 0..<200 {
            waiters.append(Task { try await limiter.withPermit { await ran.bump() } })
        }
        while await limiter.waitingCount < 200 { await Task.yield() }
        waiters.forEach { $0.cancel() }
        for waiter in waiters {
            do { try await waiter.value; XCTFail("a cancelled waiter must throw") } catch is CancellationError {}
        }
        let left = await limiter.waitingCount
        XCTAssertEqual(left, 0, "cancelled waiters are removed at once, not when a permit frees up")

        await gate.release()
        try await holder.value
        let ranCount = await ran.value
        XCTAssertEqual(ranCount, 0)
        // No permit was lost or duplicated: the limiter is fully available again.
        let active = await limiter.activeCount
        XCTAssertEqual(active, 0)
        let value = try await limiter.withPermit { 42 }
        XCTAssertEqual(value, 42)
    }

    func testQueueWaitIsBoundedByMaxWait() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let gate = Gate()
        let holder = Task { try await limiter.withPermit { await gate.wait() } }
        while await limiter.activeCount == 0 { await Task.yield() }
        let start = Date()
        do {
            _ = try await limiter.withPermit(maxWait: 0.2) { 1 }
            XCTFail("expected a timeout")
        } catch let error as AddonError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let waiting = await limiter.waitingCount
        XCTAssertEqual(waiting, 0)
        await gate.release()
        try await holder.value
        let active = await limiter.activeCount
        XCTAssertEqual(active, 0)
    }

    func testFIFOOrderAndLimitSurviveMixedCancellation() async throws {
        let limiter = ConcurrencyLimiter(limit: 2)
        actor Peak { var now = 0; var peak = 0
            func enter() { now += 1; peak = max(peak, now) }
            func leave() { now -= 1 } }
        let peak = Peak()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<60 {
                let task = Task {
                    try await limiter.withPermit {
                        await peak.enter()
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        await peak.leave()
                    }
                }
                if index % 3 == 0 { task.cancel() }
                group.addTask { _ = try? await task.value }
            }
            try await group.waitForAll()
        }
        let maxSeen = await peak.peak
        XCTAssertLessThanOrEqual(maxSeen, 2)
        let active = await limiter.activeCount
        let waiting = await limiter.waitingCount
        XCTAssertEqual(active, 0)
        XCTAssertEqual(waiting, 0)
    }

    func testMemoryByteBudgetEvictsLeastRecentlyUsed() async {
        let cache = ResponseCache(directory: nil, maxMemoryEntries: 100, maxMemoryBytes: 1000)
        for index in 0..<5 { await cache.store(key: "k\(index)", data: Data(count: 300), kind: .stream) }
        let bytes = await cache.memoryByteCount
        XCTAssertLessThanOrEqual(bytes, 1000)
        let oldest = await cache.lookup("k0")
        let newest = await cache.lookup("k4")
        XCTAssertNil(oldest)
        XCTAssertNotNil(newest)
        // An entry bigger than the whole budget never sits in memory (and does not flush everything else).
        await cache.store(key: "huge", data: Data(count: 5000), kind: .stream)
        let afterHuge = await cache.lookup("k4")
        XCTAssertNotNil(afterHuge)
        let count = await cache.memoryByteCount
        XCTAssertLessThanOrEqual(count, 1000)
    }

    func testDiskBudgetAndAgeArePruned() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory, maxMemoryEntries: 1, maxDiskBytes: 4000)
        for index in 0..<20 { await cache.store(key: "d\(index)", data: Data(count: 400), kind: .catalog) }
        let usage = await cache.diskUsage()
        XCTAssertLessThanOrEqual(usage, 4000, "the disk budget holds")
        let newest = await cache.lookup("d19")
        XCTAssertNotNil(newest, "the most recent entry survives pruning")

        // Files untouched for longer than the age limit go on the next prune.
        let old = Date().addingTimeInterval(-40 * 86400)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }
        await cache.pruneDisk()
        let afterAge = await cache.diskUsage()
        XCTAssertEqual(afterAge, 0)
    }

    func testCorruptDiskEntryIsRemovedAndTreatedAsMiss() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory)
        await cache.store(key: "x", data: Data("ok".utf8), kind: .meta)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("garbage".utf8).write(to: file)
        let reborn = ResponseCache(directory: directory)
        let hit = await reborn.lookup("x")
        XCTAssertNil(hit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
