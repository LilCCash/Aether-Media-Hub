import SwiftUI
import AetherCore

// MARK: - Hero

/// Paged carousel. Built on a paging `ScrollView` with `containerRelativeFrame` instead of `TabView(.page)`: every page is
/// given exactly the width of the carousel, so a wide child can never make a page wider than the screen (and the
/// page-style TabView, inside a lazy scrolling stack, could start offset from its container).
struct HeroCarousel: View {
    let items: [MetaItem]
    var style: HeroStyle = .card
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: Int? = 0

    private var index: Int { min(max(position ?? 0, 0), max(items.count - 1, 0)) }
    private var pageHeight: CGFloat { style == .fullBleed ? HeroFullBleedCard.height : 430 }
    private var turnsPages: Bool { settings.animationsEnabled && settings.value.appearance.heroAutoScroll && !reduceMotion }

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
        .task(id: "\(items.count)-\(turnsPages)") {
            position = 0
            guard items.count > 1, turnsPages else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if Task.isCancelled { return }
                withAnimation { position = (index + 1) % items.count }
            }
        }
        .accessibilityIdentifier("home.hero")
    }

    @ViewBuilder
    private func page(_ item: MetaItem) -> some View {
        switch style {
        case .card: HeroCard(meta: item)
        case .fullBleed: HeroFullBleedCard(meta: item)
        }
    }
}

/// Title, facts, description and the "Dettagli" button drawn over a hero picture. White: it always sits on a dark scrim.
private struct HeroTextBlock: View {
    let meta: MetaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let logo = meta.logo, !logo.isEmpty {
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
}

/// The 1.0 look: a rounded card with the title over the picture.
struct HeroCard: View {
    let meta: MetaItem
    @Environment(\.aetherStyle) private var style

    var body: some View {
        NavigationLink(value: MetaRoute(meta: meta)) {
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

    static let height: CGFloat = 500
    /// The bottom stretch where the picture fades out; the text stays above it.
    static let fadeHeight: CGFloat = 70

    var body: some View {
        NavigationLink(value: MetaRoute(meta: meta)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(urlString: meta.background ?? meta.poster, width: 1200, placeholderSeed: meta.name)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.height)
                    .clipped()
                LinearGradient(stops: [.init(color: .clear, location: 0.28),
                                       .init(color: .black.opacity(0.62), location: 0.62),
                                       .init(color: .black.opacity(0.92), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                HeroTextBlock(meta: meta)
                    .padding(.horizontal, 20)
                    .padding(.bottom, Self.fadeHeight + 14)
            }
            .frame(height: Self.height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.05),
                                         .init(color: .black, location: 1 - Self.fadeHeight / Self.height),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In evidenza: \(meta.name)")
        .accessibilityAddTraits(.isButton)
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
                        ContinueCard(progress: item, width: HomeCardMetrics.width(style: style, size: size), cardStyle: style)
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
    /// Card width; the picture is 16:9 (2:3 for the poster style). Home rows size it from the section's size, the Library
    /// grid from its columns.
    var width: CGFloat = 240
    var cardStyle: HomeCardStyle = .landscape
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.aetherStyle) private var style
    @State private var picker: StreamPickerRequest?

    private var isPortrait: Bool { cardStyle == .poster }
    private var imageHeight: CGFloat { isPortrait ? width * 1.5 : width * 9 / 16 }
    private var radius: CGFloat { isPortrait ? style.posterRadius : style.landscapeRadius }
    private var artwork: String? { isPortrait ? (progress.poster ?? progress.background) : (progress.background ?? progress.poster) }

    var body: some View {
        Button {
            picker = StreamPickerRequest(meta: progress.asMeta, video: video, resumeAt: progress.position)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(urlString: artwork, width: isPortrait ? max(160, width) : max(280, width), placeholderSeed: progress.title)
                        .frame(width: width, height: imageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .padding(8).aetherGlass(in: Circle())
                        ProgressBar(value: progress.fraction)
                    }
                    .padding(10)
                }
                .frame(width: width, height: imageHeight)
                .aetherCardChrome(cornerRadius: radius)
                Text(progress.title).font(.system(.footnote, design: AetherTypography.design).weight(.semibold)).lineLimit(1).frame(width: width, alignment: .leading)
                Text(subtitle).font(.aetherCaption()).foregroundStyle(Color.aetherSecondary).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
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
        .sheet(item: $picker) { request in
            StreamPickerSheet(request: request)
        }
        .accessibilityLabel("\(progress.title), \(subtitle). Tocca per riprendere.")
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
                        NextUpCard(item: item, cardStyle: style, width: HomeCardMetrics.width(style: style, size: size))
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
    @State private var picker: StreamPickerRequest?

    private var episodeText: String {
        [item.video.episodeLabel, item.video.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Button {
            picker = StreamPickerRequest(meta: item.meta, video: item.video, resumeAt: nil)
        } label: {
            switch cardStyle {
            case .compact: compact
            case .landscape: tile(portrait: false)
            case .poster: tile(portrait: true)
            }
        }
        .buttonStyle(.plain)
        .sheet(item: $picker) { request in
            StreamPickerSheet(request: request)
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
