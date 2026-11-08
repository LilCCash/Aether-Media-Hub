import XCTest
@testable import AetherCore

final class ZipArchiveTests: XCTestCase {
    // Made with Python's zipfile: two episodes and a text file, stored; the same with ZIP64 local headers; the same deflated.
    private let stored = "UEsDBBQAAAAAAAAAIVDfhrb5yAAAAMgAAAAtAAAAQ2FtZXJhIENhZmUvQ2FtZXJhIENhZmUgLSBzMDVlMTA3IC0gUHJpbWEubXA0RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdQSwMEFAAAAAAAAAAhUDP0pp7IAAAAyAAAADIAAABDYW1lcmEgQ2FmZS9DYW1lcmEgQ2FmZSAtIHMwNWUxMDggLSBDb250YXBhc3NpLm1wNEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4UEsDBBQAAAAAAAAAIVCGphA2BQAAAAUAAAAUAAAAQ2FtZXJhIENhZmUvaW5mby50eHRoZWxsb1BLAQIUAxQAAAAAAAAAIVDfhrb5yAAAAMgAAAAtAAAAAAAAAAAAAACAAQAAAABDYW1lcmEgQ2FmZS9DYW1lcmEgQ2FmZSAtIHMwNWUxMDcgLSBQcmltYS5tcDRQSwECFAMUAAAAAAAAACFQM/SmnsgAAADIAAAAMgAAAAAAAAAAAAAAgAETAQAAQ2FtZXJhIENhZmUvQ2FtZXJhIENhZmUgLSBzMDVlMTA4IC0gQ29udGFwYXNzaS5tcDRQSwECFAMUAAAAAAAAACFQhqYQNgUAAAAFAAAAFAAAAAAAAAAAAAAAgAErAgAAQ2FtZXJhIENhZmUvaW5mby50eHRQSwUGAAAAAAMAAwD9AAAAYgIAAAAA"
    private let zip64Local = "UEsDBC0AAAAAAAAAIVDfhrb5//////////8tABQAQ2FtZXJhIENhZmUvQ2FtZXJhIENhZmUgLSBzMDVlMTA3IC0gUHJpbWEubXA0AQAQAMgAAAAAAAAAyAAAAAAAAABFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN0VQSVNPREUxMDdFUElTT0RFMTA3RVBJU09ERTEwN1BLAwQtAAAAAAAAACFQM/Smnv//////////MgAUAENhbWVyYSBDYWZlL0NhbWVyYSBDYWZlIC0gczA1ZTEwOCAtIENvbnRhcGFzc2kubXA0AQAQAMgAAAAAAAAAyAAAAAAAAABFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOEVQSVNPREUxMDhFUElTT0RFMTA4RVBJU09ERTEwOFBLAwQtAAAAAAAAACFQhqYQNv//////////FAAUAENhbWVyYSBDYWZlL2luZm8udHh0AQAQAAUAAAAAAAAABQAAAAAAAABoZWxsb1BLAQItAy0AAAAAAAAAIVDfhrb5yAAAAMgAAAAtAAAAAAAAAAAAAACAAQAAAABDYW1lcmEgQ2FmZS9DYW1lcmEgQ2FmZSAtIHMwNWUxMDcgLSBQcmltYS5tcDRQSwECLQMtAAAAAAAAACFQM/SmnsgAAADIAAAAMgAAAAAAAAAAAAAAgAEnAQAAQ2FtZXJhIENhZmUvQ2FtZXJhIENhZmUgLSBzMDVlMTA4IC0gQ29udGFwYXNzaS5tcDRQSwECLQMtAAAAAAAAACFQhqYQNgUAAAAFAAAAFAAAAAAAAAAAAAAAgAFTAgAAQ2FtZXJhIENhZmUvaW5mby50eHRQSwUGAAAAAAMAAwD9AAAAngIAAAAA"
    private let deflated = "UEsDBBQAAAAIAAAAIVDfhrb5DwAAAMgAAAAtAAAAQ2FtZXJhIENhZmUvQ2FtZXJhIENhZmUgLSBzMDVlMTA3IC0gUHJpbWEubXA0cw3wDPZ3cTU0MHcd0iwAUEsDBBQAAAAIAAAAIVAz9KaeDwAAAMgAAAAyAAAAQ2FtZXJhIENhZmUvQ2FtZXJhIENhZmUgLSBzMDVlMTA4IC0gQ29udGFwYXNzaS5tcDRzDfAM9ndxNTSwcB3SLABQSwMEFAAAAAgAAAAhUIamEDYHAAAABQAAABQAAABDYW1lcmEgQ2FmZS9pbmZvLnR4dMtIzcnJBwBQSwECFAMUAAAACAAAACFQ34a2+Q8AAADIAAAALQAAAAAAAAAAAAAAgAEAAAAAQ2FtZXJhIENhZmUvQ2FtZXJhIENhZmUgLSBzMDVlMTA3IC0gUHJpbWEubXA0UEsBAhQDFAAAAAgAAAAhUDP0pp4PAAAAyAAAADIAAAAAAAAAAAAAAIABWgAAAENhbWVyYSBDYWZlL0NhbWVyYSBDYWZlIC0gczA1ZTEwOCAtIENvbnRhcGFzc2kubXA0UEsBAhQDFAAAAAgAAAAhUIamEDYHAAAABQAAABQAAAAAAAAAAAAAAIABuQAAAENhbWVyYSBDYWZlL2luZm8udHh0UEsFBgAAAAADAAMA/QAAAPIAAAAAAA=="

