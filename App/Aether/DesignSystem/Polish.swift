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

extension View {
    /// A block of a page (a section of the Home, a panel, an empty page) comes on stage the first time it is shown: it fades
    /// in while rising a little. `order` delays the blocks of one page one after the other.
    func aetherEntrance(_ order: Int = 0) -> some View { modifier(EntranceModifier(order: order)) }

    /// A symbol that changes (＋ to ✓, an empty star to a full one) morphs into the new one instead of switching.
    func aetherSymbolSwap() -> some View { modifier(SymbolSwapModifier()) }
}

private struct EntranceModifier: ViewModifier {
    let order: Int
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private var isOn: Bool {
        // Automated runs never wait for a block to come on stage.
        return settings.animationsEnabled && settings.value.appearance.entranceMotion && !settings.reduceEffects && !reduceMotion
            && !ProcessInfo.processInfo.arguments.contains("-AETHER_UITEST")
    }

    func body(content: Content) -> some View {
        if isOn {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 14)
                .onAppear {
                    guard !shown else { return }
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86).delay(min(0.3, Double(order) * 0.06))) { shown = true }
                }
        } else {
            content
        }
    }
}

private struct SymbolSwapModifier: ViewModifier {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if settings.animationsEnabled && settings.value.appearance.symbolMotion && !reduceMotion {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}
