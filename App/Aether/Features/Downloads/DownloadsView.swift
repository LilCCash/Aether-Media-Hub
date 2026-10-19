import SwiftUI
import AetherCore

struct DownloadsView: View {
    var filter: String = ""
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        let items = downloads.items.filter { filter.isEmpty || MetaDeduper.normalise($0.title).contains(MetaDeduper.normalise(filter)) }
        VStack(spacing: 0) {
            storageHeader
            if items.isEmpty {
                ScrollView {
                    EmptyStateView(systemImage: "arrow.down.circle", title: "Nessun download",
                                   message: "Dalla scheda di un titolo puoi scaricare le sorgenti che sono file diretti (MP4/MOV su HTTPS). HLS, torrent e archivi non sono scaricabili.")
                        .padding(.top, 40)
                }
                .accessibilityIdentifier("downloads.empty")
            } else {
                List {
                    ForEach(items) { item in
                        DownloadRow(item: item)
                            .swipeActions {
                                Button(role: .destructive) { downloads.remove(item.id) } label: { Label("Elimina", systemImage: "trash") }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("downloads.list")
            }
        }
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
                Text(item.title).font(.system(.subheadline, design: .rounded).weight(.semibold)).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(1)
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
        .accessibilityElement(children: .combine)
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
