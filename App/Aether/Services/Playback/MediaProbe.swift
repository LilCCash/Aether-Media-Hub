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
        var info = MediaFormatInfo(source: .avFoundation, container: container, duration: duration, video: video, audio: audio,
                                   subtitleTrackCount: subtitleTrackCount,
                                   platformPlayability: isPlayableButEmpty ? .unknown : playable)
        // AVFoundation decodes every format it accepts in hardware (VideoToolbox), so the decoder line can say it, as MPV's does.
        if !video.isEmpty { info.hardwareDecoder = "VideoToolbox" }
        return info
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
        facts.codecName = codecName(forTag: facts.codecTag)
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
        // `??` cannot await on its right side: read the two tags one after the other.
        let extended = try? await track.load(.extendedLanguageTag)
        let plain = try? await track.load(.languageCode)
        facts.language = extended ?? plain
        if let metadata = try? await track.load(.commonMetadata),
           let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first,
           let title = try? await item.load(.stringValue), !title.isEmpty {
            facts.title = title
        }
        if let descriptions = try? await track.load(.formatDescriptions), let description = descriptions.first {
            facts.codecTag = fourCC(CMFormatDescriptionGetMediaSubType(description))
            facts.codecName = codecName(forTag: facts.codecTag)
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                facts.channels = Int(basic.mChannelsPerFrame)
            }
        }
        return facts
    }

    /// The codec names MPV reports (lower case, FFmpeg style), so both engines read the same in the information sheet.
    static func codecName(forTag tag: String?) -> String? {
        guard let tag = tag?.lowercased() else { return nil }
        switch tag {
        case "hvc1", "hev1", "dvh1", "dvhe": return "hevc"
        case "avc1", "avc3", "dvav", "dva1": return "h264"
        case "av01", "dav1": return "av1"
        case "vp09": return "vp9"
        case "ap4h", "apch", "apcn", "apcs", "apco", "ap4x": return "prores"
        case "mp4v": return "mpeg4"
        case "aac ", "mp4a": return "aac"
        case "ac-3": return "ac3"
        case "ec-3": return "eac3"
        case ".mp3": return "mp3"
        case "alac": return "alac"
        case "flac", "fla": return "flac"
        case "opus": return "opus"
        case "lpcm": return "pcm"
        default: return nil
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08X", code)
    }
}
