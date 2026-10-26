import SwiftUI
import AetherCore

struct DownloadsView: View {
    var filter: String = ""
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    private var visibleItems: [DownloadItem] {
        downloads.items.filter { item in
            (filter.isEmpty || MetaDeduper.normalise(item.title).contains(MetaDeduper.normalise(filter)))
        }
    }

    private var titleIDs: [String] {
        Array(Set(visibleItems.map(\.metaID))).sorted { lhs, rhs in
            let left = visibleItems.first(where: { $0.metaID == lhs })?.title ?? lhs
            let right = visibleItems.first(where: { $0.metaID == rhs })?.title ?? rhs
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            storageHeader
            if visibleItems.isEmpty {
                ScrollView {
                    EmptyStateView(systemImage: "arrow.down.circle", title: "Nessun download",
                                   message: "I download in corso e i file completati appariranno qui, raggruppati per serie e stagione.")
                        .padding(.top, 40)
                }
                .accessibilityIdentifier("downloads.empty")
            } else {
                List {
                    ForEach(titleIDs, id: \.self) { metaID in
                        titleSection(metaID: metaID)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("downloads.list")
            }
        }
    }

    @ViewBuilder
    private func titleSection(metaID: String) -> some View {
        let titleItems = visibleItems.filter { $0.metaID == metaID }.sorted { $0.createdAt > $1.createdAt }
        let title = titleItems.first?.title ?? metaID
        let isSeries = titleItems.contains { $0.videoID != nil }
        if isSeries {
            DisclosureGroup {
                let seasonGroups = Dictionary(grouping: titleItems, by: { seasonNumber(for: $0) })
                ForEach(seasonGroups.keys.sorted(), id: \.self) { season in
                    DisclosureGroup {
                        let episodeItems = (seasonGroups[season] ?? []).sorted { $0.createdAt > $1.createdAt }
                        ForEach(episodeItems) { item in
                            DownloadRow(item: item)
                                .swipeActions {
                                    Button(role: .destructive) { downloads.remove(item.id) } label: {
                                        Label("Elimina", systemImage: "trash")
                                    }
                                }
                        }
                    } label: {
                        HStack {
                            Text(season == 0 ? "Altri episodi" : "Stagione \(season)")
                                .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                            Spacer()
                            Text("\(seasonGroups[season]?.count ?? 0)")
                                .font(.caption).foregroundStyle(Color.aetherSecondary)
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    RemoteImage(urlString: titleItems.first?.poster, width: 100, placeholderSeed: title)
                        .frame(width: 40, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                        Text("\(titleItems.count) episodi · download e file completati")
                            .font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                }
                .padding(.vertical, 3)
            }
        } else {
            ForEach(titleItems) { item in
                DownloadRow(item: item)
                    .swipeActions {
                        Button(role: .destructive) { downloads.remove(item.id) } label: {
                            Label("Elimina", systemImage: "trash")
                        }
                    }
            }
        }
    }

    /// Stremio episode IDs usually end in :season:episode.
    /// Unknown IDs are grouped separately instead of inventing a season number.
    private func seasonNumber(for item: DownloadItem) -> Int {
        guard let id = item.videoID else { return 0 }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let season = Int(parts[parts.count - 2]), season >= 0 else { return 0 }
        return season
    }

    private var storageHeader: some View {
        HStack {
            Image(systemName: "internaldrive")
            Text("\(Format.bytes(downloads.totalBytes)) usati · \(Format.bytes(AppPaths.availableCapacity())) liberi")
                .font(.footnote)
            Spacer()
        }
        .foregroundStyle(Color.aetherSecondary)
        .padding(.horizontal, Theme.pageMargin)
        .padding(.vertical, 6)
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(urlString: item.poster, width: 100, placeholderSeed: item.title)
                .frame(width: 44, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.subtitle?.isEmpty == false ? item.subtitle! : item.title)
                    .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold)).lineLimit(2)
                if item.subtitle?.isEmpty == false && item.videoID == nil {
                    Text(item.title).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                }
                statusLine
                if item.state == .downloading || item.state == .paused {
                    ProgressView(value: item.fraction).tint(.accentColor)
                }
            }
            Spacer(minLength: 0)
            actionButton
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.state {
        case .queued: Label("In coda", systemImage: "clock").font(.caption2).foregroundStyle(Color.aetherSecondary)
        case .downloading:
            Text("\(Int(item.fraction * 100))% · \(Format.bytes(item.bytesWritten)) di \(item.totalBytes > 0 ? Format.bytes(item.totalBytes) : "?")")
                .font(.caption2).foregroundStyle(Color.aetherSecondary)
        case .paused: Label("In pausa", systemImage: "pause.circle").font(.caption2).foregroundStyle(Color.aetherSecondary)
        case .completed: Label(Format.bytes(item.totalBytes), systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .failed:
            Label(item.errorMessage ?? "Errore", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).lineLimit(3)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item.state {
        case .queued, .downloading:
            Button { downloads.pause(item.id) } label: { Image(systemName: "pause.circle.fill").font(.title2) }
                .buttonStyle(.plain).accessibilityLabel("Metti in pausa")
        case .paused:
            Button { downloads.resume(item.id) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                .buttonStyle(.plain).accessibilityLabel("Riprendi download")
        case .failed:
            Button { downloads.retry(item.id) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title2) }
                .buttonStyle(.plain).accessibilityLabel("Riprova")
        case .completed:
            Button { playOffline() } label: { Image(systemName: "play.circle.fill").font(.title2) }
                .buttonStyle(.plain).accessibilityLabel("Riproduci offline")
        }
    }

    private func playOffline() {
        let meta = MetaItem(id: item.metaID, type: item.type, name: item.title, poster: item.poster)
        let video = item.videoID.map { Video(id: $0, title: item.subtitle ?? "") }
        router.play(PlayerRequest(meta: meta, video: video, source: .download(item), alternatives: []))
    }
}
