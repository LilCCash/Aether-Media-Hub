import SwiftUI

/// The opening card of Theater Mode: the name in marquee lettering lit by a projector beam that flickers on, then the lights go
/// up on the stage underneath. With reduced motion (or animations off) it is a short still card.
struct TheaterIntro: View {
    let animated: Bool
    let finished: () -> Void
    @State private var beam = 0.0
    @State private var reveal = 0.0
    @State private var fade = 1.0

    private let gold = Color(red: 1.0, green: 0.82, blue: 0.45)

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                // The projector cone: a wide wedge from the top left corner that widens towards the lettering.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: -10))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.35, y: proxy.size.height * 0.34))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.95, y: proxy.size.height * 0.78))
                    path.addLine(to: CGPoint(x: 0, y: 8))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.white.opacity(0.55), gold.opacity(0.18), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .blur(radius: 14)
                .blendMode(.plusLighter)
                .opacity(beam)
                VStack(spacing: 10) {
                    Text("★  ★  ★")
                        .font(.footnote).tracking(6).foregroundStyle(gold)
                    Text("THEATER MODE")
                        .font(.system(size: 46, weight: .black, design: .serif))
                        .tracking(7)
                        .foregroundStyle(LinearGradient(colors: [.white, gold], startPoint: .top, endPoint: .bottom))
                        .shadow(color: gold.opacity(0.8), radius: 18)
                        .overlay(Rectangle().fill(gold).frame(height: 1.5).offset(y: 34).opacity(0.7))
                    Text("SI SPENGONO LE LUCI").font(.caption2.weight(.semibold)).tracking(5).foregroundStyle(.white.opacity(0.6))
                }
                .opacity(reveal)
                .scaleEffect(0.96 + 0.04 * reveal)
                // Grain of light across the card.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Theater Mode")
            }
        }
        .ignoresSafeArea()
        .opacity(fade)
        .allowsHitTesting(false)
        .task { await play() }
    }

    private func play() async {
        guard animated else {
            reveal = 1
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.easeOut(duration: 0.25)) { fade = 0 }
            try? await Task.sleep(nanoseconds: 260_000_000)
            finished()
            return
        }
        // The projector flickers on.
        for level in [0.9, 0.2, 0.8, 0.35, 1.0] {
            withAnimation(.linear(duration: 0.07)) { beam = level }
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
        withAnimation(.easeOut(duration: 0.9)) { reveal = 1 }
        try? await Task.sleep(nanoseconds: 1_900_000_000)
        withAnimation(.easeInOut(duration: 0.8)) { fade = 0 }
        try? await Task.sleep(nanoseconds: 850_000_000)
        finished()
    }
}

/// Sprocket holes along the top and bottom of a row: the rows of Theater Mode read as strips of film.
struct FilmSprockets: View {
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 6
            while x < size.width {
                let hole = CGRect(x: x, y: 1, width: 7, height: 4)
                context.fill(Path(roundedRect: hole, cornerRadius: 1.2), with: .color(.white.opacity(0.16)))
                x += 16
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
