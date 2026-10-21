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
    /// Bold title in the chosen typeface (rounded by default) that follows Dynamic Type: the point size only picks the closest text style.
    static func aetherTitle(_ size: CGFloat = 28) -> Font {
        let style: Font.TextStyle
        switch size {
        case 32...: style = .largeTitle
        case 26..<32: style = .title
        case 21..<26: style = .title2
        case 18..<21: style = .title3
        default: style = .headline
        }
        return .system(style, design: AetherTypography.design).weight(.bold)
    }
    static func aetherHeadline() -> Font { .system(.headline, design: AetherTypography.design).weight(.semibold) }
    static func aetherCaption() -> Font { .system(.caption, design: AetherTypography.design) }
}

/// Page backdrop: soft colour washes behind scrolling content, in the palette and motion the viewer chose. Washes never go
/// above `AppPalette.maxWashOpacity`, the opacity at which every palette is checked for text contrast.
struct AetherBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.aetherStyle) private var style
    @EnvironmentObject private var settings: SettingsStore

    private var primary: Color {
        if let washes = style.palette.washes { return Color(hex: washes.primary) }
        return settings.accentColor
    }

    private var secondary: Color {
        if let washes = style.palette.washes { return Color(hex: washes.secondary) }
        return .cyan
    }

    private var strong: Double { scheme == .dark ? 0.28 : 0.14 }
    private var soft: Double { scheme == .dark ? 0.16 : 0.08 }

    /// Drifting washes only move when nothing asks for calm: the animations switch, Reduce Motion, Low Power Mode, and a
    /// foreground app.
    private var isMoving: Bool {
        return settings.animationsEnabled && !reduceMotion && scenePhase == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        ZStack {
            Color(scheme == .dark ? UIColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1) : UIColor.systemGroupedBackground)
            if !settings.reduceEffects {
                washes
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var washes: some View {
        switch style.backdrop {
        case .plain:
            EmptyView()
        case .aurora:
            RadialGradient(colors: [primary.opacity(strong), .clear], center: .topTrailing, startRadius: 20, endRadius: 420)
            RadialGradient(colors: [secondary.opacity(soft), .clear], center: .bottomLeading, startRadius: 20, endRadius: 380)
        case .spotlight:
            RadialGradient(colors: [primary.opacity(min(strong * 1.6, AppPalette.maxWashOpacity)), .clear],
                           center: UnitPoint(x: 0.5, y: -0.05), startRadius: 10, endRadius: 600)
            RadialGradient(colors: [secondary.opacity(soft), .clear], center: .bottom, startRadius: 20, endRadius: 360)
        case .flow:
            if isMoving {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                    flow(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                flow(at: 0)
            }
        }
    }

    private func flow(at t: Double) -> some View {
        ZStack {
            RadialGradient(colors: [primary.opacity(strong), .clear],
                           center: UnitPoint(x: 0.85 + 0.12 * sin(t / 8), y: 0.05 + 0.08 * cos(t / 6)),
                           startRadius: 20, endRadius: 420)
            RadialGradient(colors: [secondary.opacity(soft), .clear],
                           center: UnitPoint(x: 0.10 + 0.14 * cos(t / 10), y: 0.95 - 0.10 * sin(t / 7)),
                           startRadius: 20, endRadius: 380)
            RadialGradient(colors: [primary.opacity(soft * 0.6), .clear],
                           center: UnitPoint(x: 0.5 + 0.30 * sin(t / 12), y: 0.5 + 0.25 * cos(t / 9)),
                           startRadius: 10, endRadius: 300)
        }
    }
}
