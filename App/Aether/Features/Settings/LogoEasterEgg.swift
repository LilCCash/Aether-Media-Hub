import SwiftUI
import UIKit
import AetherCore

/// State of the logo in About: the heat of the kernel, the pop animation, the banner. Taps arrive from `AboutLogoView`.
@MainActor
final class LogoEasterEggModel: ObservableObject {
    struct Rain: Equatable {
        var id: Int
        var start: Date
        var origin: CGPoint
        var shower: PopcornShower

        static func == (lhs: Rain, rhs: Rain) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var heat = 0
    /// Rises with every pop; the logo turns a full circle for each.
    @Published private(set) var flips = 0
    @Published private(set) var wobble = false
    @Published private(set) var rain: Rain?
    @Published private(set) var banner: String?

    /// Where the logo is, in the coordinate space of the overlay (set by the view).
    var logoCenter: CGPoint = CGPoint(x: 200, y: 160)

    private var tracker = LogoTapTracker()
    private var coolTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var rainTask: Task<Void, Never>?
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()

    /// - Parameters:
    ///   - moving: animations are allowed (the switch is on and Reduce Motion is off).
    func tap(settings: SettingsStore, moving: Bool) {
        let voiceOver = UIAccessibility.isVoiceOverRunning
        let window = voiceOver ? LogoTapTracker.voiceOverWindow : LogoTapTracker.resetWindow
        let outcome = tracker.register(at: ProcessInfo.processInfo.systemUptime, window: window)
        switch outcome {
        case .ignored:
            return
        case .heat(let level):
            heat = level
            wobble.toggle()
            tick(level: level)
            if let text = LogoEasterEggText.heat(level: level) { show(text, for: 1.6, voiceOver: voiceOver) }
            scheduleCooldown(window: window)
        case .pop(let count):
            coolTask?.cancel()
            heat = 0
            flips += 1
            notification.notificationOccurred(.success)
            rigid.impactOccurred(intensity: 1)
            var appearance = settings.value.appearance
            let firstTime = appearance.unlock(.popcorn)
            if firstTime { settings.value.appearance = appearance }
            show(LogoEasterEggText.pop(count: count, unlockedNow: firstTime), for: firstTime ? 5 : 3.5, voiceOver: voiceOver)
            if moving { startRain(popCount: count) }
        }
    }

    /// The logo is left (or covered by another screen): stop everything and put the visible state back, so a banner or a heated
    /// logo is not still there when the viewer returns.
    func stop() {
        coolTask?.cancel()
        bannerTask?.cancel()
        rainTask?.cancel()
        rain = nil
        banner = nil
        heat = 0
        wobble = false
        tracker.cooldownElapsed()
    }

    // MARK: Pieces

    private func tick(level: Int) {
        let intensity = CGFloat(LogoHaptics.intensity(forHeat: level))
        switch level {
        case 1, 2: light.impactOccurred(intensity: intensity)
        case 3, 4: medium.impactOccurred(intensity: intensity)
        default: rigid.impactOccurred(intensity: intensity)
        }
    }

    private func scheduleCooldown(window: TimeInterval) {
        coolTask?.cancel()
        coolTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            self.tracker.cooldownElapsed()
            self.heat = 0
        }
    }

    private func show(_ text: String, for seconds: Double, voiceOver: Bool) {
        banner = text
        if voiceOver { UIAccessibility.post(notification: .announcement, argument: text) }
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    private func startRain(popCount: Int) {
        let count = ProcessInfo.processInfo.isLowPowerModeEnabled ? 14 : 36
        let run = Rain(id: popCount,
                       start: Date(),
                       origin: logoCenter,
                       shower: PopcornShower(seed: UInt64(popCount) &* 7919 &+ 17, count: count))
        rain = run
        rainTask?.cancel()
        rainTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((PopcornShower.duration + 0.2) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.rain = nil
        }
    }
}

/// The logo in About. Each tap heats it up; the seventh makes it pop.
struct AboutLogoView: View {
    @ObservedObject var model: LogoEasterEggModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var moving: Bool { settings.animationsEnabled && !reduceMotion }

    var body: some View {
        Button {
            model.tap(settings: settings, moving: moving)
        } label: {
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .scaleEffect(moving ? 1 + 0.05 * Double(model.heat) : 1)
                .rotationEffect(.degrees(moving ? Double(model.heat) * (model.wobble ? 1.5 : -1.5) : 0))
                .shadow(color: .orange.opacity(moving && !settings.reduceEffects ? 0.12 * Double(model.heat) : 0),
                        radius: CGFloat(4 + 3 * model.heat))
                .rotation3DEffect(.degrees(moving ? 360 * Double(model.flips) : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .animation(moving ? .spring(response: 0.7, dampingFraction: 0.6) : nil, value: model.flips)
                .animation(moving ? .spring(response: 0.25, dampingFraction: 0.5) : nil, value: model.heat)
                .padding(8)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: LogoFrameKey.self, value: proxy.frame(in: .named(AboutLogoView.space)))
                })
        }
        .buttonStyle(LogoPressStyle(moving: moving))
        .onPreferenceChange(LogoFrameKey.self) { frame in
            model.logoCenter = CGPoint(x: frame.midX, y: frame.midY)
        }
        .accessibilityLabel("Logo di Aether")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("about.logo")
    }

    static let space = "aboutScreen"
}

private struct LogoFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Squashes the logo while it is pressed, like a kernel under a thumb.
private struct LogoPressStyle: ButtonStyle {
    let moving: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(x: moving && configuration.isPressed ? 1.08 : 1, y: moving && configuration.isPressed ? 0.9 : 1, anchor: .bottom)
            .animation(moving ? .spring(response: 0.2, dampingFraction: 0.5) : nil, value: configuration.isPressed)
    }
}

/// The rain of popcorn and the banner, drawn over the whole About screen. Not hit-testable and hidden from VoiceOver (the
/// banner text is announced instead).
struct LogoEasterEggOverlay: View {
    @ObservedObject var model: LogoEasterEggModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var moving: Bool { settings.animationsEnabled && !reduceMotion }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let rain = model.rain {
                PopcornRainView(rain: rain)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if let banner = model.banner {
                Text(banner)
                    .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .aetherGlassCard(cornerRadius: 20)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(moving ? .move(edge: .bottom).combined(with: .opacity) : .identity)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("about.egg.message")
            }
        }
        .animation(moving ? .easeOut(duration: 0.25) : nil, value: model.banner)
    }
}

private struct PopcornRainView: View {
    let rain: LogoEasterEggModel.Rain
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: scenePhase != .active)) { timeline in
            let t = timeline.date.timeIntervalSince(rain.start)
            Canvas(rendersAsynchronously: true) { context, size in
                for piece in rain.shower.pieces {
                    guard let point = rain.shower.position(of: piece, at: t, origin: rain.origin, in: size),
                          let symbol = context.resolveSymbol(id: piece.glyph) else { continue }
                    var layer = context
                    layer.translateBy(x: point.x, y: point.y)
                    layer.rotate(by: .radians(piece.spin * (t - piece.delay)))
                    layer.scaleBy(x: piece.scale, y: piece.scale)
                    layer.draw(symbol, at: .zero)
                }
            } symbols: {
                ForEach(Array(PopcornShower.glyphs.enumerated()), id: \.offset) { index, glyph in
                    Text(glyph).font(.system(size: PopcornShower.baseGlyphSize)).tag(index)
                }
            }
        }
        .ignoresSafeArea()
    }
}
