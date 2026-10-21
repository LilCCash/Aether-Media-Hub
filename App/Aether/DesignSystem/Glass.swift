import SwiftUI

// Native Liquid Glass (iOS 26+) with a material fallback for earlier systems or when the user asked for
// reduced visual effects / Reduce Transparency. Gated at compile time so the project also builds with older SDKs.

private struct AetherGlassInteractiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether glass surfaces may use the touch-reactive ("interactive") effect. The player turns it off.
    var aetherGlassInteractive: Bool {
        get { self[AetherGlassInteractiveKey.self] }
        set { self[AetherGlassInteractiveKey.self] = newValue }
    }
}

extension View {
    /// Floating glass surface in the given shape.
    @ViewBuilder
    func aetherGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(AetherGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    func aetherGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        aetherGlass(in: Capsule(), tint: tint, interactive: interactive)
    }

    func aetherGlassCard(cornerRadius: CGFloat = 20, tint: Color? = nil) -> some View {
        aetherGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }
}

private struct AetherGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.aetherGlassInteractive) private var allowsInteractive

    func body(content: Content) -> some View {
        if settings.reduceEffects || reduceTransparency {
            content.background(Color(UIColor.secondarySystemBackground).opacity(0.96), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(glass, in: shape)
            } else {
                legacy(content)
            }
            #else
            legacy(content)
            #endif
        }
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint = tint { glass = glass.tint(tint.opacity(0.35)) }
        if interactive && allowsInteractive { glass = glass.interactive() }
        return glass
    }
    #endif

    private func legacy(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

/// Groups nearby glass shapes so they blend and morph on iOS 26; a plain container before that.
struct AetherGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// Round glass icon button used for floating controls (close, favourite, share…).
struct GlassIconButton: View {
    let systemName: String
    var accessibilityLabel: String
    var tint: Color? = nil
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .aetherGlass(in: Circle(), tint: tint, interactive: true)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Primary call-to-action: prominent glass on iOS 26, filled capsule before.
struct PrimaryActionButtonStyle: ButtonStyle {
    @EnvironmentObject private var settings: SettingsStore

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background(Capsule().fill(settings.accentColor.gradient))
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.6))
            .scaleEffect(configuration.isPressed && settings.animationsEnabled ? 0.97 : 1)
            .animation(settings.animationsEnabled ? .spring(response: 0.25, dampingFraction: 0.7) : nil, value: configuration.isPressed)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .aetherGlassCapsule(interactive: true)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
