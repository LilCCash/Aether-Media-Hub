import XCTest
@testable import AetherCore

final class PlaybackPlannerTests: XCTestCase {
    private let hdrPhone = DeviceVideoCapabilities(supportsHDR10: true, supportsHLG: true, supportsDolbyVision: true,
                                                   hardwareHEVC: true, hardwareAV1: true, hardwareVP9: false, edrHeadroom: 8)
    private let sdrDevice = DeviceVideoCapabilities.conservative

    private func facts(source: MediaFormatInfo.Source = .avFoundation, tag: String = "hvc1", range: DynamicRange = .hdr10,
                       dv: DolbyVisionInfo? = nil, decodable: Bool? = true, playability: PlatformPlayability = .playable) -> MediaFormatInfo {
        let video = VideoTrackFacts(codecTag: tag, width: 3840, height: 2160, range: range, dolbyVision: dv, isDecodable: decodable)
        return MediaFormatInfo(source: source, container: "mp4", video: [video], platformPlayability: playability)
    }

    private func plan(container: String? = "mp4", facts: MediaFormatInfo? = nil, device: DeviceVideoCapabilities? = nil,
                      mpv: Bool = true, choice: PlayerEngineChoice = .automatic, forceSDR: Bool = false) -> PlaybackPlan {
        return PlaybackPlanner.plan(container: container, facts: facts, device: device ?? hdrPhone, mpvAvailable: mpv,
                                    choice: choice, forceSDR: forceSDR)
    }

    // MARK: Engine choice

    func testMatroskaGoesToMPV() {
        let result = plan(container: "mkv")
        XCTAssertEqual(result.engine, .mpv)
        XCTAssertTrue(result.canPlay)
    }

    func testMatroskaWithoutMPVIsBlockedWithAClearMessage() {
        let result = plan(container: "mkv", mpv: false)
        XCTAssertNil(result.engine)
        XCTAssertFalse(result.canPlay)
        XCTAssertTrue(result.blockingMessage?.contains("MKV") == true, result.blockingMessage ?? "nil")
    }

    func testPlainMP4StaysOnAVPlayer() {
        XCTAssertEqual(plan(container: "mp4").engine, .avPlayer)
        XCTAssertEqual(plan(container: "m3u8").engine, .avPlayer)
        XCTAssertEqual(plan(container: nil).engine, .avPlayer, "unknown container: try the system player first")
    }

    func testHev1TaggedHEVCThatAppleCannotDecodeFallsBackToMPV() {
        let result = plan(facts: facts(tag: "hev1", decodable: false, playability: .notPlayable))
        XCTAssertEqual(result.engine, .mpv)
        XCTAssertTrue(result.notes.contains { $0.text.contains("hev1") })
    }

    func testUndecodableTrackWithoutMPVIsBlocked() {
        let result = plan(facts: facts(decodable: false, playability: .notPlayable), mpv: false)
        XCTAssertNil(result.engine)
        XCTAssertNotNil(result.blockingMessage)
    }

    func testForcedAVPlayerRefusesMatroska() {
        let result = plan(container: "mkv", choice: .avPlayer)
        XCTAssertNil(result.engine)
        XCTAssertNotNil(result.blockingMessage)
    }

    func testForcedMPVNeedsTheEngineToBePresent() {
        XCTAssertEqual(plan(choice: .mpv).engine, .mpv)
        let missing = plan(choice: .mpv, mpv: false)
        XCTAssertNil(missing.engine)
        XCTAssertNotNil(missing.blockingMessage)
    }

    func testForcedMPVIsHonouredEvenForAnMP4() {
        XCTAssertEqual(plan(container: "mp4", choice: .mpv).engine, .mpv)
    }

    // MARK: Dolby Vision

    func testDolbyVision81OnAnMP4UsesAVPlayerAndPromisesDolbyVisionOnlyOnCapableDevices() {
        let dv = DolbyVisionInfo(profile: 8, level: 6, baseLayerCompatibility: 1)
        let capable = plan(facts: facts(tag: "dvh1", dv: dv))
        XCTAssertEqual(capable.engine, .avPlayer)
        XCTAssertEqual(capable.output, .dolbyVision(profile: "8.1"))

        let noDV = DeviceVideoCapabilities(supportsHDR10: true, supportsHLG: true, supportsDolbyVision: false, edrHeadroom: 4)
        let hdr10Only = plan(facts: facts(tag: "dvh1", dv: dv), device: noDV)
        XCTAssertEqual(hdr10Only.engine, .avPlayer)
        XCTAssertEqual(hdr10Only.output, .dolbyVisionAsHDR10(profile: "8.1"))
    }

