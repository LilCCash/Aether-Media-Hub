import SwiftUI
import AetherCore

/// The page of a title in Theater Mode: the backdrop fills the screen and the facts sit over it, on the left, with the poster standing
/// on the right. For a series the seasons and the episodes run along the bottom. Playing continues in the source choice of this mode.
struct TheaterDetail: View {
    let meta: MetaItem
    let close: () -> Void
    let pick: (MetaItem, Video?) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: LibraryModel
    @AppStorage(TheaterPrefs.palette) private var palette = 0
    @AppStorage(TheaterPrefs.corners) private var corners = 1
    @StateObject private var model: DetailViewModel
    @State private var shown = false

    init(meta: MetaItem, close: @escaping () -> Void, pick: @escaping (MetaItem, Video?) -> Void) {
        self.meta = meta
        self.close = close
        self.pick = pick
        _model = StateObject(wrappedValue: DetailViewModel(route: MetaRoute(meta: meta)))
    }

    private var current: MetaItem { model.meta }
    private var accent: Color { TheaterPalette.color(palette) }
    private var radius: CGFloat { [4, 10, 16][min(max(corners, 0), 2)] }
    private var inWatchlist: Bool { library.watchlistIDs.contains(meta.id) }

    var body: some View {
        ZStack {
            backdrop
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(action: close) {
                        Image(systemName: "chevron.down").font(.body.weight(.bold)).frame(width: 40, height: 40)
                            .foregroundStyle(.white).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Chiudi")
                    .accessibilityIdentifier("theater.detail.close")
                    Spacer()
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 24) {
                    info.frame(maxWidth: 540, alignment: .leading)
                    Spacer(minLength: 0)
                    if !model.isSeries {
                        RemoteImage(urlString: current.poster ?? current.background, width: 260, placeholderSeed: current.name)
                            .frame(width: 130, height: 195)
                            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                            .shadow(color: .black.opacity(0.7), radius: 16, y: 8)
                            .accessibilityHidden(true)
                    }
                }
                if model.isSeries { episodes }
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 14)
        }
        .foregroundStyle(.white)
        .task { await model.load(env: env) }
        .onAppear { withAnimation(.easeOut(duration: 0.35).delay(0.08)) { shown = true } }
    }

    private var backdrop: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                RemoteImage(urlString: current.background ?? current.poster, width: 700, placeholderSeed: current.name)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(RequestPlanner.friendlyTypeName(current.type).uppercased())
                .font(.caption2.weight(.bold)).tracking(4).foregroundStyle(accent)
            Text(current.name).font(.system(size: 36, weight: .bold, design: .serif)).lineLimit(2).minimumScaleFactor(0.6)
                .accessibilityIdentifier("theater.detail.title")
            HStack(spacing: 8) {
                if let rating = current.imdbRating, !rating.isEmpty { chip("★ \(rating)", filled: true) }
                if let year = current.releaseInfo, !year.isEmpty { chip(String(year.prefix(4))) }
                if let runtime = current.runtime, !runtime.isEmpty { chip(runtime) }
                ForEach(current.genres.prefix(3), id: \.self) { chip($0) }
            }
            let shown = env.settings.value.content.ratings
            let scores = model.ratings.filter { shown.sources.contains($0.source) }.compactMap { rating in rating.display.map { "\(rating.title) \($0)" } }
            if !scores.isEmpty {
                HStack(spacing: 8) { ForEach(scores, id: \.self) { chip($0) } }
            }
            if let saga = model.rich?.collection, model.sagaFilms.count > 1 {
                Text("Saga: \(saga.name) · \(model.sagaFilms.count) film").font(.footnote.weight(.semibold)).foregroundStyle(accent)
            }
            if let text = current.description, !text.isEmpty {
                Text(text).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(model.isSeries ? 2 : 4)
            }
            if !model.isSeries, !current.cast.isEmpty {
                Text("Con " + current.cast.prefix(4).joined(separator: ", ")).font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            HStack(spacing: 10) {
                Button { pick(current, model.primaryVideo()) } label: {
                    Label(playTitle, systemImage: "play.fill").font(.subheadline.weight(.bold))
                        .padding(.horizontal, 22).frame(height: 42)
                        .background(Capsule().fill(accent)).foregroundStyle(.black)
                }
                .disabled(model.isSeries && model.visibleEpisodes.isEmpty)
                .accessibilityIdentifier("theater.detail.play")
                Button { library.toggleWatchlist(current) } label: {
                    Image(systemName: inWatchlist ? "checkmark" : "plus").font(.body.weight(.bold)).frame(width: 42, height: 42)
                        .background(.white.opacity(0.16), in: Circle())
                }
                .accessibilityLabel(inWatchlist ? "Rimuovi dalla watchlist" : "Aggiungi alla watchlist")
            }
            .padding(.top, 2)
        }
    }

    private var playTitle: String {
        let title = model.primaryButtonTitle()
        return model.isSeries ? title : (title == "Guarda" ? "Riproduci" : title)
    }

    // MARK: Episodes

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.meta.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.meta.seasons, id: \.self) { season in
                            let selected = model.selectedSeason == season
                            Button { model.selectedSeason = season } label: {
                                Text(season == 0 ? "Speciali" : "Stagione \(season)").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(selected ? accent : Color.white.opacity(0.14), in: Capsule())
                                    .foregroundStyle(selected ? Color.black : .white)
                            }
                        }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(model.visibleEpisodes) { video in
                        episodeCard(video)
                    }
                }
            }
        }
    }

    private func episodeCard(_ video: Video) -> some View {
        let future = (video.released ?? .distantPast) > Date()
        let progress = model.progress[video.id]
        return Button { pick(current, video) } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .bottom) {
                    RemoteImage(urlString: video.thumbnail ?? current.background, width: 320, placeholderSeed: video.id, systemPlaceholder: "play.rectangle")
                        .frame(width: 160, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    if let progress = progress, !progress.isCompleted, progress.fraction > 0 {
                        ProgressBar(value: progress.fraction, height: 3).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.watchedIDs.contains(video.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).padding(5)
                    }
                }
                Text("\(video.episode.map { "\($0). " } ?? "")\(video.title.isEmpty ? "Episodio" : video.title)")
                    .font(.caption.weight(.semibold)).lineLimit(1).frame(width: 160, alignment: .leading)
                if future, let released = video.released {
                    Text("Esce il \(released.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.orange)
                }
            }
            .opacity(future ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel("\(video.episodeLabel ?? "Episodio"), \(video.title)")
        .accessibilityIdentifier("theater.episode.\(video.id)")
    }

    private func chip(_ text: String, filled: Bool = false) -> some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 4)
            .background(filled ? accent.opacity(0.9) : .white.opacity(0.14), in: Capsule())
            .foregroundStyle(filled ? Color.black : .white)
    }
}
