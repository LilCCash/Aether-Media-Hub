import SwiftUI

/// The Theater Mode logo with the version of its interface, shown on the About page.
struct TheaterBadge: View {
    @AppStorage(TheaterPrefs.palette) private var palette = 0
    @State private var taps = 0
    @State private var lastTap = Date.distantPast
    @State private var turns = 0.0
    @State private var shout = false

    var body: some View {
        let accent = TheaterPalette.color(palette)
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(RadialGradient(colors: [accent.opacity(shout ? 0.7 : 0.25), .clear], center: .center, startRadius: 2, endRadius: 60))
                    .frame(width: 120, height: 120)
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 44)).foregroundStyle(accent)
                    .rotation3DEffect(.degrees(turns), axis: (x: 0, y: 1, z: 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { tapped() }
            Text("Theater Mode").font(.aetherTitle(22))
            Text(shout ? "CIAK, SI GIRA!" : "Interfaccia versione \(TheaterPrefs.version)")
                .font(shout ? .footnote.weight(.black) : .footnote)
                .tracking(shout ? 3 : 0)
                .foregroundStyle(shout ? accent : Color.aetherSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Theater Mode, interfaccia versione \(TheaterPrefs.version)")
        .accessibilityIdentifier("about.theaterBadge")
    }

    private func tapped() {
        let now = Date()
        taps = now.timeIntervalSince(lastTap) < 1.2 ? taps + 1 : 1
        lastTap = now
        if taps >= 5 {
            taps = 0
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeInOut(duration: 0.9)) { turns += 360 }
            withAnimation(.easeOut(duration: 0.2)) { shout = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                withAnimation(.easeOut(duration: 0.4)) { shout = false }
            }
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
