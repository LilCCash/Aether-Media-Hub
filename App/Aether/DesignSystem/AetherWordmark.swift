import SwiftUI

/// The Aether mark (a luminous triangle) with the name, for the top of the Home.
struct AetherWordmark: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 6) {
            AetherTriangle()
                .stroke(LinearGradient(colors: [Color(red: 0.55, green: 0.8, blue: 1), settings.accentColor, Color(red: 0.8, green: 0.4, blue: 1)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 18)
                .shadow(color: settings.accentColor.opacity(0.7), radius: 6)
            Text("Aether").font(.system(size: 19, weight: .bold, design: .rounded))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aether")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct AetherTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.midX, y: rect.midY * 0.95))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.14, y: rect.maxY))
        return path
    }
}
