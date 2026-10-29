import Foundation

// The look-and-feel choices of Aether 1.1. Every enum has a stable raw value (it is what is stored and what a newer or older
// build reads back) and an Italian title. Unknown raw values decode to the default, see `AppearanceSettings`.

/// How the cards of a Home section are drawn.
public enum HomeCardStyle: String, Codable, CaseIterable, Sendable {
    /// Portrait poster (2:3).
    case poster
    /// Wide card (16:9) built on the backdrop picture, like "Continua a guardare" in the Library.
    case landscape
    /// Small thumbnail with the text beside it (only the "next episode" section offers it).
    case compact

    public var title: String {
        switch self {
        case .poster: return "Locandina"
        case .landscape: return "Orizzontale"
        case .compact: return "Compatta"
        }
    }

    /// Styles a section can be shown in, the default first. Empty for sections without cards.
    public static func allowed(for sectionID: String) -> [HomeCardStyle] {
        switch sectionID {
        case HomeSectionConfig.continueWatching: return [.landscape, .poster]
        case HomeSectionConfig.nextUp: return [.compact, .landscape, .poster]
        case HomeSectionConfig.watchlist, HomeSectionConfig.catalogs: return [.poster, .landscape]
        default: return []
        }
    }

    public static func defaultStyle(for sectionID: String) -> HomeCardStyle? {
        return allowed(for: sectionID).first
    }
}

/// How the featured titles at the top of the Home look.
public enum HeroStyle: String, Codable, CaseIterable, Sendable {
    /// A rounded card with the title over the picture (the 1.0 look).
    case card
    /// The picture runs edge to edge and fades into the page, with the title over it.
    case fullBleed

    public var title: String {
        switch self {
        case .card: return "Card"
        case .fullBleed: return "Schermo intero"
        }
    }
}

/// The colours of the page background. They tint only the decorative washes behind the content, never text or controls.
public enum AppPalette: String, Codable, CaseIterable, Sendable {
    case aether, sunset, ocean, forest, candy, midnight, cinema, popcorn

    public var title: String {
        switch self {
        case .aether: return "Aether"
        case .sunset: return "Tramonto"
        case .ocean: return "Oceano"
        case .forest: return "Foresta"
        case .candy: return "Zucchero filato"
        case .midnight: return "Mezzanotte"
        case .cinema: return "Sala buia"
        case .popcorn: return "Popcorn"
        }
    }

    /// A small picture for the chooser.
    public var emoji: String {
        switch self {
        case .aether: return "✨"
        case .sunset: return "🌅"
        case .ocean: return "🌊"
        case .forest: return "🌲"
        case .candy: return "🍬"
        case .midnight: return "🌌"
        case .cinema: return "🎞️"
        case .popcorn: return "🍿"
        }
    }

    /// The secret that has to be unlocked before this palette can be chosen.
    public var requiredSecret: AppSecret? {
        return self == .popcorn ? .popcorn : nil
    }

    /// Two `#RRGGBB` washes. `nil` for `.aether`, which follows the accent colour like 1.0 did.
    public var washes: (primary: String, secondary: String)? {
        switch self {
        case .aether: return nil
        case .sunset: return ("#FF6B4A", "#B03CFF")
        case .ocean: return ("#1FB6FF", "#12D6B0")
        case .forest: return ("#2FBF71", "#C8E04A")
        case .candy: return ("#FF6FB5", "#7AD7FF")
        case .midnight: return ("#4C3FFF", "#9B5CFF")
        case .cinema: return ("#D9A441", "#7A1F2B")
        case .popcorn: return ("#FFC83D", "#E5383B")
        }
    }

    /// The most opaque a wash is ever drawn. The contrast of text over the page is checked at this opacity.
    public static let maxWashOpacity: Double = 0.30
}

/// The motion and shape of the page background.
public enum BackdropStyle: String, Codable, CaseIterable, Sendable {
    /// Two soft washes in opposite corners (the 1.0 look).
    case aurora
    /// The washes drift slowly. Still when animations are off or Reduce Motion is on.
    case flow
    /// A cone of light falling from the top, like a cinema projector.
    case spotlight
    /// No decoration.
    case plain

