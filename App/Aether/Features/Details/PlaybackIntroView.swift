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
    let ready: Bool
    let starting: Bool
    let watch: () -> Void
    let cancel: () -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @State private var logo: UIImage?
    @State private var lookupDone = false
    @State private var zoomed = false

    init(meta: MetaItem, intro: Bool, ready: Bool, starting: Bool, watch: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.meta = meta; self.intro = intro; self.ready = ready; self.starting = starting; self.watch = watch; self.cancel = cancel
        _logo = State(initialValue: FanartLogoStore.shared.cached(meta.id))
    }

    private var animates: Bool { return intro && settings.animationsEnabled }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer()
                mark
                    .scaleEffect(zoomed || !animates ? 1 : 3.2)
                    .opacity(zoomed || !animates ? 1 : 0)
                    .animation(animates ? .easeOut(duration: 2.2) : nil, value: zoomed)
                ZStack {
                    if ready && intro {
                        Button { Haptics.tap(); watch() } label: { Label("Guarda", systemImage: "play.fill").frame(minWidth: 150) }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            .accessibilityIdentifier("player.intro.watch")
                    } else {
                        ProgressView().tint(.white.opacity(0.75))
                    }
                }
                .frame(height: 56)
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
            if ready && !intro { watch() }
        }
        .onChange(of: ready) { _, isReady in
            // Without the screen of the kind the film starts by itself the moment it is ready.
            if isReady && !intro { watch() }
        }
        .task { await loadLogo() }
    }

    @ViewBuilder
    private var mark: some View {
        if let logo = logo {
            Image(uiImage: logo).resizable().scaledToFit().frame(maxWidth: 440, maxHeight: 200).accessibilityLabel(meta.name)
        } else if lookupDone {
            Text(meta.name).font(.system(size: 38, weight: .heavy, design: .serif)).foregroundStyle(.white)
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
