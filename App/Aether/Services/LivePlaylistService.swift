import Foundation
import AetherCore

/// The M3U playlists the viewer added: downloads them, keeps the channels on disk and tells how it went. A playlist added from a file has
/// no address: its channels are the cache itself.
@MainActor
final class LivePlaylistService: ObservableObject {
    @Published private(set) var channels: [UUID: [M3UChannel]] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published private(set) var messages: [UUID: String] = [:]
    @Published private(set) var updated: [UUID: Date] = [:]

    private let directory: URL
    private static let maxBytes = 30 * 1024 * 1024

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("LiveTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ id: UUID) -> URL { return directory.appendingPathComponent(id.uuidString + ".json") }
    private func guidesFile(_ id: UUID) -> URL { return directory.appendingPathComponent(id.uuidString + ".guides.json") }

    /// The TV guides the playlists announce in their header (`url-tvg`), in the order of the playlists.
    func announcedGuides(_ playlists: [LivePlaylist]) -> [String] {
        var all: [String] = []
        for playlist in playlists {
            guard let data = try? Data(contentsOf: guidesFile(playlist.id)), let list = try? JSONDecoder().decode([String].self, from: data) else { continue }
            for address in list where !all.contains(address) { all.append(address) }
        }
        return all
    }

    /// The channels of the playlist: from memory, else from the cache on disk.
    func cached(_ id: UUID) -> [M3UChannel] {
        if let known = channels[id] { return known }
        guard let data = try? Data(contentsOf: file(id)), let list = try? JSONDecoder().decode([M3UChannel].self, from: data) else { return [] }
        channels[id] = list
        updated[id] = (try? FileManager.default.attributesOfItem(atPath: file(id).path)[.modificationDate]) as? Date
        return list
    }

    /// Downloads the playlist again (or, when `force` is false, only when there is nothing in the cache).
    func load(_ playlist: LivePlaylist, force: Bool = false) async {
        if !force, !cached(playlist.id).isEmpty { return }
        guard let text = playlist.url, let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        guard !loading.contains(playlist.id) else { return }
        loading.insert(playlist.id)
        messages[playlist.id] = nil
        defer { loading.remove(playlist.id) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Aether", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                messages[playlist.id] = "Il server ha risposto con un errore."
                return
            }
            guard data.count <= Self.maxBytes else {
                messages[playlist.id] = "La lista è troppo grande (oltre 30 MB)."
                return
            }
            store(parse(data), for: playlist.id)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            messages[playlist.id] = "iOS blocca gli indirizzi non cifrati (http): usa un indirizzo https."
        } catch {
            messages[playlist.id] = "Download non riuscito: \(error.localizedDescription)"
        }
    }

    /// A playlist from the text of a file.
    func importText(_ data: Data, into id: UUID) {
        store(parse(data), for: id)
    }

    func remove(_ id: UUID) {
        channels[id] = nil
        messages[id] = nil
        updated[id] = nil
        try? FileManager.default.removeItem(at: file(id))
        try? FileManager.default.removeItem(at: guidesFile(id))
    }

    private func parse(_ data: Data) -> M3UParseResult {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return M3UParser.parse(text)
    }

    private func store(_ result: M3UParseResult, for id: UUID) {
        guard !result.channels.isEmpty else {
            messages[id] = "Non ho trovato canali in questa lista (servono indirizzi http o https)."
            return
        }
        channels[id] = result.channels
        updated[id] = Date()
        if let data = try? JSONEncoder().encode(result.channels) { try? data.write(to: file(id), options: .atomic) }
        if let data = try? JSONEncoder().encode(result.guides) { try? data.write(to: guidesFile(id), options: .atomic) }
        messages[id] = result.skipped > 0 ? "\(result.skipped) canali ignorati (indirizzo non supportato)." : nil
    }
}
