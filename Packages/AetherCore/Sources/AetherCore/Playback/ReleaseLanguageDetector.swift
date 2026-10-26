import Foundation

/// Best-effort parser for release-name audio languages.
/// Scene/P2P release names commonly use token-delimited tags such as ITA, ENG, ESP, MULTI or DUAL AUDIO.
/// Subtitle-only tags (SUBITA, SUB ITA, SUBENG, VOSTFR, HARDSUB, etc.) are removed before audio parsing.
public enum ReleaseLanguageDetector {
    /// All explicit audio-language clues in a release name, in deterministic order.
    public static func languages(in text: String) -> [String] {
        var value = text.uppercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        // Remove subtitle annotations including both joined and separated forms, without suppressing
        // independent audio tags elsewhere in the same filename (e.g. ITA ENG SUB ITA).
        let subtitlePatterns = [
            #"(?<![A-Z0-9])(?:SUBS?|SUBTITLE|SUBTITLES|HARDSUB|SOFTSUB|VOSTFR|VOSTEN|VOST|SUBBED)\s*[ ._-]*(?:ITA|IT|ITALIAN|ITALIANO|ENG|EN|ENGLISH|FRA|FRE|FR|FRENCH|FRANCAIS|SPA|ESP|ES|SPANISH|CASTELLANO|DEU|GER|DE|GERMAN|POR|PT|PORTUGUESE)(?![A-Z0-9])"#,
            #"(?<![A-Z0-9])(?:SUBS?|SUBTITLE|SUBTITLES|HARDSUB|SOFTSUB|VOSTFR|VOSTEN|VOST|SUBBED)(?![A-Z0-9])"#
        ]
        for pattern in subtitlePatterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        var found: [String] = []
        let markers: [(String, String)] = [
            (#"(?<![A-Z0-9])(?:ITA|ITALIAN|ITALIANO)(?![A-Z0-9])"#, "it"),
            (#"(?<![A-Z0-9])(?:ENG|ENGLISH)(?![A-Z0-9])"#, "en"),
            (#"(?<![A-Z0-9])(?:FRA|FRE|FRENCH|FRANCAIS)(?![A-Z0-9])"#, "fr"),
            (#"(?<![A-Z0-9])(?:SPA|ESP|SPANISH|CASTELLANO)(?![A-Z0-9])"#, "es"),
            (#"(?<![A-Z0-9])(?:DEU|GER|GERMAN|DEUTSCH)(?![A-Z0-9])"#, "de"),
            (#"(?<![A-Z0-9])(?:POR|PORTUGUESE|PORTUGUES)(?![A-Z0-9])"#, "pt"),
            (#"(?<![A-Z0-9])(?:PT[ .]?BR|BRAZILIAN)(?![A-Z0-9])"#, "pt-BR"),
            (#"(?<![A-Z0-9])(?:MULTI|MULTILANGUAGE|DUAL[ ]?AUDIO|MULTI[ ]?AUDIO|ML)(?![A-Z0-9])"#, "multi")
        ]
        for (pattern, language) in markers where value.range(of: pattern, options: .regularExpression) != nil {
            if !found.contains(language) { found.append(language) }
        }

        // Two-letter tags are ambiguous in ordinary words, so accept them only when explicitly bracketed
        // or as a complete filename token. They are checked after the unambiguous three-letter codes.
        let shortMarkers: [(String, String)] = [
            (#"(?<![A-Z0-9])(?:\[IT\]|\(IT\)|IT)(?![A-Z0-9])"#, "it"),
            (#"(?<![A-Z0-9])(?:\[EN\]|\(EN\)|EN)(?![A-Z0-9])"#, "en"),
            (#"(?<![A-Z0-9])(?:\[ES\]|\(ES\)|ES)(?![A-Z0-9])"#, "es"),
            (#"(?<![A-Z0-9])(?:\[FR\]|\(FR\)|FR)(?![A-Z0-9])"#, "fr"),
            (#"(?<![A-Z0-9])(?:\[DE\]|\(DE\)|DE)(?![A-Z0-9])"#, "de"),
            (#"(?<![A-Z0-9])(?:\[PT\]|\(PT\)|PT)(?![A-Z0-9])"#, "pt")
        ]
        for (pattern, language) in shortMarkers where value.range(of: pattern, options: .regularExpression) != nil {
            if !found.contains(language) { found.append(language) }
        }
        if found.isEmpty, value.contains("🇮🇹") { found.append("it") }
        if found.isEmpty, value.contains("🇬🇧") || value.contains("🇺🇸") { found.append("en") }
        return found
    }

    /// Preferred-language-aware single result, keeping compatibility with existing callers.
    public static func language(in text: String, preferred: String? = nil) -> String? {
        let found = languages(in: text)
        if let preferred = preferred?.lowercased(),
           let match = found.first(where: { $0.lowercased() == preferred || ($0 == "multi") }) {
            return match == "multi" ? preferred : match
        }
        return found.first
    }
}
