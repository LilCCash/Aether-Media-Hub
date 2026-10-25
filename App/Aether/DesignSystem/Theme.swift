import SwiftUI
import CoreImage
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
    /// Cinematic title page: the whole screen takes the film's colours instead of the app's background.
    var immersive = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.aetherStyle) private var style
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var mood = CinematicMood.shared

    private var primary: Color {
        if style.mood, let color = mood.color { return color }
        if let washes = style.palette.washes { return Color(hex: washes.primary) }
        return settings.accentColor
    }

    private var secondary: Color {
        if style.mood, let color = mood.color { return color.opacity(0.8) }
        if let washes = style.palette.washes { return Color(hex: washes.secondary) }
        return .cyan
    }

    private var intensity: Double { return min(max(settings.value.appearance.backdropIntensity, 0), 1.5) }
    /// AMOLED keeps the black and only lets a faint wash through; the cinematic mode lets the film's colours speak louder.
    private var boost: Double { style.amoled ? 0.45 : (style.cinematic ? 1.5 : 1) }
    private var strong: Double { (scheme == .dark ? 0.28 : 0.14) * intensity * boost }
    private var soft: Double { (scheme == .dark ? 0.16 : 0.08) * intensity * boost }

    /// Drifting washes only move when nothing asks for calm: the animations switch, Reduce Motion, Low Power Mode, and a
    /// foreground app.
    private var isMoving: Bool {
        // An endless animation keeps XCUITest from ever seeing the app idle, so the automated runs never move the washes.
        return settings.animationsEnabled && !reduceMotion && scenePhase == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !ProcessInfo.processInfo.arguments.contains("-AETHER_UITEST")
    }

    var body: some View {
        ZStack {
            if style.amoled {
                Color.black
            } else if let hex = settings.value.appearance.customBackgroundHex {
                Color(hex: hex)
            } else {
                Color(scheme == .dark ? UIColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1) : UIColor.systemGroupedBackground)
            }
            if !settings.reduceEffects && settings.value.appearance.showHalos {
                washes
            }
            if style.cinematic && style.mood, let color = mood.color {
                moodGradient(color)
            }
        }
        .animation(style.motion ? .easeInOut(duration: 1.1) : nil, value: mood.color)
        .ignoresSafeArea()
    }

    /// The film's colour as a deep tone (dark scheme) or a pale tint (light scheme) of the same hue.
    private func tone(_ color: Color, _ brightness: Double) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, value: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
        let dark = scheme == .dark || immersive
        return Color(hue: Double(hue), saturation: Double(min(1, saturation)) * (dark ? 0.95 : 0.35),
                     brightness: dark ? brightness * (style.amoled ? 0.6 : 1) : 0.97)
    }

    @ViewBuilder
    private func moodGradient(_ color: Color) -> some View {
        if immersive {
            LinearGradient(colors: [tone(color, 0.62), tone(color, 0.34), tone(color, 0.12)], startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(colors: [tone(color, 0.55).opacity(scheme == .dark ? 0.85 : 0.6), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.75))
        }
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

/// The colour of the film on screen, for the Dynamic Cinematic UI. Set by the title page, cleared when it closes.
@MainActor
final class CinematicMood: ObservableObject {
    static let shared = CinematicMood()
    @Published var color: Color?
    /// The colour of the Home's featured film: what the other screens go back to when a title page closes.
    var homeColor: Color?

    /// A lively, not-too-light average of the picture (the backdrop reads well over it).
    static func color(fromURL string: String?) async -> Color? {
        guard let string, let url = URL(string: string),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = CIImage(data: data) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(output, toBitmap: &pixel, rowBytes: 4,
                                                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: Double(hue), saturation: Double(min(1, max(saturation, 0.45))), brightness: Double(min(0.9, max(brightness, 0.55))))
    }
}
