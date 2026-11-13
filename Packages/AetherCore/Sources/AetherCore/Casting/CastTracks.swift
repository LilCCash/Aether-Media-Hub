import Foundation

/// One audio or subtitle track of the video playing on a receiver.
public struct CastTrack: Hashable, Identifiable, Sendable {
    public enum Kind: String, Hashable, Sendable { case audio, text }

    /// The receiver's id of the track (Google Cast: `trackId`; for subtitles sent by the phone, the id the phone gave them).
    public var id: Int
    public var kind: Kind
    public var name: String
    /// BCP-47 (or whatever the receiver reports).
    public var language: String?

    public init(id: Int, kind: Kind, name: String, language: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.language = language
    }

    /// What the menu shows: the name, else the language in Italian, else a number.
    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let language = language, !language.isEmpty, LanguageCodes.normalise(language) != "und" { return LanguageCodes.displayName(language) }
        return kind == .audio ? "Traccia audio \(id)" : "Sottotitoli \(id)"
    }
}

/// The tracks a receiver reports, and which of them are on.
public struct CastTrackList: Equatable, Sendable {
    public var audio: [CastTrack]
    public var text: [CastTrack]
    public var activeIDs: Set<Int>

    public init(audio: [CastTrack] = [], text: [CastTrack] = [], activeIDs: Set<Int> = []) {
        self.audio = audio
        self.text = text
        self.activeIDs = activeIDs
    }

    public var isEmpty: Bool { return audio.isEmpty && text.isEmpty }
    public var activeAudio: CastTrack? { return audio.first { activeIDs.contains($0.id) } }
    public var activeText: CastTrack? { return text.first { activeIDs.contains($0.id) } }

    /// The ids to send to the receiver to play `audio` (nil: keep the one on) and show `text` (nil: subtitles off).
    public func ids(audio audioID: Int?, text textID: Int?) -> [Int] {
        var result: [Int] = []
        if let id = audioID ?? activeAudio?.id { result.append(id) }
        if let id = textID { result.append(id) }
        return result
    }

    /// Builds the list from the receiver's tracks, de-duplicating names that repeat («Inglese», «Inglese 2»).
    public static func make(_ tracks: [CastTrack], active: [Int]) -> CastTrackList {
        func numbered(_ list: [CastTrack]) -> [CastTrack] {
            var seen: [String: Int] = [:]
            return list.map { track in
                var copy = track
                let base = track.title
                let count = (seen[base] ?? 0) + 1
                seen[base] = count
                copy.name = count > 1 ? "\(base) \(count)" : base
                return copy
            }
        }
        return CastTrackList(audio: numbered(tracks.filter { $0.kind == .audio }),
                             text: numbered(tracks.filter { $0.kind == .text }),
                             activeIDs: Set(active))
    }
}

/// A subtitle the phone sends to the receiver next to the video (addon, OpenSubtitles or downloaded file): already read into cues.
public struct CastSidecarSubtitle: Hashable, Sendable {
    /// The id the receiver will know it by (Google Cast `trackId`), unique in the load.
    public var trackID: Int
    public var name: String
    public var language: String?
    public var cues: [SubtitleCue]

    public init(trackID: Int, name: String, language: String?, cues: [SubtitleCue]) {
        self.trackID = trackID
        self.name = name
        self.language = language
        self.cues = cues
    }

    /// The file name inside the relay session: `sub-<id>.vtt` or `.srt`.
    public func leaf(srt: Bool) -> String { return "sub-\(trackID).\(srt ? "srt" : "vtt")" }
}

/// Writes cues as WebVTT (Google Cast) or SubRip (DLNA televisions).
public enum SubtitleExport {
    public static func webVTT(_ cues: [SubtitleCue], offset: Double = 0) -> String {
        var text = "WEBVTT\n\n"
        for cue in sorted(cues, offset: offset) {
            text += "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n"
            text += WebVTTWriter.clean(cue.text) + "\n\n"
        }
        return text
    }

    public static func srt(_ cues: [SubtitleCue], offset: Double = 0) -> String {
        var text = ""
        for (index, cue) in sorted(cues, offset: offset).enumerated() {
            text += "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n"
            text += cue.text.replacingOccurrences(of: "\r", with: "") + "\n\n"
        }
        return text
    }

    /// Shifted by the viewer's delay, without empty or reversed cues.
    static func sorted(_ cues: [SubtitleCue], offset: Double) -> [SubtitleCue] {
        return cues.compactMap { cue -> SubtitleCue? in
            let start = max(0, cue.start + offset), end = cue.end + offset
            let body = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, !body.isEmpty else { return nil }
            return SubtitleCue(start: start, end: end, text: body)
        }.sorted { $0.start < $1.start }
    }

    /// 3725.5 → `01:02:05.500` (`,` for SubRip).
    static func timestamp(_ seconds: Double, separator: String) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        let h = millis / 3_600_000, m = millis / 60_000 % 60, s = millis / 1000 % 60, ms = millis % 1000
        return String(format: "%02d:%02d:%02d", h, m, s) + separator + String(format: "%03d", ms)
    }
}
