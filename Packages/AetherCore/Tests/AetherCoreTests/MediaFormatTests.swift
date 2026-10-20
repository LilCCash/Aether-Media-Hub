import XCTest
@testable import AetherCore

final class DolbyVisionParsingTests: XCTestCase {
    func testProfile81Level6() {
        // version 1.0, profile 8 (7 bits), level 6 (6 bits), rpu=1 el=0 bl=1, compatibility id 1 (HDR10)
        let dv = DolbyVisionInfo.parse(configurationRecord: Data([1, 0, 16, 53, 0x10]))
        XCTAssertEqual(dv?.profile, 8)
        XCTAssertEqual(dv?.level, 6)
        XCTAssertEqual(dv?.hasRPU, true)
        XCTAssertEqual(dv?.hasEnhancementLayer, false)
        XCTAssertEqual(dv?.hasBaseLayer, true)
        XCTAssertEqual(dv?.baseLayerCompatibility, 1)
        XCTAssertEqual(dv?.profileLabel, "8.1")
        XCTAssertEqual(dv?.baseLayerRange, .hdr10)
    }

    func testProfile5HasNoCompatibleBaseLayer() {
        let dv = DolbyVisionInfo.parse(configurationRecord: Data([1, 0, 10, 77, 0x00]))
        XCTAssertEqual(dv?.profile, 5)
        XCTAssertEqual(dv?.level, 9)
        XCTAssertEqual(dv?.profileLabel, "5")
        XCTAssertEqual(dv?.baseLayerRange, .unknown)
    }

    func testProfile7IsDualLayer() {
        let dv = DolbyVisionInfo.parse(configurationRecord: Data([1, 0, 14, 55, 0x60]))
        XCTAssertEqual(dv?.profile, 7)
        XCTAssertEqual(dv?.hasEnhancementLayer, true)
        XCTAssertEqual(dv?.baseLayerCompatibility, 6)
        XCTAssertEqual(dv?.profileLabel, "7")
        XCTAssertEqual(dv?.baseLayerRange, .hdr10)
    }

    func testProfile84IsHLGCompatible() {
        let dv = DolbyVisionInfo.parse(configurationRecord: Data([1, 0, 16, 77, 0x40]))
        XCTAssertEqual(dv?.profileLabel, "8.4")
        XCTAssertEqual(dv?.baseLayerRange, .hlg)
    }

    func testLevelUsesTheSixthBitFromTheProfileByte() {
        let dv = DolbyVisionInfo.parse(configurationRecord: Data([1, 0, 11, 13, 0x00]))
        XCTAssertEqual(dv?.profile, 5)
        XCTAssertEqual(dv?.level, 33)
    }

    func testRejectsMalformedRecords() {
        XCTAssertNil(DolbyVisionInfo.parse(configurationRecord: Data()))
        XCTAssertNil(DolbyVisionInfo.parse(configurationRecord: Data([1, 0, 16, 53])))
        XCTAssertNil(DolbyVisionInfo.parse(configurationRecord: Data([2, 0, 16, 53, 0x10])), "unknown major version")
        XCTAssertNil(DolbyVisionInfo.parse(configurationRecord: Data([1, 0, 0, 0, 0])), "profile 0 is not a profile")
    }

    func testProfileEightWithoutAKnownCompatibilityIdKeepsTheBareNumber() {
        let dv = DolbyVisionInfo(profile: 8, level: 6, baseLayerCompatibility: 0)
        XCTAssertEqual(dv.profileLabel, "8")
    }
}

final class HEVCConfigTests: XCTestCase {
    private func record(profile: UInt8, level: UInt8, lumaDepth: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 23)
        bytes[0] = 1
        bytes[1] = profile
        bytes[12] = level
        bytes[16] = 0xFD
        bytes[17] = 0xF8 | (lumaDepth - 8)
        bytes[18] = 0xF8 | (lumaDepth - 8)
        return Data(bytes)
    }

    func testMain10() {
        let config = HEVCConfig.parse(configurationRecord: record(profile: 2, level: 150, lumaDepth: 10))
        XCTAssertEqual(config?.profileIDC, 2)
        XCTAssertEqual(config?.bitDepth, 10)
        XCTAssertEqual(config?.levelIDC, 150)
    }

    func testMain8Bit() {
        let config = HEVCConfig.parse(configurationRecord: record(profile: 1, level: 120, lumaDepth: 8))
        XCTAssertEqual(config?.profileIDC, 1)
        XCTAssertEqual(config?.bitDepth, 8)
    }

    func testShortRecordIsRejected() {
        XCTAssertNil(HEVCConfig.parse(configurationRecord: Data([1, 2, 3])))
    }
}

final class DynamicRangeTests: XCTestCase {
    func testCoreMediaConstants() {
        XCTAssertEqual(DynamicRange.classify(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ"), .hdr10)
        XCTAssertEqual(DynamicRange.classify(primaries: "ITU_R_2020", transfer: "ITU_R_2100_HLG"), .hlg)
        XCTAssertEqual(DynamicRange.classify(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2"), .sdr)
        XCTAssertEqual(DynamicRange.classify(primaries: "P3_D65", transfer: "sRGB"), .sdr)
    }

    func testMpvNames() {
        XCTAssertEqual(DynamicRange.classify(primaries: "bt.2020", transfer: "pq"), .hdr10)
        XCTAssertEqual(DynamicRange.classify(primaries: "bt.2020", transfer: "hlg"), .hlg)
        XCTAssertEqual(DynamicRange.classify(primaries: "bt.709", transfer: "bt.1886"), .sdr)
    }

    func testNothingSignalledIsUnknownNotSDR() {
        XCTAssertEqual(DynamicRange.classify(primaries: nil, transfer: nil), .unknown)
        XCTAssertEqual(DynamicRange.classify(primaries: "", transfer: ""), .unknown)
    }

    func testWideGamutPrimariesAloneDoNotProveHDR() {
        XCTAssertEqual(DynamicRange.classify(primaries: "ITU_R_2020", transfer: nil), .unknown)
    }
}

final class VideoTrackFactsTests: XCTestCase {
    func testVerifiedLabelPrefersDolbyVision() {
        let dv = DolbyVisionInfo(profile: 8, level: 6, baseLayerCompatibility: 1)
        let track = VideoTrackFacts(codecTag: "dvh1", range: .hdr10, dolbyVision: dv)
        XCTAssertEqual(track.verifiedHDRLabel, "Dolby Vision 8.1")
        XCTAssertTrue(track.isHDROrDolbyVision)
    }

    func testNothingKnownGivesNoLabel() {
        let track = VideoTrackFacts(codecTag: "avc1")
        XCTAssertNil(track.verifiedHDRLabel, "no label may be invented when nothing was measured")
        XCTAssertFalse(track.isHDROrDolbyVision)
    }

    func testPlatformFlagAloneGivesAGenericHDRLabel() {
        let track = VideoTrackFacts(codecTag: "hvc1", flaggedHDRByPlatform: true)
        XCTAssertEqual(track.verifiedHDRLabel, "HDR")
    }

    func testHEVCFamilyDetectsTagsAndNames() {
        XCTAssertTrue(VideoTrackFacts(codecTag: "hev1").isHEVCFamily)
        XCTAssertTrue(VideoTrackFacts(codecTag: "DVH1").isHEVCFamily)
        XCTAssertTrue(VideoTrackFacts(codecName: "hevc").isHEVCFamily)
        XCTAssertFalse(VideoTrackFacts(codecTag: "avc1").isHEVCFamily)
    }
}
