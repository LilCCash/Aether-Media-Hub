import Foundation

/// Best-effort parser for release-title language tags (for example "Show.S01E01.1080p.ITA.WEB-DL").
/// It deliberately requires explicit, token-bounded markers to avoid mistaking ordinary words for language labels.
public enum ReleaseLanguageDetector {
    public static func language(in text: String) -> String? {
        let value = text.uppercased()
        if value.contains("🇮🇹") { return "it" }
        if value.contains("🇬🇧") || value.contains("🇺🇸") { return "en" }
        let markers: [(String, String)] = [
            (#"(?<![A-Z0-9])(?:ITA|ITALIAN|ITALIANO)(?![A-Z0-9])"#, "it"),
            (#"(?:\\[\\s*IT\\s*\\]|\\(\\s*IT\\s*\\)|\\.IT\\.)"#, "it"),
            (#"(?<![A-Z0-9])(?:ENG|ENGLISH)(?![A-Z0-9])"#, "en"),
            (#"(?<![A-Z0-9])(?:FRA|FRE|FRENCH|FRANCAIS)(?![A-Z0-9])"#, "fr"),
            (#"(?<![A-Z0-9])(?:SPA|ESP|SPANISH|CASTELLANO)(?![A-Z0-9])"#, "es"),
            (#"(?<![A-Z0-9])(?:DEU|GER|GERMAN)(?![A-Z0-9])"#, "de"),
            (#"(?<![A-Z0-9])(?:POR|PTBR|PORTUGUESE)(?![A-Z0-9])"#, "pt"),
            (#"(?<![A-Z0-9])(?:MULTI|MULTILANGUAGE|DUAL[ ._-]?AUDIO|MULTI[ ._-]?AUDIO)(?![A-Z0-9])"#, "multi")
        ]
        for (pattern, language) in markers where value.range(of: pattern, options: .regularExpression) != nil {
            return language
        }
        return nil
    }
}
