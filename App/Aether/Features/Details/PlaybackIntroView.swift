import SwiftUI
import AetherCore

extension PlaybackSettings {
    /// Whether the start screen (logo, «Guarda») is on for this kind of title.
    func introEnabled(forType type: String) -> Bool {
        switch type {
        case "tv": return introLive
        case "movie": return introMovies
        default: return introSeries
        }
    }
}

/// The black start screen of a playback: the title's logo zooms out from huge to its size at the centre while the app prepares the source;
/// when everything is ready a «Guarda» button appears under it and starts the film. Without the intro the logo just sits there.
struct PlaybackIntroView: View {
    let meta: MetaItem
    let intro: Bool
    /// What the source is doing right now (TorBox steps, percent): shown here, under the logo, not under the row of the list.
    let resolution: DebridRowResolution?
    let ready: Bool
    let starting: Bool
    let watch: () -> Void
    let cancel: () -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @State private var logo: UIImage?
    @State private var lookupDone = false
    @State private var zoomed = false

    init(meta: MetaItem, intro: Bool, resolution: DebridRowResolution?, ready: Bool, starting: Bool, watch: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.meta = meta; self.intro = intro; self.resolution = resolution; self.ready = ready; self.starting = starting; self.watch = watch; self.cancel = cancel
        _logo = State(initialValue: FanartLogoStore.shared.cached(meta.id))
    }

    private var animates: Bool { return intro && settings.animationsEnabled }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cinematic && intro {
                // «Apertura cinematografica»: the scene of the opening (a glow and two lines of light) around the title.
                RadialGradient(colors: [settings.accentColor.opacity(0.4), .clear], center: .center, startRadius: 10, endRadius: 380)
                    .opacity(zoomed || !animates ? 1 : 0).ignoresSafeArea()
                    .animation(animates ? .easeOut(duration: 1.8) : nil, value: zoomed)
            }
            VStack(spacing: 26) {
                Spacer()
                if cinematic && intro { line }
                mark
                    .scaleEffect(zoomed || !animates ? 1 : 3.2)
                    .opacity(zoomed || !animates ? 1 : 0)
                    .animation(animates ? .easeOut(duration: 2.2) : nil, value: zoomed)
                if cinematic && intro { line }
                ZStack {
                    if ready && intro {
                        Button { Haptics.tap(); OpeningSound.shared.stop(); watch() } label: { Label("Guarda", systemImage: "play.fill").frame(minWidth: 150) }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            .accessibilityIdentifier("player.intro.watch")
                    } else {
                        VStack(spacing: 8) {
                            ProgressView().tint(.white.opacity(0.75))
                            if let resolution = resolution {
                                Text(resolution.message).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                                if let detail = resolution.detail {
                                    Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                                }
                            }
                        }
                        .multilineTextAlignment(.center)
                    }
                }
                .frame(minHeight: 56)
                .animation(.easeOut(duration: 0.35), value: ready)
                Spacer()
                if !starting {
                    Button("Annulla", action: cancel)
                        .buttonStyle(.bordered).tint(.white).padding(.bottom, 26)
                        .accessibilityIdentifier("stream.debrid.cancel")
                }
            }
            .padding(.horizontal, 28)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            OrientationController.set(.landscape)
            zoomed = true
            // The riser goes with the logo coming out of the dark, and only there.
            if intro && settings.value.appearance.openingSound { OpeningSound.shared.play() }
            if ready && !intro { watch() }
        }
        .onChange(of: ready) { _, isReady in
            // Without the screen of the kind the film starts by itself the moment it is ready.
            if isReady && !intro { watch() }
        }
        .onDisappear { OpeningSound.shared.stop() }
        .task { await loadLogo() }
    }

    private var cinematic: Bool { return settings.value.appearance.cinematicOpening }

    private var line: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, settings.accentColor, .clear], startPoint: .leading, endPoint: .trailing))
            .frame(width: zoomed || !animates ? 340 : 0, height: 2)
            .animation(animates ? .easeOut(duration: 1.6) : nil, value: zoomed)
    }

    @ViewBuilder
    private var mark: some View {
        if let logo = logo {
            Image(uiImage: logo).resizable().scaledToFit().frame(maxWidth: 440, maxHeight: 200).accessibilityLabel(meta.name)
        } else if lookupDone {
            Text(cinematic && intro ? meta.name.uppercased() : meta.name).font(.system(size: 38, weight: .heavy, design: .serif)).foregroundStyle(.white)
                .multilineTextAlignment(.center).lineLimit(3)
        } else {
            Color.clear.frame(height: 80)
        }
    }

    private func loadLogo() async {
        guard logo == nil, !FanartLogoStore.shared.isKnownMissing(meta.id) else { lookupDone = true; return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            lookupDone = true
        }
        logo = await FanartLogoStore.shared.load(meta: meta, env: env)
        lookupDone = true
    }
}
