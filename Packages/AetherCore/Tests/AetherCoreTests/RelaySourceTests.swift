import XCTest
@testable import AetherCore

final class MemoryRelaySourceTests: XCTestCase {
    private func drain(_ reader: RelayBodyReader) async throws -> Data {
        var all = Data()
        while let chunk = try await reader.next() { all.append(chunk) }
        return all
    }

    func testTheResourceDescribesTheFile() async throws {
        let source = MemoryRelaySource(size: 1000)
        let resource = try await source.resource(named: "video.mkv")
        XCTAssertEqual(resource, RelayResource(contentType: "video/x-matroska", length: 1000, acceptsRanges: true))
        let unknown = MemoryRelaySource(size: 1000, reportsLength: false, acceptsRanges: false)
        let hidden = try await unknown.resource(named: "video.mkv")
        XCTAssertNil(hidden.length)
        XCTAssertFalse(hidden.acceptsRanges)
    }

    func testAnotherNameIsNotFound() async {
        let source = MemoryRelaySource(size: 1000)
        do {
            _ = try await source.resource(named: "other.mkv")
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? RelayError, .notFound)
        }
        do {
            _ = try await source.open("other.mkv", range: nil)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? RelayError, .notFound)
        }
    }

    func testTheWholeFileIsReadInChunks() async throws {
        let source = MemoryRelaySource(size: 1000, chunkSize: 300)
        let reader = try await source.open("video.mkv", range: nil)
        let first = try await reader.next()
        XCTAssertEqual(first?.count, 300)
        let rest = try await drain(reader)
        XCTAssertEqual((first ?? Data()) + rest, MemoryRelaySource.expected(0...999))
        XCTAssertEqual(source.producedBytes, 1000)
        XCTAssertEqual(source.openCount, 1)
    }

    func testARangeIsReadExactly() async throws {
        let source = MemoryRelaySource(size: 1000, chunkSize: 64)
        let reader = try await source.open("video.mkv", range: 100...199)
        let data = try await drain(reader)
        XCTAssertEqual(data, MemoryRelaySource.expected(100...199))
        XCTAssertEqual(source.producedBytes, 100)
        XCTAssertEqual(source.openedRanges, [100...199])
    }

    func testBytesFollowTheDocumentedPattern() {
        XCTAssertEqual(MemoryRelaySource.byte(at: 0), 0)
        XCTAssertEqual(MemoryRelaySource.byte(at: 250), 250)
        XCTAssertEqual(MemoryRelaySource.byte(at: 251), 0)
        XCTAssertEqual(MemoryRelaySource.expected(249...252), Data([249, 250, 0, 1]))
    }

    func testCancellingStopsTheReadingAndIsCountedOnce() async throws {
        let source = MemoryRelaySource(size: 1_000_000, chunkSize: 1000)
        let reader = try await source.open("video.mkv", range: nil)
        _ = try await reader.next()
        reader.cancel()
        reader.cancel()
        let after = try await reader.next()
        XCTAssertNil(after)
        XCTAssertEqual(source.cancelCount, 1)
        XCTAssertEqual(source.producedBytes, 1000)
    }

    func testAnInjectedOpenFailureIsThrown() async {
        let source = MemoryRelaySource(size: 1000)
        source.failOpen = .upstreamRejected(status: 403)
        do {
            _ = try await source.open("video.mkv", range: nil)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? RelayError, .upstreamRejected(status: 403))
        }
        XCTAssertEqual(source.openCount, 1)
    }

    func testAnInjectedFailureInTheMiddleOfTheBody() async throws {
        let source = MemoryRelaySource(size: 1000, chunkSize: 100)
        source.failAfterBytes = 250
        let reader = try await source.open("video.mkv", range: nil)
        var received = 0
        do {
            while let chunk = try await reader.next() { received += chunk.count }
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? RelayError, .upstreamUnreachable(code: -1005))
        }
        XCTAssertEqual(received, 250)
    }

    func testClosingIsRecorded() {
        let source = MemoryRelaySource(size: 10)
        XCTAssertFalse(source.isClosed)
        source.close()
        XCTAssertTrue(source.isClosed)
    }
}
