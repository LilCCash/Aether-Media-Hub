import SwiftUI
import AetherCore

final class PackDownloadModel: ObservableObject {
    struct Episode: Identifiable, Hashable {
        let season: Int
        let episode: Int
        var id: String { return "\(season)x\(episode)" }
        var label: String { return String(format: "S%02dE%02d", season, episode) }
    }

    @Published private(set) var episodes: [Episode] = []
    @Published var selected: Set<String> = []
    @Published private(set) var loading = true
    @Published private(set) var message: String?
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var finished: String?

    func load(item: RankedStream, meta: MetaItem, video: Video?, env: AppEnvironment) async {
        guard env.debrid.isConfigured else {
            message = "Configura TorBox o Real-Debrid in Impostazioni ▸ Servizi."
            loading = false
            return
        }
        let stremioID = DebridStreamLogic.stremioID(meta: meta, video: video)
        guard let request = DebridRequest(stream: item.stream, stremioID: stremioID, mode: .cachedOnly) else {
            message = "Questa sorgente non è un torrent valido."
            loading = false
            return
        }
        do {
            let result = try await env.debrid.resolve(request, onProgress: nil)
            var found: [Episode] = []
            for file in result.packFiles {
                guard let season = file.season, let first = file.firstEpisode else { continue }
                for number in first...max(first, file.lastEpisode ?? first) { found.append(Episode(season: season, episode: number)) }
            }
            let unique = Array(Set(found)).sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
            episodes = unique
            selected = Set(unique.map { $0.id })
            if unique.count < 2 { message = "Questo torrent non sembra contenere più episodi." }
        } catch let error as DebridError {
            if case .notCached = error {
                message = "Il torrent non è già pronto sul tuo servizio. Avvialo una volta dalla riproduzione normale (viene aggiunto al tuo account) e poi riprova."
            } else {
                message = error.message
            }
        } catch {
            message = DebridErrorText.describe(error, provider: env.debrid.selectedProvider)
        }
        loading = false
    }

    func download(item: RankedStream, meta: MetaItem, env: AppEnvironment) async {
        let chosen = episodes.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, progress == nil else { return }
        progress = (0, chosen.count)
        finished = nil
        var started = 0
        var failed = 0
        let allowLocal = env.settings.value.privacy.allowLocalNetwork
        for (index, entry) in chosen.enumerated() {
            let known = meta.videos.first { $0.season == entry.season && $0.episode == entry.episode }
            let video = known ?? Video(id: "\(meta.id):\(entry.season):\(entry.episode)", title: "Episodio \(entry.episode)",
                                       season: entry.season, episode: entry.episode)
            if let request = DebridRequest(stream: item.stream, stremioID: video.id, mode: .cachedOnly) {
                do {
                    let resolution = try await env.debrid.resolve(request, onProgress: nil)
                    let resolved = resolution.playableStream(from: item.stream)
                    let refusal = await env.downloads.enqueue(meta: meta, video: video, stream: resolved,
                                                              allowLocalNetwork: allowLocal, ephemeralURL: resolution.url)
                    if refusal == nil { started += 1 } else { failed += 1 }
                } catch {
                    failed += 1
                }
            } else {
                failed += 1
            }
            progress = (index + 1, chosen.count)
        }
        progress = nil
        finished = "Download avviati: \(started)" + (failed > 0 ? " · non riusciti: \(failed)" : "") + ". Li trovi in Libreria ▸ Download."
    }
}

struct PackDownloadSheet: View {
    let item: RankedStream
    let meta: MetaItem
    let video: Video?
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PackDownloadModel()

    var body: some View {
        NavigationStack {
            List {
                if model.loading {
                    HStack(spacing: 10) { ProgressView(); Text("Leggo i file del torrent…").foregroundStyle(Color.aetherSecondary) }
                }
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(Color.aetherSecondary)
                }
                if !model.episodes.isEmpty {
                    Section {
                        HStack {
                            Button("Seleziona tutti") { model.selected = Set(model.episodes.map { $0.id }) }
                            Spacer()
                            Button("Nessuno") { model.selected = [] }
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(seasons, id: \.self) { season in
                        Section(header: Text(season == 0 ? "Speciali" : "Stagione \(season)")) {
                            ForEach(model.episodes.filter { $0.season == season }) { entry in
                                Toggle(isOn: Binding(
                                    get: { model.selected.contains(entry.id) },
                                    set: { on in if on { model.selected.insert(entry.id) } else { model.selected.remove(entry.id) } })) {
                                    HStack {
                                        Text(entry.label).font(.system(.body, design: .monospaced))
                                        if let title = meta.videos.first(where: { $0.season == entry.season && $0.episode == entry.episode })?.title {
                                            Text(title).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if let progress = model.progress {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Preparo i download: \(progress.done) di \(progress.total)").font(.footnote)
                            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        }
                    }
                }
                if let finished = model.finished {
                    Section { Label(finished, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote) }
                }
            }
            .navigationTitle("Episodi del pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() }.disabled(model.progress != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Scarica \(model.selected.count)") { Task { await model.download(item: item, meta: meta, env: env) } }
                        .disabled(model.selected.isEmpty || model.progress != nil || model.loading)
                }
            }
            .task { await model.load(item: item, meta: meta, video: video, env: env) }
        }
        .presentationDetents([.medium, .large])
    }

    private var seasons: [Int] {
        return Array(Set(model.episodes.map { $0.season })).sorted()
    }
}
