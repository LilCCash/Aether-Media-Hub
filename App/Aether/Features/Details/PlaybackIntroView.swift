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
    /// The logo flew here from the list of sources: it is already at its place, so it does not zoom in again.
    var arrived = false
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @State private var logo: UIImage?
    @State private var lookupDone = false
    @State private var zoomed = false

    init(meta: MetaItem, intro: Bool, resolution: DebridRowResolution?, ready: Bool, starting: Bool, arrived: Bool = false,
         watch: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.meta = meta; self.intro = intro; self.resolution = resolution; self.ready = ready; self.starting = starting; self.watch = watch; self.cancel = cancel
        self.arrived = arrived
        _logo = State(initialValue: FanartLogoStore.shared.cached(meta.id))
    }

    private var animates: Bool { return intro && settings.animationsEnabled }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if scene {
                // The scene of the film: its backdrop, dimmed, under everything.
                RemoteImage(urlString: meta.background ?? meta.poster, width: 1400, placeholderSeed: meta.name)
                    .ignoresSafeArea().opacity(0.4).blur(radius: 4)
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            }
            // The phone is sideways here (about 390 points tall): with the scene the logo and the gaps are smaller, so logo, plot,
            // «Guarda» and «Annulla» all fit without being cut.
            VStack(spacing: scene ? 14 : 26) {
                Spacer(minLength: 8)
                mark
                    .scaleEffect(zoomed || !animates || arrived ? 1 : 3.2)
                    .opacity(zoomed || !animates || arrived ? 1 : 0)
                    .animation(animates && !arrived ? .easeOut(duration: 2.2) : nil, value: zoomed)
                if scene { info }
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
                Spacer(minLength: 8)
                if !starting {
                    Button("Annulla", action: cancel)
                        .buttonStyle(.bordered).tint(.white).padding(.bottom, scene ? 12 : 26)
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

    /// The rich page (backdrop, year, genres, plot) is for «Apertura cinematografica» and «Modalità Cinema».
    private var scene: Bool { return intro && (settings.value.appearance.cinematicOpening || settings.value.playback.cinemaMode) }

    /// Year, length and genres on one line, then the plot: what the viewer is about to watch.
    private var info: some View {
        VStack(spacing: 10) {
            let facts = [meta.releaseInfo, meta.runtime, meta.genres.prefix(3).joined(separator: " · ")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ·   ")
            if !facts.isEmpty {
                Text(facts).font(.footnote.weight(.semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.75))
            }
            if let plot = meta.description, !plot.isEmpty {
                Text(plot).font(.callout).foregroundStyle(.white.opacity(0.82)).multilineTextAlignment(.center)
                    .lineLimit(3).frame(maxWidth: 600)
            }
        }
        .opacity(zoomed || !animates ? 1 : 0)
        .animation(animates ? .easeOut(duration: 1.6).delay(0.8) : nil, value: zoomed)
    }

    @ViewBuilder
    private var mark: some View {
        if let logo = logo {
            Image(uiImage: logo).resizable().scaledToFit()
                .frame(maxWidth: scene ? 360 : 440, maxHeight: scene ? 110 : 200)
                .shadow(color: .black.opacity(0.6), radius: 12)
                .accessibilityLabel(meta.name)
        } else if lookupDone {
            Text(meta.name).font(.system(size: scene ? 32 : 38, weight: .heavy, design: .serif)).foregroundStyle(.white)
                .multilineTextAlignment(.center).lineLimit(scene ? 2 : 3)
                .shadow(color: .black.opacity(0.6), radius: 10)
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
