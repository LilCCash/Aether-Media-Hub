import SwiftUI
import AetherCore

// MARK: - Hero

struct HeroCarousel: View {
    let items: [MetaItem]
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HeroCard(meta: item).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 430)
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
        .task(id: items.count) {
            guard items.count > 1, settings.animationsEnabled, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if Task.isCancelled { return }
                withAnimation { index = (index + 1) % items.count }
            }
        }
        .accessibilityIdentifier("home.hero")
    }
}

struct HeroCard: View {
    let meta: MetaItem
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationLink(value: MetaRoute(meta: meta)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(urlString: meta.background ?? meta.poster, width: 900, placeholderSeed: meta.name)
                    .frame(maxWidth: .infinity)
                    .frame(height: 410)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
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
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.94))
                    if let description = meta.description, !description.isEmpty {
                        Text(description).font(.footnote).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        Label("Dettagli", systemImage: "play.fill")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .padding(.top, 4)
                }
                .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, Theme.pageMargin)
            .shadow(color: .black.opacity(0.25), radius: 16, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In evidenza: \(meta.name)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Continue watching

struct ContinueWatchingRow: View {
    let items: [PlaybackProgress]
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Continua a guardare")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        ContinueCard(progress: item)
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
    @EnvironmentObject private var env: AppEnvironment
    @State private var picker: StreamPickerRequest?

    var body: some View {
        Button {
            picker = StreamPickerRequest(meta: progress.asMeta, video: video, resumeAt: progress.position)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(urlString: progress.background ?? progress.poster, width: 280, placeholderSeed: progress.title)
                        .frame(width: 240, height: 135)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .padding(8).aetherGlass(in: Circle())
                        ProgressBar(value: progress.fraction)
                    }
                    .padding(10)
                }
                .frame(width: 240, height: 135)
                Text(progress.title).font(.system(.footnote, design: .rounded).weight(.semibold)).lineLimit(1).frame(width: 240, alignment: .leading)
                Text(subtitle).font(.aetherCaption()).foregroundStyle(Color.aetherSecondary).lineLimit(1).frame(width: 240, alignment: .leading)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Prossimi episodi", subtitle: "Dove eri rimasto")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        NextUpCard(item: item)
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
    @State private var picker: StreamPickerRequest?

    var body: some View {
        Button {
            picker = StreamPickerRequest(meta: item.meta, video: item.video, resumeAt: nil)
        } label: {
            HStack(spacing: 12) {
                RemoteImage(urlString: item.video.thumbnail ?? item.meta.background ?? item.meta.poster, width: 220, placeholderSeed: item.meta.name)
                    .frame(width: 110, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.meta.name).font(.system(.footnote, design: .rounded).weight(.semibold)).lineLimit(1)
                    Text([item.video.episodeLabel, item.video.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.aetherCaption()).foregroundStyle(Color.aetherSecondary).lineLimit(2)
                }
                .frame(width: 130, alignment: .leading)
            }
            .padding(10)
            .aetherGlassCard(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .sheet(item: $picker) { request in
            StreamPickerSheet(request: request)
        }
        .accessibilityLabel("Prossimo episodio di \(item.meta.name): \(item.video.episodeLabel ?? "") \(item.video.title)")
    }
}
