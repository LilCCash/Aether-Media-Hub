import SwiftUI
import AetherCore

/// The full-screen page shown at once when a TorBox source is chosen, while TorBox is contacted and the link is prepared:
/// the film's logo from fanart.tv when the viewer has a key, else just its title, and what is going on.
struct PlaybackPreparingView: View {
    let meta: MetaItem
    let resolution: DebridRowResolution?
    let cancel: () -> Void
    @EnvironmentObject private var env: AppEnvironment
    @State private var logoURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                if let logoURL = logoURL {
                    AsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            titleText
                        }
                    }
                    .frame(maxWidth: 320, maxHeight: 140)
                } else {
                    titleText
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
        .task { await loadLogo() }
    }

    private var titleText: some View {
        Text(meta.name)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
    }

    /// Films are looked up by IMDb (or TMDB) code, series by their TheTVDB code. Without a fanart.tv key nothing is asked.
    private func loadLogo() async {
        guard env.fanart.isConfigured else { return }
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        let ids = meta.externalIDs
        var found: URL?
        if meta.type == "series" {
            if let tvdb = ids.tvdb {
                found = await env.fanart.logoURL(kind: .tv, id: String(tvdb), language: language)
            }
        } else {
            let imdb = ids.imdb ?? (meta.id.hasPrefix("tt") ? meta.id : nil)
            if let imdb = imdb {
                found = await env.fanart.logoURL(kind: .movie, id: imdb, language: language)
            }
            if found == nil, let tmdb = ids.tmdb {
                found = await env.fanart.logoURL(kind: .movie, id: String(tmdb), language: language)
            }
        }
        logoURL = found
    }
}
