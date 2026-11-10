import SwiftUI
import AetherCore

// MARK: - Hero

/// Paged carousel. Built on a paging `ScrollView` with `containerRelativeFrame` instead of `TabView(.page)`: every page is
/// given exactly the width of the carousel, so a wide child can never make a page wider than the screen (and the
/// page-style TabView, inside a lazy scrolling stack, could start offset from its container).
struct HeroCarousel: View {
    let items: [MetaItem]
    var style: HeroStyle = .card
    /// The picture starts at the top edge of the screen (see `HomeView.heroOnTop`).
    var reachesTop = false
    /// Told when another film comes to the front (by swiping or by itself), so the Home can take its colours.
    var onPage: ((MetaItem) -> Void)? = nil
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: Int? = 0

    private var index: Int { min(max(position ?? 0, 0), max(items.count - 1, 0)) }
    private var pageHeight: CGFloat { style == .fullBleed ? HeroFullBleedCard.height(reachesTop: reachesTop) : 430 }
    private var turnsPages: Bool { settings.animationsEnabled && settings.value.appearance.heroAutoScroll && !reduceMotion }
    private var interval: Double { min(20, max(3, settings.value.appearance.heroInterval)) }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                        page(item)
                            .containerRelativeFrame(.horizontal)
                            .id(offset)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollClipDisabled()
            .frame(height: pageHeight)
            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<items.count, id: \.self) { dot in
                        Capsule()
                            .fill(dot == index ? settings.accentColor : Color.primary.opacity(0.25))
                            .frame(width: dot == index ? 18 : 6, height: 6)
                    }
                }
                .animation(settings.animationsEnabled ? .spring(response: 0.3) : nil, value: index)
                .accessibilityHidden(true)
            }
        }
        .task(id: "\(items.count)-\(turnsPages)-\(interval)") {
            position = 0
            guard items.count > 1, turnsPages else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                withAnimation { position = (index + 1) % items.count }
            }
        }
        .onChange(of: index) { _, new in
            if items.indices.contains(new) { onPage?(items[new]) }
        }
        .accessibilityIdentifier("home.hero")
    }

    @ViewBuilder
    private func page(_ item: MetaItem) -> some View {
        switch style {
        case .card: HeroCard(meta: item)
        case .fullBleed: HeroFullBleedCard(meta: item, reachesTop: reachesTop)
        }
    }
}

/// Title, facts, description and the "Dettagli" button drawn over a hero picture. White: it always sits on a dark scrim.
private struct HeroTextBlock: View {
    let meta: MetaItem
    var showsButton = true
    @EnvironmentObject private var env: AppEnvironment
    @State private var storeLogo: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = storeLogo {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 84, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            } else if let logo = meta.logo, !logo.isEmpty {
                RemoteImage(urlString: logo, width: 400, contentMode: .fit, alignment: .leading)
                    .frame(width: 240, height: 72, alignment: .leading)
            } else {
                Text(meta.name).font(.aetherTitle(30)).foregroundStyle(.white).lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(RequestPlanner.friendlyTypeName(meta.type))
                if let year = meta.releaseInfo { Text("· \(year)") }
                if let rating = meta.imdbRating { Text("· ★ \(rating)") }
            }
            .font(.system(.footnote, design: AetherTypography.design).weight(.medium))
            .foregroundStyle(.white.opacity(0.94))
            if let description = meta.description, !description.isEmpty {
                Text(description).font(.footnote).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
            }
            if showsButton {
                HStack(spacing: 10) {
                    Label("Dettagli", systemImage: "play.fill")
                        .font(.system(.subheadline, design: AetherTypography.design).weight(.bold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                .padding(.top, 4)
            }
        }
        .task(id: meta.id) {
            storeLogo = FanartLogoStore.shared.cached(meta.id)
            if storeLogo == nil { storeLogo = await FanartLogoStore.shared.load(meta: meta, env: env) }
        }
        .repaintsWithTitleFont()
    }
}

/// The 1.0 look: a rounded card with the title over the picture.
struct HeroCard: View {
    let meta: MetaItem
    @Environment(\.aetherStyle) private var style

