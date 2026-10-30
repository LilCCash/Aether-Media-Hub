import CoreSpotlight
import UIKit
import UniformTypeIdentifiers
import AetherCore

/// One title in the system search.
struct SpotlightTitle: Codable, Hashable {
    var id: String
    var type: String
    var name: String
    var info: String?
    var poster: String?
    var background: String?
}

/// Puts titles in the system search so they can be found from the Home screen: the library (watchlist, favourites), what was watched, and the
/// last few hundred titles the app showed (the newest drop out first). Only on the phone; nothing is sent anywhere.
@MainActor
enum SpotlightIndexer {
    static let domain = "app.aether.library"
    private static let seenKey = "aether.spotlight.seen.v1"
    private static let seenLimit = 500
    private static var seen: [SpotlightTitle] = {
        guard let data = UserDefaults.standard.data(forKey: SpotlightIndexer.seenKey),
              let decoded = try? JSONDecoder().decode([SpotlightTitle].self, from: data) else { return [] }
        return decoded
    }()
    private static var library: [SpotlightTitle] = []
    private static var pending: Task<Void, Never>?
    /// Posters that could not be fetched: not asked for again until the app is reopened.
    private static var failedPosters = Set<String>()
    private static let posterDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("spotlight-posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func posterFile(_ id: String) -> URL {
        let name = id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return posterDirectory.appendingPathComponent(name + ".jpg")
    }

    /// Titles the app showed (catalogs, search, what was watched): kept, up to a limit, and indexed a few seconds later.
    static func record(_ items: [MetaItem]) {
        var changed = false
        for item in items where !item.name.isEmpty && (item.type == "movie" || item.type == "series") {
            if let index = seen.firstIndex(where: { $0.id == item.id }) {
                if seen[index].poster == nil, let poster = item.poster {
                    seen[index].poster = poster
                    changed = true
                }
                if seen[index].background == nil, let background = item.background {
                    seen[index].background = background
                    changed = true
                }
                continue
            }
            seen.append(SpotlightTitle(id: item.id, type: item.type, name: item.name, info: item.releaseInfo, poster: item.poster, background: item.background))
            changed = true
        }
        guard changed else { return }
        if seen.count > seenLimit { seen.removeFirst(seen.count - seenLimit) }
        if let data = try? JSONEncoder().encode(seen) { UserDefaults.standard.set(data, forKey: seenKey) }
        schedule()
    }

    static func setLibrary(_ entries: [LibraryEntry]) {
        library = entries.filter { !$0.isRemoved }.map { SpotlightTitle(id: $0.id, type: $0.type, name: $0.name, info: $0.releaseInfo, poster: $0.poster, background: $0.background) }
        schedule()
    }

    private static func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { reindexNow() }
        }
    }

    private static func reindexNow() {
        var ids = Set<String>()
        var items: [CSSearchableItem] = []
        for title in library + seen.reversed() where ids.insert(title.id).inserted {
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
            attributes.title = title.name
            attributes.contentDescription = [title.type == "movie" ? "Film" : "Serie", title.info].compactMap { $0 }.joined(separator: " · ")
            // Spotlight matches words: "Spider-Man" must also be found as "Spiderman" or "Spider Man".
            attributes.keywords = Array(Set([title.name, title.name.replacingOccurrences(of: "-", with: ""),
                                             title.name.replacingOccurrences(of: "-", with: " ")]))
            let file = posterFile(title.id)
            if FileManager.default.fileExists(atPath: file.path) { attributes.thumbnailURL = file }
            items.append(CSSearchableItem(uniqueIdentifier: "\(title.type)/\(title.id)", domainIdentifier: domain, attributeSet: attributes))
        }
        fetchMissingPosters(for: library + seen.reversed())
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            if !items.isEmpty { index.indexSearchableItems(items) { _ in } }
        }
    }

    /// Downloads the posters the index does not have yet (small JPEGs, a few at a time); when some arrive the index is made again with them.
    private static func fetchMissingPosters(for titles: [SpotlightTitle]) {
        var jobs: [(id: String, remote: URL, file: URL)] = []
        for title in titles where jobs.count < 40 {
            let file = posterFile(title.id)
            guard !FileManager.default.fileExists(atPath: file.path), !failedPosters.contains(title.id),
                  let address = PosterOverrides.shared.url(for: title.id) ?? title.poster, let remote = URL(string: address) else { continue }
            jobs.append((title.id, remote, file))
        }
        guard !jobs.isEmpty else { return }
        let work = jobs
        Task.detached(priority: .utility) {
            var arrived = false
            for job in work {
                if let (data, _) = try? await URLSession.shared.data(from: job.remote), let image = UIImage(data: data),
                   let small = image.preparingThumbnail(of: CGSize(width: 200, height: 300)), let jpeg = small.jpegData(compressionQuality: 0.7),
                   (try? jpeg.write(to: job.file)) != nil {
                    arrived = true
                } else {
                    await MainActor.run { _ = failedPosters.insert(job.id) }
                }
            }
            if arrived { await MainActor.run { schedule() } }
        }
    }

    /// The title page for an indexed title, with what is known about it already (name, poster) so it does not open empty. The stored backdrop is not used: until the real page arrives the poster, blurred, fills the header.
    static func route(forIdentifier identifier: String) -> MetaRoute? {
        let parts = identifier.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let known = (library + seen).first { $0.id == parts[1] }
        let preview = known.map { MetaItem(id: $0.id, type: parts[0], name: $0.name, poster: $0.poster, releaseInfo: $0.info) }
        return MetaRoute(type: parts[0], id: parts[1], preview: preview)
    }
}
