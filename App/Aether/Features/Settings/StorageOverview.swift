import SwiftUI
import AetherCore

/// The space Aether takes, as one bar split in films, series, cache and the rest, with what can be given back.
struct StorageOverview: View {
    let report: AppEnvironment.StorageReport?
    let items: [DownloadItem]
    let history: [PlaybackProgress]
    var refresh: () async -> Void = {}
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var downloads: DownloadManager
    @State private var confirming = false
    @State private var working = false

    struct Segment: Identifiable {
        var id: String
        var title: String
        var bytes: Int64
        var color: Color
    }

    private var filmBytes: Int64 { items.filter { $0.type == "movie" }.reduce(0) { $0 + $1.bytesWritten } }
    private var seriesBytes: Int64 { items.filter { $0.type != "movie" }.reduce(0) { $0 + $1.bytesWritten } }
    private var cacheBytes: Int64 { (report?.images ?? 0) + (report?.metadata ?? 0) }
    private var otherBytes: Int64 { max(0, (report?.downloads ?? 0) - filmBytes - seriesBytes) }

    /// Downloads that are finished and already watched to the end.
    private var watched: [DownloadItem] {
        items.filter { item in
            guard item.state == .completed else { return false }
            return history.contains { $0.isCompleted && $0.metaID == item.metaID && (item.videoID == nil || $0.videoID == item.videoID) }
        }
    }

    private var recoverable: Int64 { cacheBytes + otherBytes + watched.reduce(0) { $0 + max($1.bytesWritten, $1.totalBytes) } }

    private var segments: [Segment] {
        [Segment(id: "film", title: "Film", bytes: filmBytes, color: .pink),
         Segment(id: "series", title: "Serie", bytes: seriesBytes, color: .indigo),
         Segment(id: "cache", title: "Cache", bytes: cacheBytes, color: .teal),
         Segment(id: "other", title: "Altro", bytes: otherBytes, color: .gray)]
    }

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.bytes }, 1)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.bytes(segments.reduce(0) { $0 + $1.bytes })).font(.system(size: 32, weight: .bold, design: .rounded))
                Text("usati da Aether").font(.subheadline).foregroundStyle(Color.aetherSecondary)
                Spacer()
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.bytes > 0 }) { segment in
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(segment.color.gradient)
                            .frame(width: max(6, proxy.size.width * CGFloat(Double(segment.bytes) / Double(total))))
                    }
                    if segments.allSatisfy({ $0.bytes == 0 }) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.1))
                    }
                }
            }
            .frame(height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(segments) { segment in
                    HStack(spacing: 8) {
                        Circle().fill(segment.color).frame(width: 10, height: 10)
                        Text(segment.title).font(.subheadline)
                        Spacer(minLength: 4)
                        Text(Format.bytes(segment.bytes)).font(.subheadline.monospacedDigit()).foregroundStyle(Color.aetherSecondary)
                    }
                }
            }
            Divider()
            HStack {
                Label("Spazio libero", systemImage: "internaldrive").font(.subheadline)
                Spacer()
                Text(Format.bytes(AppPaths.availableCapacity())).font(.subheadline.monospacedDigit()).foregroundStyle(Color.aetherSecondary)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spazio recuperabile").font(.headline)
                    Text(watched.isEmpty ? "Cache e file inutilizzati" : "Cache, file inutilizzati e \(watched.count) download già visti")
                        .font(.caption).foregroundStyle(Color.aetherSecondary)
                }
                Spacer()
                Text(Format.bytes(recoverable)).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(.tint)
            }
            Button { confirming = true } label: {
                Label(working ? "Un momento…" : "Libera spazio", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || recoverable == 0)
            .confirmationDialog("Libera spazio", isPresented: $confirming, titleVisibility: .visible) {
                Button("Svuota la cache") { Task { await free(includeWatched: false) } }
                if !watched.isEmpty {
                    Button("Svuota la cache ed elimina i download già visti", role: .destructive) { Task { await free(includeWatched: true) } }
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("La cache si ricostruisce da sola. I download già visti si possono scaricare di nuovo.")
            }
        }
        .padding(.vertical, 2)
    }

    private func free(includeWatched: Bool) async {
        working = true
        await env.clearImageCache()
        await env.clearMetadataCache()
        if includeWatched {
            for item in watched { downloads.remove(item.id) }
        }
        await refresh()
        working = false
        Haptics.success()
    }
}
