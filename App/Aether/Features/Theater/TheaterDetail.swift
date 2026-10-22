import SwiftUI
import AetherCore

private struct TheaterNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
private struct TheaterOpenIDKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// The namespace shared by the cards and the immersive page, so a card's picture grows into the page.
    var theaterNamespace: Namespace.ID? {
        get { self[TheaterNamespaceKey.self] }
        set { self[TheaterNamespaceKey.self] = newValue }
    }
    /// The title whose immersive page is open (its card hands the picture over to the page).
    var theaterOpenID: String? {
        get { self[TheaterOpenIDKey.self] }
        set { self[TheaterOpenIDKey.self] = newValue }
    }
}

/// The page of a title in Theater Mode: the picture of the card grows to fill the screen and the facts sit over it, on the left, with
/// the poster standing on the right. "Riproduci" continues in the normal details screen, where the sources are chosen.
struct TheaterDetail: View {
    let meta: MetaItem
    let namespace: Namespace.ID
    let close: () -> Void
    let play: (MetaItem) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: LibraryModel
    @AppStorage(TheaterPrefs.palette) private var palette = 0
    @State private var full: MetaItem?
    @State private var shown = false

    private var current: MetaItem { full ?? meta }
    private var accent: Color { TheaterPalette.color(palette) }
    private var inWatchlist: Bool { library.watchlistIDs.contains(meta.id) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Color.black
                RemoteImage(urlString: current.background ?? current.poster, width: proxy.size.width, placeholderSeed: current.name)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .matchedGeometryEffect(id: meta.id, in: namespace)
                LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 24) {
                    info.frame(maxWidth: 520, alignment: .leading)
                    Spacer(minLength: 0)
                    RemoteImage(urlString: current.poster ?? current.background, width: 130, placeholderSeed: current.name)
                        .frame(width: 130, height: 195)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .shadow(color: .black.opacity(0.7), radius: 16, y: 8)
                        .opacity(shown ? 1 : 0).offset(x: shown ? 0 : 30)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 36).padding(.trailing, 36).padding(.bottom, 26)
                .opacity(shown ? 1 : 0)
                VStack {
                    HStack {
                        Button(action: close) {
                            Image(systemName: "chevron.down").font(.body.weight(.bold)).frame(width: 40, height: 40)
                                .foregroundStyle(.white).background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Chiudi")
                        .accessibilityIdentifier("theater.detail.close")
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.leading, 20).padding(.top, 12)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .task { await load() }
        .onAppear { withAnimation(.easeOut(duration: 0.45).delay(0.2)) { shown = true } }
        .accessibilityIdentifier("theater.detail")
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RequestPlanner.friendlyTypeName(current.type).uppercased())
                .font(.caption2.weight(.bold)).tracking(4).foregroundStyle(accent)
            Text(current.name).font(.system(size: 38, weight: .bold, design: .serif)).lineLimit(2).minimumScaleFactor(0.6)
            HStack(spacing: 8) {
                if let rating = current.imdbRating, !rating.isEmpty { chip("★ \(rating)", filled: true) }
                if let year = current.releaseInfo, !year.isEmpty { chip(String(year.prefix(4))) }
                if let runtime = current.runtime, !runtime.isEmpty { chip(runtime) }
                ForEach(current.genres.prefix(3), id: \.self) { chip($0) }
            }
            if let text = current.description, !text.isEmpty {
                Text(text).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(4)
            }
            if !current.cast.isEmpty {
                Text("Con " + current.cast.prefix(4).joined(separator: ", ")).font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            HStack(spacing: 10) {
                Button { play(meta) } label: {
                    Label("Riproduci", systemImage: "play.fill").font(.subheadline.weight(.bold))
                        .padding(.horizontal, 22).frame(height: 42)
                        .background(Capsule().fill(accent)).foregroundStyle(.black)
                }
                .accessibilityIdentifier("theater.detail.play")
                Button { library.toggleWatchlist(meta) } label: {
                    Image(systemName: inWatchlist ? "checkmark" : "plus").font(.body.weight(.bold)).frame(width: 42, height: 42)
                        .background(.white.opacity(0.16), in: Circle())
                }
                .accessibilityLabel(inWatchlist ? "Rimuovi dalla watchlist" : "Aggiungi alla watchlist")
            }
            .padding(.top, 4)
        }
    }

    private func chip(_ text: String, filled: Bool = false) -> some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 4)
            .background(filled ? accent.opacity(0.9) : .white.opacity(0.14), in: Capsule())
            .foregroundStyle(filled ? Color.black : .white)
    }

    private func load() async {
        let resolution = await env.service.meta(type: meta.type, id: meta.id, fallback: meta)
        full = resolution.meta
    }
}
