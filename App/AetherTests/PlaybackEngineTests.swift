import XCTest
import AetherCore
@testable import Aether

@MainActor
final class PlaybackEngineTests: XCTestCase {
    func testTheMPVEngineIsLinkedIntoThisBuild() {
        XCTAssertTrue(PlaybackEngineFactory.mpvAvailable, "MPVKit must be linked; otherwise MKV/AVI cannot play")
        XCTAssertTrue(PlaybackEngineFactory.capabilities.mpvAvailable)
    }

    /// libmpv really starts inside the app process and reports what the linked FFmpeg can do. These are the
    /// simulator slices of the libraries; the device slices come from the same build recipe but are not exercised here.
    func testLibmpvStartsAndReportsItsCodecsAndContainers() throws {
        let report = try XCTUnwrap(PlaybackEngineFactory.mpvSelfTest(), "no MPV in this build")
        XCTAssertGreaterThanOrEqual(report.initStatus, 0, "mpv_initialize failed with \(report.initStatus)")
        XCTAssertTrue(report.mpvVersion?.hasPrefix("mpv") == true, "version: \(report.mpvVersion ?? "nil")")
        XCTAssertFalse((report.ffmpegVersion ?? "").isEmpty, "FFmpeg version missing")
        // `decoder-list` is a JSON array of {codec, driver, description} for audio and video decoders.
        let data = try XCTUnwrap(report.decoders.data(using: .utf8))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]], "decoder-list is not a JSON array")
        let codecs = Set(entries.compactMap { $0["codec"] as? String })
        XCTAssertGreaterThan(codecs.count, 40, "suspiciously few decoders: \(codecs.sorted().prefix(20))")
        for codec in ["h264", "hevc", "av1", "vp9", "vc1", "mpeg2video", "eac3", "ac3", "aac", "opus", "flac", "truehd", "dts", "mp3"] {
            XCTAssertTrue(codecs.contains(codec), "decoder \(codec) missing; have: \(codecs.sorted().joined(separator: ","))")
        }
        let demuxers = report.demuxers.lowercased()
        for container in ["matroska", "avi", "mov", "mpegts", "flv", "hls"] {
            XCTAssertTrue(demuxers.contains(container), "demuxer \(container) missing from: \(demuxers.prefix(400))")
        }
    }

    func testFactoryBuildsBothEnginesAndTearsThemDown() {
        let settings = PlaybackSettings()
        let device = DeviceVideoCapabilities.conservative
        let avPlayer = PlaybackEngineFactory.make(.avPlayer, settings: settings, device: device)
        XCTAssertEqual(avPlayer.kind, .avPlayer)
        XCTAssertTrue(avPlayer.supportsPictureInPicture || !AVPictureInPictureSupport.isSupported)
        avPlayer.teardown()

        let mpv = PlaybackEngineFactory.make(.mpv, settings: settings, device: device)
        XCTAssertEqual(mpv.kind, .mpv)
        XCTAssertFalse(mpv.supportsPictureInPicture, "picture in picture is AVPlayer-only and the UI must know")
        XCTAssertNil(mpv.mediaInfo, "nothing is known before a file is loaded")
        mpv.teardown()
    }

    func testDeviceCapabilitiesAreReadFromTheSystem() {
        let capabilities = DeviceCapabilitiesReader.current()
        XCTAssertGreaterThanOrEqual(capabilities.edrHeadroom, 1.0)
        // On a simulator HEVC decoding comes from the host; the value only has to be a definite answer.
        _ = capabilities.hardwareHEVC
    }

    func testBuildInfoDeclaresTheLinkedLibraries() {
        // The licence screen must mention what is actually linked.
        XCTAssertTrue(AboutView.licenses.contains(where: { $0.name.contains("MPV") }) || !PlaybackEngineFactory.mpvAvailable,
                      "MPVKit is linked but not listed among the third-party components")
    }
}