    func testDolbyVisionOnAnSDRDeviceIsToneMapped() {
        let dv = DolbyVisionInfo(profile: 8, level: 6, baseLayerCompatibility: 1)
        let result = plan(facts: facts(tag: "dvh1", dv: dv), device: sdrDevice)
        XCTAssertEqual(result.output, .toneMappedToSDR(source: "Dolby Vision 8.1"))
    }

    func testProfile7IsNotAppleDecodableAndGoesToMPVAsHDR10() {
        let dv = DolbyVisionInfo(profile: 7, level: 6, hasEnhancementLayer: true, baseLayerCompatibility: 6)
        let result = plan(facts: facts(tag: "dvh1", dv: dv))
        XCTAssertEqual(result.engine, .mpv)
        XCTAssertEqual(result.output, .dolbyVisionAsHDR10(profile: "7"))
        XCTAssertTrue(result.notes.contains { $0.text.contains("non pilota") }, "must say MPV is not true Dolby Vision")
    }

    func testProfile7WithoutMPVWarnsInsteadOfPromising() {
        let dv = DolbyVisionInfo(profile: 7, level: 6, hasEnhancementLayer: true, baseLayerCompatibility: 6)
        let result = plan(facts: facts(tag: "dvh1", dv: dv), mpv: false)
        XCTAssertEqual(result.engine, .avPlayer)
        XCTAssertEqual(result.output, .unknown)
        XCTAssertTrue(result.notes.contains { $0.severity == .warning })
    }

    func testDolbyVisionThroughMPVIsNeverReportedAsNativeDolbyVision() {
        let dv = DolbyVisionInfo(profile: 8, level: 6, baseLayerCompatibility: 1)
        let result = plan(container: "mkv", facts: facts(source: .mpv, tag: "hevc", dv: dv))
        XCTAssertEqual(result.engine, .mpv)
        XCTAssertEqual(result.output, .dolbyVisionAsHDR10(profile: "8.1"))
    }

    func testProfile5ThroughMPVOnAnSDRScreenIsToneMapped() {
        let dv = DolbyVisionInfo(profile: 5, level: 9, baseLayerCompatibility: 0)
        let result = plan(container: "mkv", facts: facts(source: .mpv, tag: "hevc", dv: dv), device: sdrDevice)
        XCTAssertEqual(result.output, .toneMappedToSDR(source: "Dolby Vision 5"))
    }

    // MARK: HDR10 / HLG / SDR

    func testHDR10OnAnHDRDeviceStaysHDR10() {
        XCTAssertEqual(plan(facts: facts()).output, .hdr10)
    }

    func testHDR10OnAnSDRDeviceIsToneMapped() {
        XCTAssertEqual(plan(facts: facts(), device: sdrDevice).output, .toneMappedToSDR(source: "HDR10"))
    }

    func testUserCanForceSDR() {
        XCTAssertEqual(plan(facts: facts(), forceSDR: true).output, .toneMappedToSDR(source: "HDR10"))
        XCTAssertEqual(plan(facts: facts(range: .hlg), forceSDR: true).output, .toneMappedToSDR(source: "HLG"))
    }

    func testHLGAndSDR() {
        XCTAssertEqual(plan(facts: facts(range: .hlg)).output, .hlg)
        XCTAssertEqual(plan(facts: facts(tag: "avc1", range: .sdr)).output, .sdr)
    }

    func testNoFactsMeansNoPromise() {
        XCTAssertEqual(plan(facts: nil).output, .unknown)
        XCTAssertEqual(plan(facts: facts(range: .unknown)).output, .unknown, "unsignalled range is not SDR")
    }

    // MARK: Supporting types

    func testNativeContainerList() {
        XCTAssertTrue(PlaybackPlanner.isNativeToAVFoundation(container: "MP4"))
        XCTAssertTrue(PlaybackPlanner.isNativeToAVFoundation(container: "mov"))
        XCTAssertFalse(PlaybackPlanner.isNativeToAVFoundation(container: "mkv"))
        XCTAssertFalse(PlaybackPlanner.isNativeToAVFoundation(container: "avi"))
        XCTAssertTrue(PlaybackPlanner.isNativeToAVFoundation(container: ""))
    }

