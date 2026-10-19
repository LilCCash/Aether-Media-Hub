import SwiftUI
import AetherCore

/// Aether's visual language: deep "ether" backgrounds, luminous accents, generous radii.
/// Liquid Glass is applied sparingly (floating controls, bars, sheets); content stays opaque for legibility.
enum Theme {
    static func accent(for choice: AccentChoice) -> Color {
        switch choice {
        case .aurora: return Color(red: 0.43, green: 0.47, blue: 1.00)
        case .ember: return Color(red: 1.00, green: 0.48, blue: 0.27)
        case .jade: return Color(red: 0.18, green: 0.84, blue: 0.63)
        case .rose: return Color(red: 1.00, green: 0.36, blue: 0.60)
        case .sky: return Color(red: 0.24, green: 0.73, blue: 1.00)
        case .gold: return Color(red: 1.00, green: 0.76, blue: 0.28)
        }
    }

    // Surfaces adapt to the colour scheme; both are tuned for >= 4.5:1 text contrast.
    static let backgroundTop = Color("LaunchBackground")
    static let cardCorner: CGFloat = 14
    static let sheetCorner: CGFloat = 28
    static let pageMargin: CGFloat = 16

    static func fallbackGradient(for seed: String) -> LinearGradient {
        // Deterministic placeholder colours per title so skeleton-less posters still look intentional.
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let hue = Double(hash % 360) / 360.0
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.45),
                                       Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.25)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    /// Secondary text with enough contrast on the app's light and dark backdrops (the system `.secondary` label
    /// colour stays under 4.5:1 on tinted light backgrounds, which Apple's accessibility audit flags).
    static var aetherSecondary: Color { Color.primary.opacity(0.72) }
}

extension Font {
    /// Rounded bold title that follows Dynamic Type: the point size only picks the closest text style.
    static func aetherTitle(_ size: CGFloat = 28) -> Font {
        let style: Font.TextStyle
        switch size {
        case 32...: style = .largeTitle
        case 26..<32: style = .title
        case 21..<26: style = .title2
        case 18..<21: style = .title3
        default: style = .headline
        }
        return .system(style, design: .rounded).weight(.bold)
    }
    static func aetherHeadline() -> Font { .system(.headline, design: .rounded).weight(.semibold) }
    static func aetherCaption() -> Font { .system(.caption, design: .rounded) }
}

/// Page backdrop: a soft aurora wash behind scrolling content.
struct AetherBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            Color(scheme == .dark ? UIColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1) : UIColor.systemGroupedBackground)
            if !settings.reduceEffects {
                RadialGradient(colors: [settings.accentColor.opacity(scheme == .dark ? 0.28 : 0.14), .clear],
                               center: .topTrailing, startRadius: 20, endRadius: 420)
                RadialGradient(colors: [Color.cyan.opacity(scheme == .dark ? 0.16 : 0.08), .clear],
                               center: .bottomLeading, startRadius: 20, endRadius: 380)
            }
        }
        .ignoresSafeArea()
    }
}
