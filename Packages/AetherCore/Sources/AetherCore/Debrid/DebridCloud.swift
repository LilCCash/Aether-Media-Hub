import Foundation

public enum DebridCloudKind: String, Sendable, CaseIterable {
    case torrent, web

    public var title: String { return self == .torrent ? "Torrent" : "Download web" }
}

/// Un file nel «cloud» del servizio debrid dell'utente (TorBox, Real-Debrid): quello che ha già aggiunto o scaricato lì.
public struct DebridCloudItem: Identifiable, Equatable, Sendable {
    public var id: String
    /// `torbox` o `realdebrid`.
    public var provider: String
    public var kind: DebridCloudKind
    public var name: String
    /// L'hash del torrent (serve per riprodurlo).
    public var hash: String?
    /// Il link diretto (i «download web» di Real-Debrid).
    public var directLink: String?
    public var size: Int64?
    /// 0...1.
    public var progress: Double
    /// Pronto da guardare (in cache, scaricato).
    public var isReady: Bool

    public init(id: String, provider: String, kind: DebridCloudKind, name: String, hash: String? = nil, directLink: String? = nil,
                size: Int64? = nil, progress: Double = 1, isReady: Bool = true) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.name = name
        self.hash = hash
        self.directLink = directLink
        self.size = size
        self.progress = progress
        self.isReady = isReady
    }
}

extension TorBoxClient {
    /// I torrent presenti nell'account TorBox.
    public func cloudTorrents() async throws -> [DebridCloudItem] {
        let torrents = try await myList(limit: 1000)
        return torrents.compactMap { (torrent: TorBoxTorrent) -> DebridCloudItem? in
            guard let name = torrent.name, !name.isEmpty else { return nil }
            var fraction = torrent.progress ?? (torrent.downloadFinished == true ? 1 : 0)
            if fraction > 1 { fraction /= 100 }
            let ready = torrent.downloadFinished == true || torrent.downloadPresent == true || torrent.cached == true || fraction >= 0.999
            return DebridCloudItem(id: "torbox:\(torrent.id)", provider: "torbox", kind: .torrent, name: name,
                                   hash: torrent.hash, size: torrent.size, progress: min(1, max(0, ready ? 1 : fraction)), isReady: ready)
        }
    }
}

enum RealDebridCloud {
    /// `GET /torrents` e `GET /downloads` → elementi del cloud.
    static func items(torrents: [[String: Any]], downloads: [[String: Any]]) -> [DebridCloudItem] {
        var items: [DebridCloudItem] = []
        for entry in torrents {
            guard let id = entry["id"] as? String, let name = (entry["filename"] as? String) ?? (entry["original_filename"] as? String) else { continue }
            let status = (entry["status"] as? String) ?? ""
            let percent = (entry["progress"] as? Double) ?? Double(entry["progress"] as? Int ?? 0)
            let ready = status == "downloaded"
            items.append(DebridCloudItem(id: "realdebrid:t:\(id)", provider: "realdebrid", kind: .torrent, name: name,
                                         hash: entry["hash"] as? String, size: (entry["bytes"] as? NSNumber)?.int64Value,
                                         progress: ready ? 1 : min(1, max(0, percent / 100)), isReady: ready))
        }
        for entry in downloads {
            guard let id = entry["id"] as? String, let name = entry["filename"] as? String,
                  let link = entry["download"] as? String, !link.isEmpty else { continue }
            items.append(DebridCloudItem(id: "realdebrid:d:\(id)", provider: "realdebrid", kind: .web, name: name, directLink: link,
                                         size: (entry["filesize"] as? NSNumber)?.int64Value, progress: 1, isReady: true))
        }
        return items
    }
}

extension RealDebridClient {
    /// I torrent e i download web presenti nell'account Real-Debrid.
    public func cloudItems() async throws -> [DebridCloudItem] {
        let torrents = try await cloudList(path: "/torrents?limit=100")
        let downloads = (try? await cloudList(path: "/downloads?limit=100")) ?? []
        return RealDebridCloud.items(torrents: torrents, downloads: downloads)
    }
}
