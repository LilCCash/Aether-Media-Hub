import SwiftUI

/// Aether's measures, in one place: every screen uses these steps instead of its own numbers, so spacing and corners read as
/// one app. The corners follow the viewer's «Angoli» setting (`AetherStyle.posterRadius`): the default (Morbidi, 20) gives the
/// base values below; Netti makes everything sharper, Bolle rounder.
enum Space {
    /// 2 — between a title and its own subtitle line.
    static let hair: CGFloat = 2
    /// 4
    static let xs: CGFloat = 4
    /// 8 — inside a chip, between an icon and its label.
    static let s: CGFloat = 8
    /// 12 — between items of a row, inside a compact card.
    static let m: CGFloat = 12
    /// 16 — page margin, inside a card.
    static let l: CGFloat = 16
    /// 20
    static let xl: CGFloat = 20
    /// 24 — between groups inside a section.
    static let xxl: CGFloat = 24
    /// 32 — between sections of a page.
    static let section: CGFloat = 32
}

/// Corner sizes, by role.
enum Radius {
    /// Badges, small thumbnails, progress tracks.
    case small
    /// Buttons, chips that are not capsules, rows, tiles.
    case medium
    /// Cards and panels.
    case large
    /// Featured cards, sheets.
    case xlarge

    fileprivate var base: CGFloat {
        switch self {
        case .small: return 6
        case .medium: return 12
        case .large: return 18
        case .xlarge: return 26
        }
    }
}

extension AetherStyle {
    /// 1 at the default corner style (20 pt posters).
    var radiusScale: CGFloat { max(0.2, posterRadius / 20) }

    func radius(_ role: Radius) -> CGFloat {
        return max(2, (role.base * radiusScale).rounded())
    }
}

extension Color {
    /// A filled surface on the page (a row, a tile, a chip): the same tint of the text colour in light and dark.
    static var aetherSurface: Color { Color.primary.opacity(0.06) }
    /// A surface that must stand out a little more (selected rows, pressed states, fields).
    static var aetherSurfaceStrong: Color { Color.primary.opacity(0.10) }
    /// Hairline borders and separators.
    static var aetherHairline: Color { Color.primary.opacity(0.10) }
    /// Text and icons that are present but quieter than secondary (hints, disabled).
    static var aetherTertiary: Color { Color.primary.opacity(0.55) }
}

extension View {
    /// A filled, rounded surface that follows the viewer's corner setting.
    func aetherSurface(_ role: Radius = .medium, fill: Color = .aetherSurface, stroke: Bool = false) -> some View {
        modifier(AetherSurfaceModifier(role: role, fill: fill, stroke: stroke))
    }

    /// Clips to a rounded rectangle of the given role, following the viewer's corner setting.
    func aetherClip(_ role: Radius) -> some View {
        modifier(AetherClipModifier(role: role))
    }

    /// A page of the app (lists and settings included): Aether's background with the viewer's palette, wash and black options
    /// behind the content, instead of the plain system grey or black lists had before.
    func aetherPage() -> some View {
        self.scrollContentBackground(.hidden)
            .background { AetherBackdrop() }
    }
}

private struct AetherSurfaceModifier: ViewModifier {
    let role: Radius
    let fill: Color
    let stroke: Bool
    @Environment(\.aetherStyle) private var style

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radius(role), style: .continuous)
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(stroke ? Color.aetherHairline : .clear, lineWidth: 0.5))
    }
}

private struct AetherClipModifier: ViewModifier {
    let role: Radius
    @Environment(\.aetherStyle) private var style

    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: style.radius(role), style: .continuous))
    }
}
