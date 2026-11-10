import SwiftUI

// The finishing touches shared by every screen: the light edge on cards and filled controls, and the way cards come into view
// while scrolling. All of it follows «Animazioni» and Reduce Motion, and none of it changes a layout.

/// A thin light edge, brighter at the top-left: what makes a card or a filled button read as a physical surface.
struct Sheen<S: InsettableShape>: View {
    let shape: S
    var strength: Double = 1
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        if settings.value.appearance.cardSheen && strength > 0 { edge }
    }

    private var edge: some View {
        shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.34 * strength), location: 0),
                                                  .init(color: .white.opacity(0.06 * strength), location: 0.38),
                                                  .init(color: .clear, location: 0.7)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A card of a horizontal row: it settles to full size as it comes in from the edge.
    func aetherRowMotion() -> some View { modifier(ScrollMotionModifier(axis: .horizontal)) }

    /// A card of a grid or a list: it rises into place as it scrolls into view.
    func aetherGridMotion() -> some View { modifier(ScrollMotionModifier(axis: .vertical)) }
}

private struct ScrollMotionModifier: ViewModifier {
    let axis: Axis
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if settings.animationsEnabled && settings.value.appearance.scrollMotion && !settings.reduceEffects && !reduceMotion {
            let horizontal = axis == .horizontal
            content.scrollTransition(.interactive(timingCurve: .easeOut).threshold(.visible(horizontal ? 0.55 : 0.12)), axis: axis) { view, phase in
                view.scaleEffect(phase.isIdentity ? 1 : (horizontal ? 0.94 : 0.95))
                    .opacity(phase.isIdentity ? 1 : (horizontal ? 0.72 : 0.55))
            }
        } else {
            content
        }
    }
}