    func testAppleDolbyVisionProfiles() {
        XCTAssertTrue(PlaybackPlanner.avFoundationSupportsDolbyVision(DolbyVisionInfo(profile: 5, level: 6)))
        XCTAssertTrue(PlaybackPlanner.avFoundationSupportsDolbyVision(DolbyVisionInfo(profile: 8, level: 6, baseLayerCompatibility: 1)))
        XCTAssertTrue(PlaybackPlanner.avFoundationSupportsDolbyVision(DolbyVisionInfo(profile: 8, level: 6, baseLayerCompatibility: 4)))
        XCTAssertFalse(PlaybackPlanner.avFoundationSupportsDolbyVision(DolbyVisionInfo(profile: 7, level: 6, baseLayerCompatibility: 6)))
        XCTAssertFalse(PlaybackPlanner.avFoundationSupportsDolbyVision(DolbyVisionInfo(profile: 8, level: 6, baseLayerCompatibility: 0)))
    }

    func testHasHDRDisplayFollowsCapabilities() {
        XCTAssertFalse(DeviceVideoCapabilities.conservative.hasHDRDisplay)
        XCTAssertTrue(DeviceVideoCapabilities(edrHeadroom: 2).hasHDRDisplay)
        XCTAssertTrue(DeviceVideoCapabilities(supportsHLG: true).hasHDRDisplay)
    }
}

final class MPVOptionsTests: XCTestCase {
    private let hdrDevice = DeviceVideoCapabilities(supportsHDR10: true, edrHeadroom: 4)

    private func value(_ name: String, in pairs: [MPVOptions.Pair]) -> String? {
        return pairs.last(where: { $0.name == name })?.value
    }

    func testDefaultOptionsDrawWithMetalThroughMoltenVK() {
        let pairs = MPVOptions.initialOptions(video: VideoOutputSettings(), device: hdrDevice)
        XCTAssertEqual(value("vo", in: pairs), "gpu-next")
        XCTAssertEqual(value("gpu-api", in: pairs), "vulkan")
        XCTAssertEqual(value("gpu-context", in: pairs), "moltenvk")
        XCTAssertEqual(value("hwdec", in: pairs), "videotoolbox")
        XCTAssertEqual(value("ao", in: pairs), "audiounit")
        XCTAssertEqual(value("audio-fallback-to-null", in: pairs), "yes")
        XCTAssertEqual(value("ytdl", in: pairs), "no")
        XCTAssertEqual(value("load-scripts", in: pairs), "no")
    }

    func testHeadlessVideoUsesTheNullOutputOnly() {
        let pairs = MPVOptions.initialOptions(video: VideoOutputSettings(), device: hdrDevice, headlessVideo: true)
        XCTAssertEqual(value("vo", in: pairs), "null")
        XCTAssertNil(value("gpu-api", in: pairs))
        XCTAssertNil(value("gpu-context", in: pairs))
    }

    func testHardwareDecodingSwitch() {
        var video = VideoOutputSettings()
        video.hardwareDecoding = false
        XCTAssertEqual(value("hwdec", in: MPVOptions.initialOptions(video: video, device: hdrDevice)), "no")
    }

    func testColourSpaceHintOnlyWhenTheScreenCanShowHDRAndTheUserAllowsIt() {
        var video = VideoOutputSettings()
        XCTAssertEqual(value("target-colorspace-hint", in: MPVOptions.runtimeProperties(video: video, device: hdrDevice)), "yes")
        XCTAssertEqual(value("target-colorspace-hint", in: MPVOptions.runtimeProperties(video: video, device: .conservative)), "no")
        video.hdrMode = .sdr
        XCTAssertEqual(value("target-colorspace-hint", in: MPVOptions.runtimeProperties(video: video, device: hdrDevice)), "no")
        XCTAssertTrue(MPVOptions.wantsExtendedDynamicRange(video: VideoOutputSettings(), device: hdrDevice))
        XCTAssertFalse(MPVOptions.wantsExtendedDynamicRange(video: video, device: hdrDevice))
    }

    func testToneMappingAndPictureControls() {
        var video = VideoOutputSettings()
        video.toneMapping = .bt2390
        video.deband = true
        video.brightness = 5
        video.gamma = -3
        let pairs = MPVOptions.runtimeProperties(video: video, device: hdrDevice)
        XCTAssertEqual(value("tone-mapping", in: pairs), "bt.2390")
        XCTAssertEqual(value("deband", in: pairs), "yes")
        XCTAssertEqual(value("brightness", in: pairs), "5")
        XCTAssertEqual(value("gamma", in: pairs), "-3")
    }

    func testBufferOptionsOnlyWhenRequested() {
        XCTAssertNil(value("cache-secs", in: MPVOptions.initialOptions(video: VideoOutputSettings(), device: hdrDevice)))
        var video = VideoOutputSettings()
        video.bufferSeconds = 45
        let pairs = MPVOptions.initialOptions(video: video, device: hdrDevice)
        XCTAssertEqual(value("cache-secs", in: pairs), "45")
        XCTAssertEqual(value("demuxer-readahead-secs", in: pairs), "45")
    }

