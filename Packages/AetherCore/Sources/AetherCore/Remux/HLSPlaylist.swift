import Foundation

public enum HLSVideoRange: String, Equatable, Sendable {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
}

public struct HLSMasterInfo: Equatable, Sendable {
    public var bandwidth: Int
    public var averageBandwidth: Int
    public var width: Int
    public var height: Int
    public var frameRate: Double?
    /// RFC 6381 codec strings, video first.
    public var codecs: [String]
    public var range: HLSVideoRange

    public init(bandwidth: Int, averageBandwidth: Int, width: Int, height: Int, frameRate: Double? = nil, codecs: [String], range: HLSVideoRange = .sdr) {
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codecs = codecs
        self.range = range
    }
}

/// One subtitle track offered next to the video (WebVTT pieces cut like the video ones).
public struct HLSSubtitleRendition: Equatable, Sendable {
    public var name: String
    public var language: String?
    public var uri: String
    public var isDefault: Bool
    public var isForced: Bool

    public init(name: String, language: String?, uri: String, isDefault: Bool = false, isForced: Bool = false) {
        self.name = name
        self.language = language
        self.uri = uri
        self.isDefault = isDefault
        self.isForced = isForced
    }
}

/// Builds the two playlists the receiver is given. The text is written by hand: the FFmpeg in the app has no HLS muxer.
public enum HLSPlaylistBuilder {
    private static func seconds(_ value: Double) -> String {
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func master(_ info: HLSMasterInfo, mediaURI: String = "media.m3u8", subtitles: [HLSSubtitleRendition] = []) -> String {
        var attributes = ["BANDWIDTH=\(max(1, info.bandwidth))", "AVERAGE-BANDWIDTH=\(max(1, info.averageBandwidth))"]
        if info.width > 0 && info.height > 0 { attributes.append("RESOLUTION=\(info.width)x\(info.height)") }
        if let rate = info.frameRate, rate > 0 { attributes.append("FRAME-RATE=\(seconds(rate))") }
        if !info.codecs.isEmpty { attributes.append("CODECS=\"\(info.codecs.joined(separator: ","))\"") }
        attributes.append("VIDEO-RANGE=\(info.range.rawValue)")
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if !subtitles.isEmpty {
            attributes.append("SUBTITLES=\"subs\"")
            var usedNames = Set<String>()
            for (position, rendition) in subtitles.enumerated() {
                // Names must be unique in a group: a second «Italiano» becomes «Italiano 2».
                var name = rendition.name.replacingOccurrences(of: "\"", with: "'")
                if usedNames.contains(name) { name += " \(position + 1)" }
                usedNames.insert(name)
                var media = ["TYPE=SUBTITLES", "GROUP-ID=\"subs\"", "NAME=\"\(name)\""]
                if let language = rendition.language, !language.isEmpty {
                    media.append("LANGUAGE=\"\(language.replacingOccurrences(of: "\"", with: ""))\"")
                }
                media.append("DEFAULT=\(rendition.isDefault ? "YES" : "NO")")
                media.append("AUTOSELECT=YES")
                media.append("FORCED=\(rendition.isForced ? "YES" : "NO")")
                media.append("URI=\"\(rendition.uri)\"")
                lines.append("#EXT-X-MEDIA:" + media.joined(separator: ","))
            }
        }
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append(mediaURI)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The playlist of one subtitle track: the same pieces as the video, as WebVTT.
    public static func subtitles(segments: [RemuxSegmentSpan], track: Int) -> String {
        let longest = segments.map { $0.duration }.max() ?? 6
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(1, Int(longest.rounded(.up))))", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD"]
        for segment in segments {
            lines.append("#EXTINF:\(seconds(segment.duration)),")
            lines.append("sub-\(track)-\(segment.index).vtt")
        }
        lines.append("#EXT-X-ENDLIST")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func media(segments: [RemuxSegmentSpan], initURI: String = "init.mp4") -> String {
        let longest = segments.map { $0.duration }.max() ?? 6
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(1, Int(longest.rounded(.up))))", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"\(initURI)\""]
        for segment in segments {
            lines.append("#EXTINF:\(seconds(segment.duration)),")
            lines.append("seg-\(segment.index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
