import XCTest
@testable import AetherCore

/// RAR files written byte by byte from the format's documentation (the CRCs are not checked by the reader, so they are zero).
final class RarArchiveTests: XCTestCase {
    private func le16(_ v: Int) -> [UInt8] { return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { return (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    /// RAR 4: marker, main header, one file header per file (stored, method 0x30), the data, the end block.
    private func rar4(_ files: [(name: String, data: [UInt8], unpacked: Int, flags: Int)], method: UInt8 = 0x30) -> Data {
        var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        bytes += [0, 0, 0x73] + le16(0) + le16(13) + [0, 0, 0, 0, 0, 0]          // main header, 13 bytes
        for file in files {
            let name = Array(file.name.utf8)
            let size = 32 + name.count
            bytes += [0, 0, 0x74] + le16(0x8000 | file.flags) + le16(size)
            bytes += le32(file.data.count) + le32(file.unpacked) + [0] + le32(0) + le32(0) + [20, method] + le16(name.count) + le32(0)
            bytes += name
            bytes += file.data
        }
        bytes += [0, 0, 0x7B] + le16(0x4000) + le16(7)
        return Data(bytes)
    }

    private func vint(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v > 0 { byte |= 0x80 }
            out.append(byte)
        } while v > 0
        return out
    }

    /// RAR 5: signature, main header, one file header per file (stored: compression info 0), the data, the end header.
    private func rar5(_ files: [(name: String, data: [UInt8])]) -> Data {
        var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        func block(_ body: [UInt8], data: [UInt8] = []) {
            bytes += [0, 0, 0, 0] + vint(body.count) + body + data
        }
        block(vint(1) + vint(0) + vint(0))                                      // main: type 1, flags 0, archive flags 0
        for file in files {
            let name = Array(file.name.utf8)
            var body = vint(2) + vint(0x02) + vint(file.data.count)             // type 2, flags: data area, its size
            body += vint(0) + vint(file.data.count) + vint(0)                   // file flags, unpacked size, attributes
            body += vint(0) + vint(0) + vint(name.count) + name                 // compression (stored), host OS, name
            block(body, data: file.data)
        }
        block(vint(5) + vint(0) + vint(0))                                      // end of archive
        return Data(bytes)
    }

    private func fetcher(_ data: Data) -> (total: Int64, fetch: RarArchive.Fetch) {
        return (Int64(data.count), { range in data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1)) })
    }

    func testAStoredRar4IsWalkedAndItsFilesAreFound() async throws {
        let one = Array(repeating: UInt8(0x31), count: 300)
        let two = Array(repeating: UInt8(0x32), count: 500)
        let data = rar4([("Show/Show.S01E01.mkv", one, 300, 0), ("Show/Show.S01E02.mkv", two, 500, 0)])
        let rar = fetcher(data)
        let entries = try await RarArchive.entries(total: rar.total, fetch: rar.fetch)
        XCTAssertEqual(entries.map { $0.name }, ["Show/Show.S01E01.mkv", "Show/Show.S01E02.mkv"])
        XCTAssertTrue(entries.allSatisfy { $0.isStored && !$0.isEncrypted })
        let second = entries[1]
        XCTAssertEqual(second.packedSize, 500)
        XCTAssertEqual([UInt8](try await rar.fetch(second.dataOffset...(second.dataOffset + 499))), two)
    }

    func testACompressedRar4IsRecognised() async throws {
        let data = rar4([("Movie.mkv", Array(repeating: 1, count: 50), 400, 0)], method: 0x33)
        let rar = fetcher(data)
        let entries = try await RarArchive.entries(total: rar.total, fetch: rar.fetch)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].isStored)
    }

    func testAVideoSplitOverTwoVolumesIsReadAsOne() async throws {
        let first = Array(repeating: UInt8(0x41), count: 400)
        let second = Array(repeating: UInt8(0x42), count: 250)
        let volume1 = rar4([("Movie.mkv", first, 650, 0x02)])        // continues in the next volume
        let volume2 = rar4([("Movie.mkv", second, 650, 0x01)])       // continues from the previous one
        let one = fetcher(volume1), two = fetcher(volume2)
        let a = try await RarArchive.entries(total: one.total, fetch: one.fetch, firstFileOnly: true)
        let b = try await RarArchive.entries(total: two.total, fetch: two.fetch, firstFileOnly: true)
        XCTAssertTrue(a[0].continuesInNext)
        XCTAssertTrue(b[0].continuesFromPrevious)
        XCTAssertEqual(a[0].unpackedSize, 650)

        final class Source: RelayRangeFetcher, @unchecked Sendable {
            let data: Data
            init(_ data: Data) { self.data = data }
            func probe() async throws -> RelayResource { RelayResource(contentType: "application/x-rar", length: Int64(data.count), acceptsRanges: true) }
            func fetch(_ range: ClosedRange<Int64>) async throws -> Data { data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1)) }
        }
        let joined = ConcatenatedRangeFetcher(pieces: [
            .init(fetcher: Source(volume1), offset: a[0].dataOffset, length: a[0].packedSize),
            .init(fetcher: Source(volume2), offset: b[0].dataOffset, length: b[0].packedSize),
        ], contentType: "video/x-matroska")
        let facts = try await joined.probe()
        XCTAssertEqual(facts.length, 650)
        let across = [UInt8](try await joined.fetch(395...404))
        XCTAssertEqual(across, Array(repeating: 0x41, count: 5) + Array(repeating: 0x42, count: 5), "a read across the two volumes")
        let whole = [UInt8](try await joined.fetch(0...649))
        XCTAssertEqual(whole, first + second)
    }

    func testAStoredRar5IsWalked() async throws {
        let one = Array(repeating: UInt8(0x51), count: 200)
        let two = Array(repeating: UInt8(0x52), count: 130)
        let data = rar5([("Pack/Episode.S02E05.mp4", one), ("Pack/Episode.S02E06.mp4", two)])
        let rar = fetcher(data)
        let entries = try await RarArchive.entries(total: rar.total, fetch: rar.fetch)
        XCTAssertEqual(entries.map { $0.name }, ["Pack/Episode.S02E05.mp4", "Pack/Episode.S02E06.mp4"])
        XCTAssertTrue(entries.allSatisfy { $0.isStored })
        let second = entries[1]
        XCTAssertEqual(second.unpackedSize, 130)
        XCTAssertEqual([UInt8](try await rar.fetch(second.dataOffset...(second.dataOffset + 129))), two)
    }

    func testANonRarIsRefused() async {
        let rar = fetcher(Data(repeating: 0x20, count: 100))
        do {
            _ = try await RarArchive.entries(total: rar.total, fetch: rar.fetch)
            XCTFail("not a RAR")
        } catch {
            XCTAssertEqual(error as? RarArchive.Failure, .notARar)
        }
    }

    func testVolumesAreGroupedAndOrdered() {
        let sets = RarArchive.volumeSets([
            "Show.S01E02.part2.rar", "Show.S01E02.part1.rar", "Show.S01E02.part10.rar",
            "Movie/movie.r01", "Movie/movie.rar", "Movie/movie.r00",
            "sample.mkv",
        ])
        XCTAssertEqual(sets.count, 2)
        XCTAssertTrue(sets.contains(["Movie/movie.rar", "Movie/movie.r00", "Movie/movie.r01"]))
        XCTAssertTrue(sets.contains(["Show.S01E02.part1.rar", "Show.S01E02.part2.rar", "Show.S01E02.part10.rar"]))
    }
}
