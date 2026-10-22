import SwiftUI

/// The opening of Theater Mode: a projector lights a wide beam full of dust, the name appears in it, a low hit bursts into sparkles
/// and the lights go up on the stage. Everything is drawn from the elapsed time, so it stays in step with the sound. With reduced
/// motion (or animations off) it is a short still card.
struct TheaterIntro: View {
    let animated: Bool
    let sound: Bool
    let accent: Color
    let finished: () -> Void
    @State private var start = Date()
    @State private var done = false

    private let total = 3.7
    private let hit = 2.4

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color.black
                if animated {
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSince(start)
                        ZStack {
                            Canvas { context, canvasSize in draw(&context, canvasSize, t) }
                            title(size: size, t: t)
                        }
                        .opacity(t > 3.0 ? max(0, 1 - (t - 3.0) / (total - 3.0)) : 1)
                        .task(id: t > total) { if t > total { complete() } }
                    }
                } else {
                    title(size: size, t: 2.5).task { try? await Task.sleep(nanoseconds: 600_000_000); complete() }
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

    private func title(size: CGSize, t: Double) -> some View {
        let reveal = animated ? min(1, max(0, (t - 0.6) / 1.1)) : 1
        return VStack(spacing: 6) {
            Text("THEATER MODE")
                .font(.system(size: min(size.width * 0.12, 110), weight: .black, design: .serif))
                .tracking(8)
                .lineLimit(1).minimumScaleFactor(0.4)
                .foregroundStyle(LinearGradient(colors: [.white, accent], startPoint: .top, endPoint: .bottom))
                .shadow(color: accent.opacity(0.9), radius: 24)
            Text("SI SPENGONO LE LUCI").font(.callout.weight(.semibold)).tracking(8).foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 24)
        .opacity(reveal)
        .scaleEffect(0.94 + 0.06 * reveal)
        .mask(Rectangle().frame(width: max(1, size.width * (0.15 + 0.85 * reveal))).frame(maxWidth: .infinity, alignment: .leading))
    }

    // MARK: Drawing

    private func rand(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return x - floor(x)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        // The projector flickers on, then holds.
        var flicker = 1.0
        if t < 0.55 { flicker = [0.9, 0.15, 0.8, 0.25, 0.95, 0.5, 1.0][min(6, Int(t / 0.08))] }
        let ramp = min(1, t / 0.6)
        let source = CGPoint(x: w * 0.08, y: -6)

        // Two small spotlights sweeping from the top corners.
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

        // The main beam: wide, bright at the source, fading towards the far end.
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
        // The projector lens.
        context.fill(Path(ellipseIn: CGRect(x: source.x - 26, y: -34, width: 70, height: 56)), with: .color(.white.opacity(0.9 * flicker * ramp)))

        // Dust in the light.
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

        // The hit: a flash and sparkles around the name.
        if t >= hit {
            let k = t - hit
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(max(0, 0.55 - k * 1.6))))
            for i in 0..<22 {
                let angle = rand(i, 7) * .pi * 2
                let distance = (0.1 + rand(i, 8) * 0.42) * w * min(1, k * 1.8)
                let centre = CGPoint(x: w / 2 + cos(angle) * distance, y: h / 2 + sin(angle) * distance * 0.55)
                let life = max(0, 1 - k / (0.9 + rand(i, 9) * 0.5))
                let r = (5 + rand(i, 10) * 14) * life
                var star = Path()
                star.move(to: CGPoint(x: centre.x, y: centre.y - r)); star.addLine(to: CGPoint(x: centre.x + r * 0.22, y: centre.y - r * 0.22))
                star.addLine(to: CGPoint(x: centre.x + r, y: centre.y)); star.addLine(to: CGPoint(x: centre.x + r * 0.22, y: centre.y + r * 0.22))
                star.addLine(to: CGPoint(x: centre.x, y: centre.y + r)); star.addLine(to: CGPoint(x: centre.x - r * 0.22, y: centre.y + r * 0.22))
                star.addLine(to: CGPoint(x: centre.x - r, y: centre.y)); star.addLine(to: CGPoint(x: centre.x - r * 0.22, y: centre.y - r * 0.22))
                star.closeSubpath()
                context.fill(star, with: .color((i % 3 == 0 ? accent : .white).opacity(life)))
            }
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
