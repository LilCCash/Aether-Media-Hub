import SwiftUI
import AetherCore

/// The page of a title in Theater Mode: the backdrop fills the screen and the facts sit over it, on the left, with the poster standing
/// on the right. For a series the seasons and the episodes run along the bottom. Playing continues in the source choice of this mode.
struct TheaterDetail: View {
    let meta: MetaItem
    let close: () -> Void
    let pick: (MetaItem, Video?) -> Void
    /// Opens another title (a similar film, a film of the saga) in this same page.
    let open: (MetaItem) -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: LibraryModel
    @AppStorage(TheaterPrefs.palette) private var palette = 0
    @AppStorage(TheaterPrefs.corners) private var corners = 1
    @StateObject private var model: DetailViewModel
    @State private var shown = false
    @State private var person: PersonRoute?
    @State private var lookingUp = false
    @State private var problem: String?

    init(meta: MetaItem, close: @escaping () -> Void, pick: @escaping (MetaItem, Video?) -> Void, open: @escaping (MetaItem) -> Void = { _ in }) {
        self.meta = meta
        self.close = close
        self.pick = pick
        self.open = open
        _model = StateObject(wrappedValue: DetailViewModel(route: MetaRoute(meta: meta)))
    }

    private var current: MetaItem { model.meta }
    private var accent: Color { TheaterPalette.color(palette) }
    private var radius: CGFloat { [4, 10, 16][min(max(corners, 0), 2)] }
    private var inWatchlist: Bool { library.watchlistIDs.contains(meta.id) }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                backdrop
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        hero.frame(height: proxy.size.height)
                        moreSections
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .task { await model.load(env: env) }
        .onAppear { withAnimation(.easeOut(duration: 0.35).delay(0.08)) { shown = true } }
        .fullScreenCover(item: $person) { route in
            NavigationStack {
                PersonFilmographyView(route: route)
                    .navigationTitle(route.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Chiudi") { person = nil } }
                    }
            }
            .tint(accent)
            .preferredColorScheme(.dark)
        }
        .alert("Titolo non disponibile", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    /// The first screen: facts, play button and, for a series, the episodes.
    private var hero: some View {
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

    // MARK: Below the first screen: the same information as the page of the normal app

    @ViewBuilder
    private var moreSections: some View {
        let modules = env.settings.value.content.titleModules
        VStack(alignment: .leading, spacing: 22) {
            if let text = current.description, !text.isEmpty {
                block("Trama") { Text(text).font(.callout).foregroundStyle(.white.opacity(0.88)) }
            }
            let directors = current.directors
            if !directors.isEmpty {
                block("Regia") { Text(directors.joined(separator: ", ")).font(.callout).foregroundStyle(.white.opacity(0.88)) }
            } else if let creators = model.rich?.creators, !creators.isEmpty {
                block("Creato da") { Text(creators.joined(separator: ", ")).font(.callout).foregroundStyle(.white.opacity(0.88)) }
            }
            if let rich = model.rich {
                let ratingChoice = env.settings.value.content.ratings
                let chosen = model.ratings.filter { ratingChoice.sources.contains($0.source) && $0.display != nil }
                if !chosen.isEmpty { TitleRatingsSection(ratings: chosen) }
                if !rich.cast.isEmpty && modules.cast {
                    TitleCastSection(people: rich.cast) { personItem in
                        if let id = personItem.tmdbPersonID { person = PersonRoute(personID: id, name: personItem.name) }
                    }
                }
                if !rich.trailers.isEmpty && modules.trailers { TitleTrailersSection(trailers: rich.trailers) }
                if !model.sagaFilms.isEmpty, let saga = rich.collection {
                    TitleSimilarSection(titles: model.sagaFilms, heading: saga.name, identifier: "theater.saga", open: openSimilar)
                }
                if !rich.companies.isEmpty && modules.companies { TitleCompaniesSection(companies: rich.companies) }
                if (rich.budget != nil || rich.revenue != nil) && modules.financials { TitleFinancialsSection(budget: rich.budget, revenue: rich.revenue) }
                let rows = rich.detailRows()
                if !rows.isEmpty && modules.facts { TitleFactsSection(rows: rows) }
                if !rich.similar.isEmpty && modules.similar { TitleSimilarSection(titles: rich.similar, open: openSimilar) }
                TMDBAttributionView().padding(.horizontal, 24)
            } else {
                if !current.cast.isEmpty {
                    block("Cast") { Text(current.cast.prefix(12).joined(separator: ", ")).font(.callout).foregroundStyle(.white.opacity(0.88)) }
                }
                if model.suggestsTMDBKey { TMDBKeyHint() }
            }
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.84))
        .environment(\.colorScheme, .dark)
        .tint(accent)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 22, weight: .bold, design: .serif)).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.horizontal, 24)
    }

    /// A similar title is known to TMDB by its own id; the catalog knows it by its IMDb id, which is asked for first.
    private func openSimilar(_ item: TitleRichDetails.Similar) {
        guard !lookingUp else { return }
        lookingUp = true
        let type = model.meta.type
        Task {
            defer { lookingUp = false }
            guard let imdb = await env.metadata.imdbID(forTMDBID: item.tmdbID, metaType: type) else {
                problem = "Non riesco a trovare «\(item.title)» negli addon: TMDB non indica il suo codice IMDb oppure non risponde."
                return
            }
            open(MetaItem(id: imdb, type: type, name: item.title, poster: item.posterURL))
        }
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
