import SwiftUI
import AetherCore

/// The full-screen page shown at once when a TorBox source is chosen, while TorBox is contacted and the link is prepared:
/// the film's logo from fanart.tv when the viewer has a key, else just its title, and what is going on.
struct PlaybackPreparingView: View {
    let meta: MetaItem
    let resolution: DebridRowResolution?
    let cancel: () -> Void
    @EnvironmentObject private var env: AppEnvironment
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
            VStack(spacing: 22) {
                Spacer()
                if let logo = logo {
                    Image(uiImage: logo)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 420, maxHeight: 190)
                        .accessibilityLabel(meta.name)
                } else if lookupDone || !env.fanart.isConfigured {
                    titleText
                } else {
                    Color.clear.frame(height: 60)
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
                    .buttonStyle(.bordered)
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
        guard logo == nil, env.fanart.isConfigured, !FanartLogoStore.shared.isKnownMissing(meta.id) else { lookupDone = true; return }
        logo = await FanartLogoStore.shared.load(meta: meta, env: env)
        lookupDone = true
    }
}
