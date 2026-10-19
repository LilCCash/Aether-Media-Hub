import SwiftUI
import AetherCore

/// Renders one subtitle block with the user's style (size, colour, weight, outline, background).
/// Used by the player overlay and by the live preview in Settings so both always look identical.
struct SubtitleText: View {
    let text: String
    let style: SubtitleStyle
    /// 1 = the size used in a 390 pt wide portrait preview; the player passes a larger value in landscape.
    let scale: CGFloat

    private var fontSize: CGFloat { 19 * CGFloat(style.sizePercent / 100) * scale }

    var body: some View {
        let outline = Color(hex: style.outlineColor)
        Text(text)
            .font(.system(size: fontSize, weight: style.isBold ? .bold : .semibold))
            .foregroundStyle(Color(hex: style.textColor))
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, style.backgroundOpacity > 0 ? 10 : 0)
            .padding(.vertical, style.backgroundOpacity > 0 ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(hex: style.backgroundColor).opacity(style.backgroundOpacity))
            )
            // SwiftUI has no text stroke: four hard shadows around the glyphs give a clean outline.
            .shadow(color: style.outlineEnabled ? outline : .clear, radius: 0, x: 1, y: 1)
            .shadow(color: style.outlineEnabled ? outline : .clear, radius: 0, x: -1, y: -1)
            .shadow(color: style.outlineEnabled ? outline : .clear, radius: 0, x: 1, y: -1)
            .shadow(color: style.outlineEnabled ? outline : .clear, radius: 0, x: -1, y: 1)
            .shadow(color: style.outlineEnabled ? outline.opacity(0.6) : .clear, radius: 2, x: 0, y: 1)
            .accessibilityLabel(text)
    }
}
