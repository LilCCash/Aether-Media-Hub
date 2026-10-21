import XCTest
import AetherCore
@testable import Aether

/// Scenario 12 at application level: history and resume points are written to a backup file and come back
/// into a brand-new, empty installation. Uses isolated storage (see `UITestHooks`), never the real app data.
@MainActor
final class BackupServiceTests: XCTestCase {
    private func makeEnvironment() -> AppEnvironment {
        AppEnvironment(arguments: ["-AETHER_UITEST", "-AETHER_UITEST_SESSION", UUID().uuidString, "-AETHER_UITEST_RESET"])
    }

    private let movie = MetaItem(id: "tt9000001", type: "movie", name: "Aether Fixture One", poster: "https://img.example/p.png")

    func testHistoryWatchlistAndResumePointsSurviveBackupAndRestore() async throws {
        let source = makeEnvironment()
        await source.libraryStore.load()
        _ = await source.libraryStore.recordProgress(meta: movie, video: nil, position: 600, duration: 3600)
        await source.libraryStore.setWatchlist(true, meta: movie)
        await source.libraryStore.flush()

        let file = try await BackupService.makeBackup(env: source, includeAddonURLs: false)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file)

        let fresh = makeEnvironment()
        await fresh.libraryStore.load()
        let before = await fresh.libraryStore.history()
        XCTAssertTrue(before.isEmpty, "a new installation starts empty")

        let summary = try await BackupService.restore(data: data, env: fresh, mode: .replace, applySettings: false)
        XCTAssertEqual(summary.progressRecords, 1)
        XCTAssertFalse(summary.settingsApplied)

        let history = await fresh.libraryStore.history()
        XCTAssertEqual(history.map { $0.metaID }, ["tt9000001"])
        let resume = await fresh.libraryStore.resumePosition(metaID: "tt9000001", videoID: "tt9000001")
        XCTAssertEqual(resume ?? 0, 600, accuracy: 1)
        let entries = await fresh.libraryStore.snapshot().entries.values
        XCTAssertEqual(entries.filter { $0.inWatchlist }.map { $0.id }, ["tt9000001"])
    }

    func testRestoringNeverTurnsOnTheDirectLinkToTheTV() async throws {
        let source = makeEnvironment()
        let skip = source.settings.value.playback.skipForwardSeconds
        defer {
            source.settings.value.playback.skipForwardSeconds = skip
            source.settings.value.advanced.sendDirectLinkToTV = false
        }
        source.settings.value.advanced.sendDirectLinkToTV = true
        source.settings.value.playback.skipForwardSeconds = skip == 45 ? 30 : 45
        let wanted = source.settings.value.playback.skipForwardSeconds
        let file = try await BackupService.makeBackup(env: source, includeAddonURLs: false)
        defer { try? FileManager.default.removeItem(at: file) }

        let target = makeEnvironment()
        target.settings.value.advanced.sendDirectLinkToTV = false
        let summary = try await BackupService.restore(data: try Data(contentsOf: file), env: target, mode: .replace, applySettings: true)
        XCTAssertTrue(summary.settingsApplied)
        XCTAssertEqual(target.settings.value.playback.skipForwardSeconds, wanted, "the other settings are restored")
        XCTAssertFalse(target.settings.value.advanced.sendDirectLinkToTV, "the key switch must be turned on again on this phone")
    }

    func testMergeKeepsWhatIsAlreadyOnTheDevice() async throws {
        let source = makeEnvironment()
        await source.libraryStore.load()
        _ = await source.libraryStore.recordProgress(meta: movie, video: nil, position: 300, duration: 3600)
        let file = try await BackupService.makeBackup(env: source, includeAddonURLs: false)
        defer { try? FileManager.default.removeItem(at: file) }

        let target = makeEnvironment()
        await target.libraryStore.load()
        let other = MetaItem(id: "tt9000002", type: "movie", name: "Aether Fixture Two")
        _ = await target.libraryStore.recordProgress(meta: other, video: nil, position: 900, duration: 3600)

        _ = try await BackupService.restore(data: try Data(contentsOf: file), env: target, mode: .merge, applySettings: false)
        let ids = Set(await target.libraryStore.history().map { $0.metaID })
        XCTAssertEqual(ids, ["tt9000001", "tt9000002"])
    }

    func testRestoringGarbageFailsWithoutTouchingData() async throws {
        let env = makeEnvironment()
        await env.libraryStore.load()
        _ = await env.libraryStore.recordProgress(meta: movie, video: nil, position: 600, duration: 3600)
        do {
            _ = try await BackupService.restore(data: Data("{ not a backup".utf8), env: env, mode: .replace, applySettings: true)
            XCTFail("expected a decoding error")
        } catch {
            // expected
        }
        let history = await env.libraryStore.history()
        XCTAssertEqual(history.count, 1, "a failed restore must not erase existing data")
    }
}
