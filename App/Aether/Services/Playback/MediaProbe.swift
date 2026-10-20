import AVFoundation
import CoreMedia
import AetherCore

/// Reads what AVFoundation itself reports about an asset: sample-entry codes, colour signalling, the Dolby Vision and
/// HEVC configuration boxes, whether the platform can decode each track. Nothing here looks at a file name.
enum MediaProbe {
    static func facts(for asset: AVAsset, container: String?, subtitleTrackCount: Int) async -> MediaFormatInfo {
        let playable: PlatformPlayability
        if let isPlayable = try? await asset.load(.isPlayable) {
            playable = isPlayable ? .playable : .notPlayable
        } else {
            playable = .unknown
        }
        let duration = (try? await asset.load(.duration)).flatMap { $0.isNumeric ? $0.seconds : nil }

        var video: [VideoTrackFacts] = []
        for track in (try? await asset.loadTracks(withMediaType: .video)) ?? [] {
            video.append(await videoFacts(track))
        }
        var audio: [AudioTrackFacts] = []
        for track in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] {
            audio.append(await audioFacts(track))
        }
        let isPlayableButEmpty = playable == .playable && video.isEmpty && audio.isEmpty
        return MediaFormatInfo(source: .avFoundation, container: container, duration: duration, video: video, audio: audio,
                               subtitleTrackCount: subtitleTrackCount,
                               platformPlayability: isPlayableButEmpty ? .unknown : playable)
    }

    private static func videoFacts(_ track: AVAssetTrack) async -> VideoTrackFacts {
        var facts = VideoTrackFacts()
        if let size = try? await track.load(.naturalSize) {
            facts.width = Int(size.width.rounded())
            facts.height = Int(size.height.rounded())
        }
        if let rate = try? await track.load(.nominalFrameRate), rate > 0 { facts.frameRate = Double(rate) }
        facts.isDecodable = try? await track.load(.isDecodable)
        if let characteristics = try? await track.load(.mediaCharacteristics) {
            facts.flaggedHDRByPlatform = characteristics.contains(.containsHDRVideo)
        }
        guard let descriptions = try? await track.load(.formatDescriptions), let description = descriptions.first else { return facts }

        let subtype = CMFormatDescriptionGetMediaSubType(description)
        facts.codecTag = fourCC(subtype)
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
        facts.primaries = extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        facts.transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        facts.matrix = extensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        facts.range = DynamicRange.classify(primaries: facts.primaries, transfer: facts.transfer)
        if let depth = extensions?[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int { facts.bitDepth = depth }

        let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        if let hvcC = atoms?["hvcC"] as? Data, let config = HEVCConfig.parse(configurationRecord: hvcC) {
            facts.bitDepth = config.bitDepth
        }
        if let record = (atoms?["dvvC"] as? Data) ?? (atoms?["dvcC"] as? Data) {
            facts.dolbyVision = DolbyVisionInfo.parse(configurationRecord: record)
        }
        let dolbyTags: Set<String> = ["dvh1", "dvhe", "dav1", "dvav", "dva1"]
        if facts.dolbyVision == nil, let tag = facts.codecTag, dolbyTags.contains(tag) {
            // Tagged Dolby Vision but the configuration box could not be read: say so instead of guessing a profile.
            facts.dolbyVision = DolbyVisionInfo(profile: 0, level: 0)
        }
        return facts
    }

    private static func audioFacts(_ track: AVAssetTrack) async -> AudioTrackFacts {
        var facts = AudioTrackFacts()
        facts.language = try? await track.load(.extendedLanguageTag)
        if let descriptions = try? await track.load(.formatDescriptions), let description = descriptions.first {
            facts.codecTag = fourCC(CMFormatDescriptionGetMediaSubType(description))
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                facts.channels = Int(basic.mChannelsPerFrame)
            }
        }
        return facts
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08X", code)
    }
}
