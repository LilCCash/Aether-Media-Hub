import SwiftUI
import UIKit

/// Soft taps, switched on and off by Aspetto ▸ Movimento ▸ Feedback tattile. A plain global like `AetherTypography`:
/// `SettingsStore` keeps it in step with the setting. Only the main thread touches it.
enum Haptics {
    nonisolated(unsafe) static var enabled = true

    @MainActor static func tap() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @MainActor static func select() {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @MainActor static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// A button that gives a little under the finger: the card shrinks a touch while it is pressed. Follows the animations switch.
struct PressableStyle: ButtonStyle {
    @EnvironmentObject private var settings: SettingsStore

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && settings.animationsEnabled ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(settings.animationsEnabled ? .spring(response: 0.28, dampingFraction: 0.72) : nil, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// A rounded panel for the dashboards (Profile, Storage…): the glass of the app on a soft fill.
struct AetherPanel<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.aetherStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = title {
                HStack(spacing: 8) {
                    if let symbol = symbol { Image(systemName: symbol).foregroundStyle(.tint) }
                    Text(title).font(.aetherHeadline())
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: style.glassCardRadius, style: .continuous))
        .aetherCardChrome(cornerRadius: style.glassCardRadius)
    }
}