    var body: some View {
        TitleLink(route: MetaRoute(meta: meta)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(urlString: meta.background ?? meta.poster, width: 900, placeholderSeed: meta.name)
                    .frame(maxWidth: .infinity)
                    .frame(height: 410)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                HeroTextBlock(meta: meta)
                    .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: style.heroRadius, style: .continuous))
            .padding(.horizontal, Theme.pageMargin)
            .shadow(color: .black.opacity(0.25), radius: 16, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In evidenza: \(meta.name)")
        .accessibilityAddTraits(.isButton)
    }
}

/// The picture runs from edge to edge and melts into the page at the bottom, with the title over it. The text sits above the
/// melting zone, on the dark scrim, so it stays readable in the light and dark appearance alike.
struct HeroFullBleedCard: View {
    let meta: MetaItem
    /// At the top edge of the screen: taller by the status bar, no fade at the top, a light shade under the clock.
    var reachesTop = false
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryModel

    static let height: CGFloat = 560
    static func height(reachesTop: Bool) -> CGFloat { return reachesTop ? height + 60 : height }
    /// The bottom stretch where the picture fades out; the text stays above it.
    static let fadeHeight: CGFloat = 96
    private var height: CGFloat { return Self.height(reachesTop: reachesTop) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TitleLink(route: MetaRoute(meta: meta)) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(urlString: meta.background ?? meta.poster, width: 1200, placeholderSeed: meta.name)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .clipped()
                    LinearGradient(stops: [.init(color: .black.opacity(reachesTop ? 0.35 : 0), location: 0),
                                           .init(color: .clear, location: 0.22),
                                           .init(color: .clear, location: 0.34),
                                           .init(color: .black.opacity(0.5), location: 0.62),
                                           .init(color: .black.opacity(0.86), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    HeroTextBlock(meta: meta, showsButton: false)
                        .padding(.horizontal, 20)
                        .padding(.bottom, Self.fadeHeight + 70)
                }
                .frame(height: height)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("In evidenza: \(meta.name)")
            .accessibilityAddTraits(.isButton)
            // The buttons are siblings of the link, not inside it: each one answers on its own.
            HStack(spacing: 12) {
                Button { router.detail = MetaRoute(meta: meta) } label: {
                    Label("Dettagli", systemImage: "play.fill")
                        .font(.system(.headline, design: AetherTypography.design).weight(.bold))
                        .padding(.horizontal, 26).padding(.vertical, 13)
                        .background(.white, in: Capsule()).foregroundStyle(.black)
                }
                .accessibilityIdentifier("hero.details")
                Button { library.toggleWatchlist(meta) } label: {
                    Image(systemName: library.watchlistIDs.contains(meta.id) ? "checkmark" : "plus")
                        .aetherSymbolSwap()
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                }
                .accessibilityLabel(library.watchlistIDs.contains(meta.id) ? "Rimuovi dalla watchlist" : "Aggiungi alla watchlist")
                .accessibilityIdentifier("hero.watchlist")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, Self.fadeHeight - 10)
        }
        .frame(height: height)
        .mask(LinearGradient(stops: [.init(color: reachesTop ? .black : .clear, location: 0),
                                     .init(color: .black, location: 0.04),
                                     .init(color: .black, location: 1 - Self.fadeHeight / height),
                                     .init(color: .black.opacity(0.55), location: 1 - Self.fadeHeight / height * 0.5),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Cards of a Home row

/// A 16:9 card for a catalogue title (the picture is the backdrop when the addon gives one).
struct MetaLandscapeCard: View {
    let meta: MetaItem
    var width: CGFloat = 240
    var isInWatchlist: Bool = false
    @Environment(\.aetherStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RemoteImage(urlString: meta.background ?? meta.poster, width: max(280, width), placeholderSeed: meta.name)
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: style.landscapeRadius, style: .continuous))
                    .aetherCardChrome(cornerRadius: style.landscapeRadius)
                HStack {
                    if let rating = meta.imdbRating, !rating.isEmpty { RatingBadge(rating: rating) }
                    Spacer(minLength: 0)
                    if isInWatchlist {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .accessibilityLabel("In watchlist")
                    }
                }
                .padding(6)
            }
            .frame(width: width, height: width * 9 / 16)
            Text(meta.name)
                .font(.system(.footnote, design: AetherTypography.design).weight(.semibold))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            if let year = meta.releaseInfo, !year.isEmpty {
                Text(year).font(.aetherCaption()).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [meta.name]
        if let year = meta.releaseInfo, !year.isEmpty { parts.append(year) }
        if let rating = meta.imdbRating, !rating.isEmpty { parts.append("valutazione \(rating)") }
        if isInWatchlist { parts.append("nella watchlist") }
        return parts.joined(separator: ", ")
    }
}

/// Width of one card for `style` at `size`, in points.
enum HomeCardMetrics {
    static func width(style: HomeCardStyle, size: PosterSize) -> CGFloat {
        switch style {
        case .poster: return CGFloat(size.rowWidth)
        case .landscape, .compact: return CGFloat(size.landscapeWidth)
        }
    }

    /// Width over height of the card's picture, for placeholders.
    static func aspectRatio(style: HomeCardStyle) -> CGFloat {
        switch style {
        case .poster: return 0.675
        case .landscape, .compact: return 16.0 / 9.0
        }
    }
}

// MARK: - Continue watching

struct ContinueWatchingRow: View {
    let items: [PlaybackProgress]
    var style: HomeCardStyle = .landscape
    var size: PosterSize = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Continua a guardare")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        ContinueCard(progress: item, width: HomeCardMetrics.width(style: style, size: size), cardStyle: style).aetherRowMotion()
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
            .scrollClipDisabled()
        }
        .accessibilityIdentifier("home.continue")
    }
}

struct ContinueCard: View {
    let progress: PlaybackProgress
    /// Card width; the picture is 16:9 (2:3 for the poster style). Home rows size it from the section's size. Nil: the card takes the
    /// width its grid column offers (the Library), so a row of three always fills the screen edge to edge.
    var width: CGFloat? = 240
    var cardStyle: HomeCardStyle = .landscape
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.aetherStyle) private var style

    private var isPortrait: Bool { cardStyle == .poster }
    private var ratio: CGFloat { isPortrait ? 2.0 / 3.0 : 16.0 / 9.0 }
    private var radius: CGFloat { isPortrait ? style.posterRadius : style.landscapeRadius }
    private var artwork: String? { isPortrait ? (progress.poster ?? progress.background) : (progress.background ?? progress.poster) }

    var body: some View {
        Button {
            router.picker = StreamPickerRequest(meta: progress.asMeta, video: video, resumeAt: progress.position)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                picture
                    // The wide card had no hairline in 1.0; the poster-shaped one is framed like every poster.
                    .aetherCardChrome(cornerRadius: radius, hairline: isPortrait)
                Text(progress.title).font(.system(.footnote, design: AetherTypography.design).weight(.semibold)).lineLimit(1)
                    .frame(width: width, alignment: .leading)
                    .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                Text(subtitle).font(.aetherCaption()).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                    .frame(width: width, alignment: .leading)
                    .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                let meta = progress.asMeta
                router.detail = MetaRoute(type: meta.type, id: meta.id, preview: meta)
            } label: {
                Label("Vai alla scheda del titolo", systemImage: "info.circle")
            }
            Button { Task { await env.libraryStore.dismissFromContinueWatching(metaID: progress.metaID) } } label: {
                Label("Rimuovi da Continua a guardare", systemImage: "xmark.circle")
            }
            Button { Task { await env.libraryStore.markWatched(true, meta: progress.asMeta, video: video) } } label: {
                Label("Segna come visto", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) { Task { await env.libraryStore.removeHistory(id: progress.id) } } label: {
                Label("Elimina dalla cronologia", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(progress.title), \(subtitle). Tocca per riprendere.")
    }

    /// The artwork with the play button and the progress bar, at its ratio: a fixed size in the Home rows, the column width in a grid.
    @ViewBuilder
    private var picture: some View {
        let compact = (width ?? 0) < 150
        let overlay = ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Image(systemName: "play.fill").font(.system(size: compact ? 10 : 13, weight: .bold)).foregroundStyle(.white)
                    .padding(compact ? 6 : 8).aetherGlass(in: Circle())
                ProgressBar(value: progress.fraction)
            }
            .padding(compact ? 7 : 10)
        }
        if let width = width {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(urlString: artwork, width: isPortrait ? max(160, width) : max(280, width), placeholderSeed: progress.title)
                    .frame(width: width, height: width / ratio)
                overlay
            }
            .frame(width: width, height: width / ratio)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            Color.clear
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { RemoteImage(urlString: artwork, width: isPortrait ? 300 : 420, placeholderSeed: progress.title) }
                .overlay(alignment: .bottomLeading) { overlay }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    private var video: Video? {
        guard progress.videoID != progress.metaID else { return nil }
        return Video(id: progress.videoID, title: progress.episodeTitle ?? "", season: progress.season, episode: progress.episode)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let label = progress.episodeLabel { parts.append(label) }
        if let remaining = progress.remaining { parts.append(Format.remaining(remaining)) }
        else { parts.append(Format.duration(progress.position)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Next up

struct NextUpRow: View {
    let items: [HomeViewModel.NextUpItem]
    var style: HomeCardStyle = .compact
    var size: PosterSize = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Prossimi episodi", subtitle: "Dove eri rimasto")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        NextUpCard(item: item, cardStyle: style, width: HomeCardMetrics.width(style: style, size: size)).aetherRowMotion()
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
            .scrollClipDisabled()
        }
        .accessibilityIdentifier("home.nextup")
    }
}

struct NextUpCard: View {
    let item: HomeViewModel.NextUpItem
    var cardStyle: HomeCardStyle = .compact
    /// Used by the wide and poster styles; the compact card has a fixed size.
    var width: CGFloat = 240
    @Environment(\.aetherStyle) private var style
    @EnvironmentObject private var router: AppRouter

    private var episodeText: String {
        [item.video.episodeLabel, item.video.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Button {
            router.picker = StreamPickerRequest(meta: item.meta, video: item.video, resumeAt: nil)
        } label: {
            switch cardStyle {
            case .compact: compact
            case .landscape: tile(portrait: false)
            case .poster: tile(portrait: true)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                router.detail = MetaRoute(type: item.meta.type, id: item.meta.id, preview: item.meta)
            } label: {
                Label("Vai alla scheda del titolo", systemImage: "info.circle")
            }
        }
        .accessibilityLabel("Prossimo episodio di \(item.meta.name): \(item.video.episodeLabel ?? "") \(item.video.title)")
    }

    private var compact: some View {
        HStack(spacing: 12) {
            RemoteImage(urlString: item.video.thumbnail ?? item.meta.background ?? item.meta.poster, width: 220, placeholderSeed: item.meta.name)
                .frame(width: 110, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: style.thumbnailRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.meta.name).font(.system(.footnote, design: AetherTypography.design).weight(.semibold)).lineLimit(1)
                Text(episodeText)
                    .font(.aetherCaption()).foregroundStyle(Color.aetherSecondary).lineLimit(2)
            }
            .frame(width: 130, alignment: .leading)
        }
        .padding(10)
        .aetherGlassCard(cornerRadius: style.glassCardRadius)
    }

    private func tile(portrait: Bool) -> some View {
        let height = portrait ? width * 1.5 : width * 9 / 16
        let radius = portrait ? style.posterRadius : style.landscapeRadius
        let artwork = portrait ? (item.meta.poster ?? item.meta.background) : (item.video.thumbnail ?? item.meta.background ?? item.meta.poster)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(urlString: artwork, width: portrait ? max(160, width) : max(280, width), placeholderSeed: item.meta.name)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                if let label = item.video.episodeLabel, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 11, weight: .bold, design: AetherTypography.design))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(8)
                }
            }
            .frame(width: width, height: height)
            .aetherCardChrome(cornerRadius: radius)
            Text(item.meta.name).font(.system(.footnote, design: AetherTypography.design).weight(.semibold)).lineLimit(1)
                .frame(width: width, alignment: .leading)
            Text(item.video.title.isEmpty ? (item.video.episodeLabel ?? "") : item.video.title)
                .font(.aetherCaption()).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }
}
