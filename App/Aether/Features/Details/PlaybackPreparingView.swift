import SwiftUI
import AetherCore

/// The full-screen page shown at once when a TorBox source is chosen, while TorBox is contacted and the link is prepared:
/// the film's logo from fanart.tv when the viewer has a key, else just its title, and what is going on.
struct PlaybackPreparingView: View {
    let meta: MetaItem
    let resolution: DebridRowResolution?
    let cancel: () -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @State private var logo: UIImage?
    @State private var lookupDone = false

    init(meta: MetaItem, resolution: DebridRowResolution?, cancel: @escaping () -> Void) {
        self.meta = meta
        self.resolution = resolution
        self.cancel = cancel
        // A logo fetched ahead of time is on screen from the very first frame.
        _logo = State(initialValue: FanartLogoStore.shared.cached(meta.id))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if settings.value.playback.cinemaMode {
                RemoteImage(urlString: meta.background ?? meta.poster, width: 1200, placeholderSeed: meta.name)
                    .ignoresSafeArea().opacity(0.35).blur(radius: 6)
                LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            }
            VStack(spacing: 22) {
                Spacer()
                if let logo = logo {
                    Image(uiImage: logo)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 420, maxHeight: 190)
                        .accessibilityLabel(meta.name)
                } else if lookupDone {
                    titleText
                } else {
                    Color.clear.frame(height: 60)
                }
                if settings.value.playback.cinemaMode {
                    Text([meta.releaseInfo, meta.genres.prefix(3).joined(separator: " · ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ·   "))
                        .font(.footnote.weight(.semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.7))
                }
                VStack(spacing: 14) {
                    if let fraction = resolution?.determinateFraction {
                        ProgressView(value: fraction)
                            .tint(.white)
                            .frame(maxWidth: 260)
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(resolution?.message ?? "Preparo la riproduzione…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    if let detail = resolution?.detail {
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stream.debrid.progress")
                Spacer()
                Button("Annulla", action: cancel)
                    .buttonStyle(.aetherSecondary)
                    .tint(.white)
                    .padding(.bottom, 30)
                    .accessibilityLabel("Annulla l'attesa di TorBox")
                    .accessibilityIdentifier("stream.debrid.cancel")
            }
            .padding(.horizontal, 28)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Match the player orientation from the very first loading frame; do not wait for PlayerView.
            OrientationController.set(.landscape)
        }
        .task { await loadLogo() }
    }

    private var titleText: some View {
        Text(meta.name)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
    }

    private func loadLogo() async {
        guard logo == nil, !FanartLogoStore.shared.isKnownMissing(meta.id) else { lookupDone = true; return }
        // The title shows if the logo is slow; the logo takes its place when it arrives.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            lookupDone = true
        }
        logo = await FanartLogoStore.shared.load(meta: meta, env: env)
        lookupDone = true
    }
}
