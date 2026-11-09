import Foundation

/// A mark from 0 to 100 for a source, with the reasons, for the list of sources. It reads only what is known before playing (the
/// addon's announcement and the file name, see `StreamInfo`): it says how good the source promises to be for this viewer, not a
/// measurement. The order of the list stays `StreamSelector`'s; the mark explains it.
public struct SourceRating: Equatable, Sendable {
    public struct Reason: Equatable, Sendable {
        public var text: String
        /// True for what counts in favour, false for what counts against.
        public var isPositive: Bool
    }

    public var score: Int
    public var reasons: [Reason]

    /// «Eccellente», «Ottima», «Buona», «Discreta», «Scarsa».
    public var verdict: String {
        switch score {
        case 90...: return "Eccellente"
        case 75..<90: return "Ottima"
        case 60..<75: return "Buona"
        case 40..<60: return "Discreta"
        default: return "Scarsa"
        }
    }

    public static func rate(_ info: StreamInfo, preferences: StreamPreferences) -> SourceRating {
        var reasons: [Reason] = []
        func good(_ text: String) { reasons.append(Reason(text: text, isPositive: true)) }
        func bad(_ text: String) { reasons.append(Reason(text: text, isPositive: false)) }

        if case .unsupported = info.support {
            return SourceRating(score: 0, reasons: [Reason(text: "Non riproducibile su questo telefono", isPositive: false)])
        }

        // Quality: up to 40, less above the viewer's cap.
        var quality: Int
        switch info.quality {
        case .uhd2160: quality = 40
        case .fullHD1080: quality = 32
        case .hd720: quality = 22
        case .sd: quality = 10
        case .unknown: quality = 16
        }
        let height = info.quality.height
        if height > 0 && height > preferences.qualityCap.maxHeight {
            quality = max(10, quality - 14)
            bad("\(info.quality.label): oltre la qualità massima scelta")
        } else if info.quality == .unknown {
            bad("Qualità non indicata")
        } else if info.quality == .uhd2160 || info.quality == .fullHD1080 {
            good("Risoluzione \(info.quality.label)")
        } else {
            bad("Risoluzione \(info.quality.label)")
        }

        // Language: up to 25.
        var language = 15
        if let wanted = preferences.preferredLanguage, preferences.preferLanguage {
            let name = LanguageCodes.displayName(wanted)
            if info.languages.contains(wanted) {
                language = 25
                good("Audio in \(name.lowercased())")
            } else if info.languages.contains("multi") {
                language = 18
                good("Più lingue audio (probabilmente anche \(name.lowercased()))")
            } else if info.languages.isEmpty {
                language = 8
                bad("Lingua dell'audio non indicata")
            } else {
                language = 0
                bad("Audio non in \(name.lowercased())")
            }
        }

        // Compatibility of the picture: up to 15.
        var codec = 10
        switch info.codec {
        case .h264?: codec = 15; good("Video H.264, compatibile ovunque")
        case .hevc?: codec = 13; good("Video HEVC, efficiente")
        case .av1?: codec = 8; bad("Video AV1: pesante da decodificare")
        case .vp9?: codec = 9
        case .xvid?, .mpeg2?: codec = 4; bad("Codec video vecchio")
        case nil: codec = 10
        }
        if info.support == .unknown {
            codec = min(codec, 6)
            bad("Formato da verificare all'apertura")
        }

        // Picture range and sound: up to 10 each.
        var range = 5
        if info.hdr.contains(.dolbyVision) {
            range = 10; good("Dolby Vision (nel nome)")
        } else if !info.hdr.isEmpty {
            range = 9; good("\(info.hdr.first?.label ?? "HDR") (nel nome)")
        }
        var sound = 5
        if info.audio.contains(.atmos) || info.audio.contains(.truehd) {
            sound = 10; good("Audio \(info.audio.contains(.atmos) ? "Dolby Atmos" : "TrueHD")")
        } else if info.audio.contains(.eac3) || info.audio.contains(.dts) || info.audio.contains(.ac3) {
            sound = 8; good("Audio multicanale")
        }

        var total = quality + language + codec + range + sound
        if !info.warnings.isEmpty {
            total -= min(15, info.warnings.count * 5)
            bad(info.warnings.first ?? "Avvisi sulla sorgente")
        }
        if info.needsHeaders { total -= 3 }
        return SourceRating(score: max(0, min(100, total)), reasons: reasons)
    }
}
