import SwiftUI
import AetherCore

/// The typeface Aether's own titles and card text use. A plain global read by the font helpers: `SettingsStore` sets it
/// before any view is redrawn for a changed setting. Only the main thread touches it.
enum AetherTypography {
    nonisolated(unsafe) static var design: Font.Design = .rounded

    static func fontDesign(for font: TitleFont) -> Font.Design {
        switch font {
        case .rounded: return .rounded
        case .standard: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

/// The viewer's look-and-feel choices as values the views read from the environment. Injected once above the whole app
/// (see `ThemedRoot`), so sheets and full-screen covers get it too.
struct AetherStyle: Equatable {
    var palette: AppPalette = .aether
    var backdrop: BackdropStyle = .aurora
    var chrome: CardChrome = .standard
    var posterRadius: CGFloat = 14
    var titleFont: TitleFont = .rounded

    init() {}

    init(_ appearance: AppearanceSettings) {
        palette = appearance.palette
        backdrop = appearance.backdrop
        chrome = appearance.cardChrome
        posterRadius = CGFloat(appearance.cornerStyle.radius)
        titleFont = appearance.titleFont
    }

    /// 16:9 cards are a little rounder than posters (16 against 14 by default, as in 1.0).
    var landscapeRadius: CGFloat { posterRadius + 2 }
    var thumbnailRadius: CGFloat { max(posterRadius - 2, 2) }
    var glassCardRadius: CGFloat { posterRadius + 4 }
    /// The featured card (28 by default), capped so a very round setting does not eat the picture.
    var heroRadius: CGFloat { min(posterRadius * 2, 36) }
}

private struct AetherStyleKey: EnvironmentKey {
    static let defaultValue = AetherStyle()
}

extension EnvironmentValues {
    var aetherStyle: AetherStyle {
        get { self[AetherStyleKey.self] }
        set { self[AetherStyleKey.self] = newValue }
    }
}

/// The frame around a poster or card: hairline (default), accent outline, soft shadow or accent glow.
struct CardChromeModifier: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.aetherStyle) private var style
    @EnvironmentObject private var settings: SettingsStore

    private var strokeColor: Color {
        switch style.chrome {
        case .standard, .shadow: return Color.primary.opacity(0.10)
        case .outline: return settings.accentColor.opacity(0.85)
        case .glow: return settings.accentColor.opacity(0.35)
        }
    }

    private var strokeWidth: CGFloat {
        switch style.chrome {
        case .standard, .shadow: return 0.5
        case .outline: return 1.5
        case .glow: return 0.75
        }
    }

    private var shadowColor: Color {
        switch style.chrome {
        case .standard, .outline: return .clear
        case .shadow: return .black.opacity(0.38)
        case .glow: return settings.accentColor.opacity(0.55)
        }
    }

    private var shadowRadius: CGFloat {
        switch style.chrome {
        case .standard, .outline: return 0
        case .shadow: return 8
        case .glow: return 10
        }
    }

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(strokeColor, lineWidth: strokeWidth))
            .shadow(color: shadowColor, radius: shadowRadius, y: style.chrome == .shadow ? 5 : 0)
    }
}

extension View {
    /// Apply after the picture is clipped to its rounded shape.
    func aetherCardChrome(cornerRadius: CGFloat) -> some View {
        modifier(CardChromeModifier(cornerRadius: cornerRadius))
    }
}

/// Injects the style and the typeface above the whole app.
struct ThemedRoot: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        RootView()
            .environment(\.aetherStyle, AetherStyle(settings.value.appearance))
    }
}
