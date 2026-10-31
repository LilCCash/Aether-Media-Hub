import SwiftUI
import AetherCore

private let previewColors: [[Color]] = [
    [Color(red: 0.36, green: 0.27, blue: 0.75), Color(red: 0.13, green: 0.55, blue: 0.85)],
    [Color(red: 0.85, green: 0.35, blue: 0.40), Color(red: 0.95, green: 0.65, blue: 0.30)],
    [Color(red: 0.15, green: 0.60, blue: 0.50), Color(red: 0.30, green: 0.80, blue: 0.55)],
    [Color(red: 0.55, green: 0.25, blue: 0.65), Color(red: 0.85, green: 0.45, blue: 0.75)],
]

/// A live sketch of how a Home row looks with the chosen card style and size: the cards have the real widths, so choosing another style or
/// size changes the sketch at once (animated).
struct HomeCardPreview: View {
    let style: HomeCardStyle
    let size: PosterSize
    @Environment(\.aetherStyle) private var aetherStyle

    private func tile(_ index: Int, width: CGFloat) -> some View {
        let ratio = HomeCardMetrics.aspectRatio(style: style)
        return VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: aetherStyle.posterRadius, style: .continuous)
                .fill(LinearGradient(colors: previewColors[index % previewColors.count], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: width, height: width / ratio)
                .overlay(Image(systemName: style == .poster ? "film" : "play.rectangle.fill").font(.title2).foregroundStyle(.white.opacity(0.55)))
            Capsule().fill(Color.primary.opacity(0.22)).frame(width: width * 0.7, height: 8)
            Capsule().fill(Color.primary.opacity(0.12)).frame(width: width * 0.4, height: 6)
        }
    }

    private var compactRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: aetherStyle.posterRadius, style: .continuous)
                .fill(LinearGradient(colors: previewColors[0], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 84, height: 47)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color.primary.opacity(0.22)).frame(width: 130, height: 9)
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 90, height: 7)
            }
        }
    }

    /// The sketch's own height (the cards are wider than the screen: only the height decides the layout, the width is cut at the row's edges).
    private var sketchHeight: CGFloat {
        if style == .compact { return 47 }
        let width = HomeCardMetrics.width(style: style, size: size)
        return width / HomeCardMetrics.aspectRatio(style: style) + 32
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Anteprima").font(.caption).foregroundStyle(Color.aetherSecondary)
            Color.clear
                .frame(height: sketchHeight)
                .overlay(alignment: .topLeading) {
                    if style == .compact {
                        compactRow
                    } else {
                        let width = HomeCardMetrics.width(style: style, size: size)
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(0..<3, id: \.self) { tile($0, width: width) }
                        }
                        .fixedSize()
                    }
                }
                .clipped()
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: style)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: size)
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
    }
}

/// The sketch of the «In evidenza» section in its two looks.
struct HeroPreview: View {
    let style: HeroStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Anteprima").font(.caption).foregroundStyle(Color.aetherSecondary)
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: previewColors[0], startPoint: .topLeading, endPoint: .bottomTrailing)
                if style == .fullBleed {
                    LinearGradient(colors: [.clear, Color(UIColor.systemBackground)], startPoint: .center, endPoint: .bottom)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(style == .fullBleed ? Color.primary.opacity(0.55) : Color.white.opacity(0.85)).frame(width: 130, height: 12)
                    Capsule().fill(style == .fullBleed ? Color.primary.opacity(0.3) : Color.white.opacity(0.5)).frame(width: 90, height: 8)
                }
                .padding(14)
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: style == .fullBleed ? 0 : 18, style: .continuous))
            .padding(.horizontal, style == .fullBleed ? 0 : 12)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: style)
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
    }
}