    func testHeadersAreAppendedOneByOneAndBadNamesAreDropped() {
        let pairs = MPVOptions.headerOptions(["User-Agent": "x, y", "Referer": "https://a.test/", "Bad:Name": "1", "": "2", "X-Inj": "a\r\nEvil: 1"])
        XCTAssertEqual(pairs.map { $0.name }, ["http-header-fields-append", "http-header-fields-append", "http-header-fields-append"])
        XCTAssertEqual(pairs.map { $0.value }, ["Referer: https://a.test/", "User-Agent: x, y", "X-Inj: aEvil: 1"])
    }

    func testLanguagePriorityList() {
        XCTAssertEqual(MPVOptions.languagePriorityList(["it", "ITA", "off", "system", "it", "en"]), "it,ita,en")
        XCTAssertEqual(MPVOptions.languagePriorityList(["off"]), "")
    }

    func testSubtitleStyleMapping() {
        var style = SubtitleStyle()
        style.sizePercent = 150
        style.isBold = true
        style.textColor = "#ffcc00"
        style.outlineEnabled = false
        style.backgroundColor = "#112233"
        style.backgroundOpacity = 0.5
        style.bottomOffsetPercent = 12
        let pairs = MPVOptions.subtitleStyleProperties(style)
        XCTAssertEqual(value("sub-scale", in: pairs), "1.50")
        XCTAssertEqual(value("sub-bold", in: pairs), "yes")
        XCTAssertEqual(value("sub-color", in: pairs), "#FFCC00")
        XCTAssertEqual(value("sub-border-size", in: pairs), "0")
        XCTAssertEqual(value("sub-back-color", in: pairs), "#80112233")
        XCTAssertEqual(value("sub-pos", in: pairs), "88")
    }

    func testMalformedColoursFallBack() {
        var style = SubtitleStyle()
        style.textColor = "red"
        style.outlineColor = "#12"
        let pairs = MPVOptions.subtitleStyleProperties(style)
        XCTAssertEqual(value("sub-color", in: pairs), "#FFFFFF")
        XCTAssertEqual(value("sub-border-color", in: pairs), "#000000")
    }

    func testPanscan() {
        XCTAssertEqual(MPVOptions.panscan(fill: true), "1.0")
        XCTAssertEqual(MPVOptions.panscan(fill: false), "0.0")
    }

    func testSettingsDecodeLeniently() throws {
        let json = #"{"playback":{"engine":"mpv","video":{"hdrMode":"sdr","brightness":500,"bufferSeconds":2,"toneMapping":"nonsense"},"holdSpeed":9}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.playback.engine, .mpv)
        XCTAssertEqual(settings.playback.video.hdrMode, .sdr)
        XCTAssertEqual(settings.playback.video.brightness, 100, "clamped")
        XCTAssertEqual(settings.playback.video.bufferSeconds, 5, "clamped to the minimum")
        XCTAssertEqual(settings.playback.video.toneMapping, .auto, "unknown value falls back")
        XCTAssertEqual(settings.playback.holdSpeed, 4, "clamped")
        XCTAssertTrue(settings.playback.holdToSpeed)
    }
}

final class MPVErrorMapperTests: XCTestCase {
    func testHTTPStatusesInTheLogWin() {
        XCTAssertEqual(MPVErrorMapper.map(code: -13, message: "loading failed", recentLog: ["http error 403 Forbidden"]).kind, .forbidden)
        XCTAssertEqual(MPVErrorMapper.map(code: -13, message: "loading failed", recentLog: ["HTTP error 404 Not Found"]).kind, .notFound)
        XCTAssertEqual(MPVErrorMapper.map(code: -13, message: "loading failed", recentLog: ["Connection timed out"]).kind, .timeout)
    }

    func testFormatErrors() {
        XCTAssertEqual(MPVErrorMapper.map(code: -17, message: "unrecognized file format", recentLog: []).kind, .formatUnsupported)
        XCTAssertEqual(MPVErrorMapper.map(code: -16, message: "nothing to play", recentLog: []).kind, .formatUnsupported)
    }

    func testVideoOutputFailureIsExplained() {
        let failure = MPVErrorMapper.map(code: -15, message: "VO init failed", recentLog: [])
        XCTAssertEqual(failure.kind, .unknown)
        XCTAssertTrue(failure.detail.contains("uscita video"))
    }

    func testPlainLoadingFailureIsUnreachable() {
        XCTAssertEqual(MPVErrorMapper.map(code: -13, message: "loading failed", recentLog: []).kind, .unreachable)
    }
}