    private func reader(_ base64: String) throws -> (total: Int64, fetch: ZipArchive.Fetch, reads: () -> Int) {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        final class Counter: @unchecked Sendable { var reads = 0 }
        let counter = Counter()
        let fetch: ZipArchive.Fetch = { range in
            counter.reads += 1
            return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
        }
        return (Int64(data.count), fetch, { counter.reads })
    }

    private var episode108: TorBoxFileMatcher.Query {
        return TorBoxFileMatcher.Query(episode: DebridEpisode(season: 5, episode: 108), expectsEpisode: true)
    }

    func testTheEpisodeIsFoundAndReadFromInsideAStoredZip() async throws {
        for archive in [stored, zip64Local] {
            let zip = try reader(archive)
            let entries = try await ZipArchive.entries(total: zip.total, fetch: zip.fetch)
            XCTAssertEqual(entries.count, 3)
            XCTAssertTrue(entries.allSatisfy { $0.isStored })
            let entry = try XCTUnwrap(ZipArchive.choose(entries, query: episode108))
            XCTAssertTrue(entry.name.hasSuffix("s05e108 - Contapassi.mp4"), entry.name)
            let window = try await ZipArchive.window(of: entry, total: zip.total, fetch: zip.fetch)
            XCTAssertEqual(window.length, 200)
            let bytes = try await zip.fetch(window.offset...(window.offset + window.length - 1))
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), String(repeating: "EPISODE108", count: 20),
                           "the local header's own extra field is skipped")
            XCTAssertLessThanOrEqual(zip.reads(), 5, "only the end, the index and one header are read")
        }
    }

    func testACompressedEntryIsRecognised() async throws {
        let zip = try reader(deflated)
        let entries = try await ZipArchive.entries(total: zip.total, fetch: zip.fetch)
        let entry = try XCTUnwrap(ZipArchive.choose(entries, query: episode108))
        XCTAssertFalse(entry.isStored)
        XCTAssertEqual(entry.method, 8)
    }

    func testAFileThatIsNotAZipIsRefused() async {
        let data = Data(repeating: 0x41, count: 5_000)
        do {
            _ = try await ZipArchive.entries(total: Int64(data.count)) { range in data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1)) }
            XCTFail("not a ZIP")
        } catch {
            XCTAssertEqual(error as? ZipArchive.Failure, .notAZip)
        }
    }

    func testZip64SizesAndOffsetsAreReadFromTheExtraField() {
        // One central entry with 0xFFFFFFFF sizes and offset, and the real values in the ZIP64 extra field.
        var entry = Data()
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { entry.append(contentsOf: $0) } }
        let name = Array("big/Show.S01E01.mkv".utf8)
        le(UInt32(0x02014b50)); le(UInt16(45)); le(UInt16(45)); le(UInt16(0)); le(UInt16(0)); le(UInt16(0)); le(UInt16(0))
        le(UInt32(0)); le(UInt32(0xFFFF_FFFF)); le(UInt32(0xFFFF_FFFF)); le(UInt16(name.count)); le(UInt16(28)); le(UInt16(0))
        le(UInt16(0)); le(UInt16(0)); le(UInt32(0)); le(UInt32(0xFFFF_FFFF))
        entry.append(contentsOf: name)
        le(UInt16(0x0001)); le(UInt16(24)); le(UInt64(6_000_000_000)); le(UInt64(6_000_000_000)); le(UInt64(70_000_000_000))
        let parsed = ZipArchive.parseDirectory(entry)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.uncompressedSize, 6_000_000_000)
        XCTAssertEqual(parsed.first?.compressedSize, 6_000_000_000)
        XCTAssertEqual(parsed.first?.localHeaderOffset, 70_000_000_000)
        XCTAssertEqual(parsed.first?.name, "big/Show.S01E01.mkv")
    }

    func testAWindowIsReadAsAFileOfItsOwn() async throws {
        final class Base: RelayRangeFetcher, @unchecked Sendable {
            let data = Data((0..<100).map { UInt8($0) })
            func probe() async throws -> RelayResource { RelayResource(contentType: "application/zip", length: 100, acceptsRanges: true) }
            func fetch(_ range: ClosedRange<Int64>) async throws -> Data { data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1)) }
        }
        let window = WindowRangeFetcher(base: Base(), offset: 40, length: 20, contentType: "video/mp4")
        let facts = try await window.probe()
        XCTAssertEqual(facts.length, 20)
        let bytes = try await window.fetch(0...4)
        XCTAssertEqual([UInt8](bytes), [40, 41, 42, 43, 44])
        do {
            _ = try await window.fetch(15...25)
            XCTFail("past the end of the window")
        } catch {}
    }
}
