import SwiftUI

/// The opening of Theater Mode: a projector lights a wide beam full of dust, the name lights up letter by letter in it, a deep hit
/// shakes the light, then the beam floods the whole screen and fades onto the stage. Everything is drawn from the elapsed time, so it
/// stays in step with the sound. With reduced motion (or animations off) it is a short still card.
struct TheaterIntro: View {
    let animated: Bool
    let sound: Bool
    let accent: Color
    let finished: () -> Void
    @State private var start = Date()
    @State private var done = false

    private let total = 6.0
    private let hit = 3.4
    /// The halves part and the light widens to the whole screen from here, then the light fades.
    private let openStart = 4.3
    private let floodEnd = 5.1

    private let order = [3, 9, 0, 6, 11, 2, 8, 5, 10, 1, 7, 4]
    private let letters = Array("THEATER MODE")

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if animated {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSince(start)
                        let open = min(1, max(0, (t - openStart) / (floodEnd - openStart)))
                        let eased = open * open * (3 - 2 * open)
                        let fade = min(1, max(0, (t - floodEnd) / (total - floodEnd)))
                        ZStack {
                            HStack(spacing: 0) {
                                Color.black.offset(x: -size.width / 2 * eased)
                                Color.black.offset(x: size.width / 2 * eased)
                            }
                            Canvas { context, canvasSize in draw(&context, canvasSize, t) }
                                .opacity(1 - min(1, open * 1.4))
                            title(size: size, t: t).opacity(1 - min(1, open * 1.8))
                            // The light of the opening: a thin line that widens to fill the screen.
                            Rectangle()
                                .fill(LinearGradient(colors: [accent.opacity(0.85), .white, accent.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                                .frame(width: max(0, 4 + size.width * 1.05 * eased), height: size.height)
                                .blur(radius: 4 + 26 * eased)
                                .opacity(open > 0 ? 1 : 0)
                        }
                        .opacity(1 - fade)
                        .task(id: t > total) { if t > total { complete() } }
                    }
                } else {
                    ZStack { Color.black; title(size: size, t: 9) }
                        .task { try? await Task.sleep(nanoseconds: 700_000_000); complete() }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { start = Date(); if animated && sound { TheaterSound.playIntro() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Theater Mode")
    }

    private func complete() {
        guard !done else { return }
        done = true
        finished()
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    /// The name, lit one letter at a time in a scattered order (each letter blooms out of a blur), under a line that grows from the middle.
    private func title(size: CGSize, t: Double) -> some View {
        let fontSize = min(size.width * 0.1, 96)
        let lineGrow = animated ? clamp((t - 1.9) / 0.9) : 1
        let tagline = animated ? clamp((t - 2.5) / 0.7) : 1
        return VStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(0..<letters.count, id: \.self) { i in
                    let appear = animated ? clamp((t - 0.7 - Double(order[i]) * 0.1) / 0.5) : 1
                    Text(String(letters[i]))
                        .font(.system(size: fontSize, weight: .black, design: .serif))
                        .foregroundStyle(LinearGradient(colors: [.white, accent], startPoint: .top, endPoint: .bottom))
                        .shadow(color: accent.opacity(0.9 * appear), radius: 22)
                        .opacity(appear)
                        .scaleEffect(1.45 - 0.45 * appear)
                        .blur(radius: (1 - appear) * 12)
                        .frame(width: letters[i] == " " ? fontSize * 0.45 : nil)
                }
            }
            .lineLimit(1)
            Rectangle().fill(LinearGradient(colors: [.clear, accent, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: size.width * 0.62 * lineGrow, height: 1.5)
            Text("SI SPENGONO LE LUCI")
                .font(.callout.weight(.semibold)).tracking(9)
                .foregroundStyle(.white.opacity(0.7 * tagline))
                .offset(y: (1 - tagline) * 8)
        }
        .padding(.horizontal, 24)
    }

    // MARK: Drawing

    private func rand(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return x - floor(x)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        var flicker = 1.0
        if t < 0.55 { flicker = [0.9, 0.15, 0.8, 0.25, 0.95, 0.5, 1.0][min(6, Int(t / 0.08))] }
        let ramp = min(1, t / 0.6)
        let source = CGPoint(x: w * 0.08, y: -6)

        for (index, origin) in [CGPoint(x: w * 0.92, y: -6), CGPoint(x: w * 0.55, y: -6)].enumerated() {
            let sweep = sin(t * 0.9 + Double(index) * 2) * 0.12
            var path = Path()
            path.move(to: origin)
            path.addLine(to: CGPoint(x: origin.x - w * (0.22 + sweep), y: h))
            path.addLine(to: CGPoint(x: origin.x - w * (0.05 + sweep), y: h))
            path.closeSubpath()
            var layer = context
            layer.addFilter(.blur(radius: 18))
            layer.fill(path, with: .color(accent.opacity(0.14 * ramp)))
        }

        var beam = Path()
        beam.move(to: source)
        beam.addLine(to: CGPoint(x: w * 0.02, y: h * 1.02))
        beam.addLine(to: CGPoint(x: w * 1.02, y: h * 1.02))
        beam.addLine(to: CGPoint(x: w * 0.18, y: -6))
        beam.closeSubpath()
        var glow = context
        glow.addFilter(.blur(radius: 22))
        glow.blendMode = .plusLighter
        glow.fill(beam, with: .linearGradient(Gradient(colors: [.white.opacity(0.5 * flicker * ramp), accent.opacity(0.22 * ramp), .clear]),
                                              startPoint: source, endPoint: CGPoint(x: w * 0.6, y: h)))
        context.fill(Path(ellipseIn: CGRect(x: source.x - 26, y: -34, width: 70, height: 56)), with: .color(.white.opacity(0.9 * flicker * ramp)))

        let direction = CGPoint(x: w * 0.6 - source.x, y: h - source.y)
        let length = (direction.x * direction.x + direction.y * direction.y).squareRoot()
        let unit = CGPoint(x: direction.x / length, y: direction.y / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        for i in 0..<90 {
            let speed = 0.015 + rand(i, 1) * 0.04
            let u = (rand(i, 2) + t * speed).truncatingRemainder(dividingBy: 1)
            let across = (rand(i, 3) * 2 - 1) * (0.1 + 0.62 * u)
            let drift = sin(t * (0.6 + rand(i, 4)) + Double(i)) * 8
            let d = u * length * 1.15
            let x = source.x + unit.x * d + normal.x * across * w * 0.5 + drift
            let y = source.y + unit.y * d + normal.y * across * w * 0.5 + drift * 0.5
            let twinkle = 0.35 + 0.65 * abs(sin(t * (1.4 + rand(i, 5) * 2) + Double(i)))
            let radius = 0.8 + rand(i, 6) * 2.2
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                         with: .color(.white.opacity(0.7 * twinkle * flicker * ramp * (1 - u * 0.5))))
        }

        // The hit: a soft flash and a ring of light spreading out from the middle (no sparkles).
        if t >= hit {
            let k = t - hit
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(max(0, 0.4 - k * 1.2))))
            let radius = k * w * 0.55
            var ring = context
            ring.addFilter(.blur(radius: 6))
            ring.stroke(Path(ellipseIn: CGRect(x: w / 2 - radius, y: h / 2 - radius * 0.6, width: radius * 2, height: radius * 1.2)),
                        with: .color(accent.opacity(max(0, 0.7 - k * 0.8))), lineWidth: 3)
        }
    }
}

/// Sprocket holes along the top and bottom of a row: the rows can read as strips of film.
struct FilmSprockets: View {
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 6
            while x < size.width {
                context.fill(Path(roundedRect: CGRect(x: x, y: 1, width: 7, height: 4), cornerRadius: 1.2), with: .color(.white.opacity(0.16)))
                x += 16
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
