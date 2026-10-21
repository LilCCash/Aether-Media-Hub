import XCTest
@testable import AetherCore

final class MP4FragmentTests: XCTestCase {
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        return [UInt8(size >> 24), UInt8((size >> 16) & 0xff), UInt8((size >> 8) & 0xff), UInt8(size & 0xff)] + Array(type.utf8) + payload
    }

    private func tfhd(_ trackID: UInt32) -> [UInt8] {
        return box("tfhd", [0, 0x02, 0x00, 0x00] + [UInt8(trackID >> 24), UInt8((trackID >> 16) & 0xff), UInt8((trackID >> 8) & 0xff), UInt8(trackID & 0xff)])
    }

    private func tfdtV0(_ base: UInt32) -> [UInt8] {
        return box("tfdt", [0, 0, 0, 0] + [UInt8(base >> 24), UInt8((base >> 16) & 0xff), UInt8((base >> 8) & 0xff), UInt8(base & 0xff)])
    }

    private func tfdtV1(_ base: UInt64) -> [UInt8] {
        return box("tfdt", [1, 0, 0, 0] + (0..<8).map { UInt8(truncatingIfNeeded: base >> UInt64(56 - 8 * $0)) })
    }

    private func traf(_ trackID: UInt32, tfdt: [UInt8]) -> [UInt8] {
        return box("traf", tfhd(trackID) + tfdt + box("trun", [0, 0, 0, 0, 0, 0, 0, 0]))
    }

    private func muxed(withTrailer: Bool = true) -> Data {
        let initPart = box("ftyp", Array("isom".utf8) + [0, 0, 0, 1]) + box("moov", [1, 2, 3, 4])
        let moof = box("moof", box("mfhd", [0, 0, 0, 0, 0, 0, 0, 1]) + traf(1, tfdt: tfdtV0(0)) + traf(2, tfdt: tfdtV1(0)))
        let mdat = box("mdat", [9, 9, 9, 9, 9])
        let mfra = box("mfra", [7, 7, 7])
        return Data(initPart + moof + mdat + (withTrailer ? mfra : []))
    }

    func testBoxesAreWalkedInOrder() {
        let list = MP4Fragment.boxes(in: muxed())
        XCTAssertEqual(list.map { $0.type }, ["ftyp", "moov", "moof", "mdat", "mfra"])
        XCTAssertEqual(list.first?.start, 0)
        XCTAssertEqual(list.last?.end, muxed().count)
    }

    func testTheMuxerOutputIsCutIntoInitAndFragmentWithoutTheTrailer() throws {
        let parts = try XCTUnwrap(MP4Fragment.split(muxed()))
        XCTAssertEqual(MP4Fragment.boxes(in: parts.initPart).map { $0.type }, ["ftyp", "moov"])
        XCTAssertEqual(MP4Fragment.boxes(in: parts.fragment).map { $0.type }, ["moof", "mdat"])
    }

    func testSeveralFragmentsAreKeptTogether() throws {
        var data = muxed(withTrailer: false)
        data.append(Data(box("moof", box("mfhd", [0, 0, 0, 0, 0, 0, 0, 2]) + traf(1, tfdt: tfdtV0(0))) + box("mdat", [1])))
        let parts = try XCTUnwrap(MP4Fragment.split(data))
        XCTAssertEqual(MP4Fragment.boxes(in: parts.fragment).map { $0.type }, ["moof", "mdat", "moof", "mdat"])
    }

    func testNothingToCutWithoutAFragment() {
        XCTAssertNil(MP4Fragment.split(Data(box("ftyp", Array("isom".utf8)) + box("moov", [1]))))
        XCTAssertNil(MP4Fragment.split(Data()))
    }

    func testDecodeTimesAreWrittenInBothBoxVersions() throws {
        var fragment = try XCTUnwrap(MP4Fragment.split(muxed())).fragment
        XCTAssertEqual(MP4Fragment.decodeTimes(in: fragment), [1: 0, 2: 0])
        XCTAssertTrue(MP4Fragment.setDecodeTimes(in: &fragment, [1: 64_000, 2: 6_000_000_000]))
        XCTAssertEqual(MP4Fragment.decodeTimes(in: fragment), [1: 64_000, 2: 6_000_000_000])
        // The structure is intact: same boxes, same sizes.
        XCTAssertEqual(MP4Fragment.boxes(in: fragment).map { $0.type }, ["moof", "mdat"])
    }

    func testATrackWithoutAnEntryIsLeftAlone() throws {
        var fragment = try XCTUnwrap(MP4Fragment.split(muxed())).fragment
        XCTAssertTrue(MP4Fragment.setDecodeTimes(in: &fragment, [2: 77]))
        XCTAssertEqual(MP4Fragment.decodeTimes(in: fragment), [1: 0, 2: 77])
    }

    func testAValueThatDoesNotFitTheShortBoxIsReported() throws {
        var fragment = try XCTUnwrap(MP4Fragment.split(muxed())).fragment
        XCTAssertFalse(MP4Fragment.setDecodeTimes(in: &fragment, [1: UInt64(UInt32.max) + 1]))
    }

    func testTruncatedDataDoesNotCrash() {
        let data = muxed()
        for length in 0..<data.count where length % 3 == 0 {
            _ = MP4Fragment.boxes(in: data.prefix(length))
            _ = MP4Fragment.split(Data(data.prefix(length)))
        }
    }

    func testTrackTimescalesAreReadFromTheInitSegment() {
        func u32(_ value: UInt32) -> [UInt8] { return [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)] }
        // tkhd v0: version/flags, creation, modification, track ID, reserved, duration …; mdhd v0: version/flags, creation, modification, time scale, duration …
        func track(id: UInt32, scale: UInt32) -> [UInt8] {
            let tkhd = box("tkhd", [0, 0, 0, 0] + u32(0) + u32(0) + u32(id) + u32(0) + u32(0))
            let mdhd = box("mdhd", [0, 0, 0, 0] + u32(0) + u32(0) + u32(scale) + u32(0) + [0, 0, 0, 0])
            return box("trak", tkhd + box("mdia", mdhd))
        }
        let initPart = Data(box("ftyp", Array("isom".utf8)) + box("moov", track(id: 1, scale: 16000) + track(id: 2, scale: 48000)))
        XCTAssertEqual(MP4Fragment.trackTimescales(in: initPart), [1: 16000, 2: 48000])
    }
}