    public var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .flow: return "Onde"
        case .spotlight: return "Faro"
        case .plain: return "Tinta unita"
        }
    }
}

/// The frame drawn around posters and cards.
public enum CardChrome: String, Codable, CaseIterable, Sendable {
    case standard, outline, shadow, glow

    public var title: String {
        switch self {
        case .standard: return "Standard"
        case .outline: return "Contorno"
        case .shadow: return "Ombra"
        case .glow: return "Alone"
        }
    }
}

/// How round the corners of posters and cards are.
public enum CornerStyle: String, Codable, CaseIterable, Sendable {
    case sharp, standard, rounded, bubble

    public var title: String {
        switch self {
        case .sharp: return "Netti"
        case .standard: return "Standard"
        case .rounded: return "Morbidi"
        case .bubble: return "Bolle"
        }
    }

    /// Corner radius of a poster-sized card in points.
    public var radius: Double {
        switch self {
        case .sharp: return 4
        case .standard: return 14
        case .rounded: return 20
        case .bubble: return 28
        }
    }
}

/// The typeface of Aether's own titles and card text.
public enum TitleFont: String, Codable, CaseIterable, Sendable {
    case rounded, standard, serif, mono

    public var title: String {
        switch self {
        case .rounded: return "Arrotondato"
        case .standard: return "Classico"
        case .serif: return "Con grazie"
        case .mono: return "Macchina da scrivere"
        }
    }
}

/// Hidden extras. Stored by raw id so an id written by a newer build survives a round trip through an older one.
public enum AppSecret: String, CaseIterable, Sendable {
    case popcorn
}

// MARK: - Section order

public enum HomeSectionOrdering {
    /// Moves the section with `id` by `delta` positions (negative = up), clamped to the list. Unknown ids change nothing.
    public static func moved(_ sections: [HomeSectionConfig], id: String, by delta: Int) -> [HomeSectionConfig] {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return sections }
        let target = min(max(index + delta, 0), sections.count - 1)
        guard target != index else { return sections }
        var result = sections
        let item = result.remove(at: index)
        result.insert(item, at: target)
        return result
    }

    public static func canMove(_ sections: [HomeSectionConfig], id: String, by delta: Int) -> Bool {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + delta
        return target >= 0 && target < sections.count
    }
}

// MARK: - Greeting

public enum Greeting {
    public static let maxNameLength = 24

    /// A name as it may be shown: no line breaks, collapsed spaces, at most 24 characters. Empty when nothing is left.
    public static func sanitizedName(_ raw: String) -> String {
        let flattened = raw.components(separatedBy: .newlines).joined(separator: " ")
        let collapsed = flattened.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }

    /// The line at the top of the Home. `hour` is 0...23 in the viewer's time zone.
    public static func text(hour: Int, name: String) -> String {
        let who = sanitizedName(name)
        switch hour {
        case 0..<5:
            return who.isEmpty ? "Ancora sveglio?" : "Ancora sveglio, \(who)?"
        case 5..<12:
            return who.isEmpty ? "Buongiorno" : "Buongiorno, \(who)"
        case 12..<18:
            return who.isEmpty ? "Buon pomeriggio" : "Buon pomeriggio, \(who)"
        default:
            return who.isEmpty ? "Buonasera" : "Buonasera, \(who)"
        }
    }
}

// MARK: - Contrast

/// WCAG contrast arithmetic on `#RRGGBB` colours, used to prove that every palette keeps text readable.
public enum ContrastRatio {
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public static func luminance(_ color: (r: Double, g: Double, b: Double)) -> Double {
        func channel(_ value: Double) -> Double {
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    public static func ratio(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// `foreground` painted at `opacity` over `background`.
    public static func blend(_ foreground: (r: Double, g: Double, b: Double), opacity: Double,
                             over background: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        let alpha = min(max(opacity, 0), 1)
        return (foreground.r * alpha + background.r * (1 - alpha),
                foreground.g * alpha + background.g * (1 - alpha),
                foreground.b * alpha + background.b * (1 - alpha))
    }
}
