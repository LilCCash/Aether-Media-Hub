import SwiftUI
import AetherCore

/// Libreria ▸ Cloud: i file che l'utente ha nel suo servizio debrid (TorBox, Real-Debrid), con filtro per servizio e per tipo.
@MainActor
final class CloudLibraryModel: ObservableObject {
    @Published private(set) var items: [DebridCloudItem] = []
    @Published private(set) var loading = false
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var loaded = false
    @Published var provider: DebridService.ProviderChoice?
    @Published var kind: DebridCloudKind?
    @Published var message: String?
    @Published private(set) var playingID: String?

    func load(env: AppEnvironment) async {
        guard !loading else { return }
        loading = true
        let result = await env.debrid.cloudItems()
        items = result.items
        failures = result.failures
        loading = false
        loaded = true
    }

    func visible(matching text: String) -> [DebridCloudItem] {
        let needle = MetaDeduper.normalise(text)
        return items.filter { (item: DebridCloudItem) -> Bool in
            if let provider = provider, item.provider != provider.rawValue { return false }
            if let kind = kind, item.kind != kind { return false }
            return needle.isEmpty || MetaDeduper.normalise(item.name).contains(needle)
        }
    }

    static func displayName(_ raw: String) -> String {
        var name = raw
        if let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) <= 5, name.contains(".") == true {
            let ext = name[name.index(after: dot)...].lowercased()
            if ["mkv", "mp4", "avi", "mov", "m4v", "ts", "m2ts"].contains(ext) { name = String(name[..<dot]) }
        }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// Plays the file: a torrent through its provider (only when it is ready), a web download straight from its link.
    func play(_ item: DebridCloudItem, env: AppEnvironment) async {
        guard item.isReady else {
            message = "Non è ancora pronto: \(Int(item.progress * 100))%."
            return
        }
        let meta = MetaItem(id: "cloud:" + item.id, type: "movie", name: Self.displayName(item.name))
        var directLink = item.directLink
        if directLink == nil, let webID = item.webID {
            playingID = item.id
            defer { playingID = nil }
            do { directLink = try await env.debrid.torboxWebLink(webID: webID, fileID: item.fileID ?? 0).absoluteString } catch {
                message = DebridErrorText.describe(error, provider: .torbox)
                return
            }
        }
        if let link = directLink {
            guard let url = URL.lenient(link) else {
                message = "Il link di questo file non è valido."
                return
            }
            if let blocked = await env.validateMediaURL(url) {
                message = blocked.message
                return
            }
            let stream = AddonStream(source: .url(link))
            env.router.play(PlayerRequest(meta: meta, video: nil, source: .stream(stream), alternatives: []))
            return
        }
        guard let hash = item.hash, let provider = DebridService.ProviderChoice(rawValue: item.provider) else {
            message = "Questo file non ha un hash valido."
            return
        }
        playingID = item.id
        defer { playingID = nil }
        let stream = AddonStream(source: .torrent(infoHash: hash, fileIndex: nil, trackers: []))
        let stremioID = DebridStreamLogic.stremioID(meta: meta, video: nil)
        let request = DebridRequest(infoHash: hash, stremioID: nil, mode: .cachedOnly)
        do {
            let result = try await env.debrid.resolve(request, provider: provider, onProgress: nil)
            if let blocked = await env.validateMediaURL(result.url) {
                message = blocked.message
                return
            }
            env.debrid.stashResolution(result, for: stream, stremioID: stremioID)
            env.router.play(PlayerRequest(meta: meta, video: nil, source: .stream(stream), alternatives: []))
        } catch let error as DebridError {
            message = error.message
        } catch {
            message = DebridErrorText.describe(error, provider: provider)
        }
    }

    /// The text to copy for the item: the direct link, or a magnet for a torrent.
    func link(for item: DebridCloudItem) -> String? {
        if let link = item.directLink { return link }
        guard let hash = item.hash else { return nil }
        return "magnet:?xt=urn:btih:\(hash)"
    }
}

struct CloudLibraryView: View {
    let filter: String
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model = CloudLibraryModel()

    private var configuredProviders: [DebridService.ProviderChoice] {
        return DebridService.ProviderChoice.allCases.filter { env.debrid.hasCredentials(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if configuredProviders.isEmpty {
                ScrollView {
                    EmptyStateView(systemImage: "icloud.slash", title: "Nessun servizio collegato",
                                   message: "Aggiungi la chiave di TorBox o Real-Debrid in Impostazioni ▸ Servizi per vedere qui i tuoi file.")
                        .padding(.top, 60)
                }
            } else {
                filters
                list
            }
        }
        .task { if configuredProviders.isEmpty == false && !model.loaded { await model.load(env: env) } }
        .alert("Cloud", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Servizio", selection: $model.provider) {
                    Text("Tutti i servizi").tag(DebridService.ProviderChoice?.none)
                    ForEach(configuredProviders) { Text($0.title).tag(DebridService.ProviderChoice?.some($0)) }
                }
            } label: {
                FilterMenuLabel(title: model.provider?.title ?? "Tutti i servizi", systemImage: "cloud")
            }
            Menu {
                Picker("Tipo", selection: $model.kind) {
                    Text("Tutti i tipi").tag(DebridCloudKind?.none)
                    ForEach(DebridCloudKind.allCases, id: \.self) { Text($0.title).tag(DebridCloudKind?.some($0)) }
                }
            } label: {
                FilterMenuLabel(title: model.kind?.title ?? "Tutti i tipi", systemImage: "line.3.horizontal.decrease.circle")
            }
            Spacer()
            Button {
                Task { await model.load(env: env) }
            } label: {
                if model.loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }
            .disabled(model.loading)
            .accessibilityLabel("Aggiorna")
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var list: some View {
        let items = model.visible(matching: filter)
        List {
            ForEach(model.failures.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                InlineErrorView(message: "\(entry.key): \(entry.value)")
                    .listRowBackground(Color.clear)
            }
            if items.isEmpty && model.loaded && !model.loading {
                Text(model.items.isEmpty ? "Non hai ancora niente nel cloud." : "Nessun file con questi filtri.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(items) { item in
                Button {
                    Task { await model.play(item, env: env) }
                } label: {
                    CloudRow(item: item, busy: model.playingID == item.id)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let link = model.link(for: item) {
                        Button {
                            UIPasteboard.general.string = link
                        } label: {
                            Label(item.directLink == nil ? "Copia il magnet" : "Copia il link", systemImage: "link")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(env: env) }
        .accessibilityIdentifier("library.cloud")
    }
}

private struct CloudRow: View {
    let item: DebridCloudItem
    let busy: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(CloudLibraryModel.displayName(item.name)).font(.headline).lineLimit(2)
                Text("\(provider) · \(item.kind.title)").font(.caption).foregroundStyle(Color.aetherSecondary)
                HStack(spacing: 6) {
                    Text(item.isReady ? "Pronto" : "In download")
                        .foregroundStyle(item.isReady ? Color.green : Color.orange)
                    if let size = item.size { Text("· " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    Text("· \(Int(item.progress * 100))%")
                }
                .font(.caption)
                .foregroundStyle(Color.aetherSecondary)
            }
            Spacer()
            if busy { ProgressView() } else { Image(systemName: item.isReady ? "play.fill" : "hourglass").foregroundStyle(Color.aetherSecondary) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var provider: String { return item.provider == "torbox" ? "TorBox" : "Real-Debrid" }
}
