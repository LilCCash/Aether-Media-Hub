import CoreSpotlight
import UniformTypeIdentifiers
import AetherCore

/// One title in the system search.
struct SpotlightTitle: Codable, Hashable {
    var id: String
    var type: String
    var name: String
    var info: String?
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

    /// Titles the app showed (catalogs, search, what was watched): kept, up to a limit, and indexed a few seconds later.
    static func record(_ items: [MetaItem]) {
        var known = Set(seen.map { $0.id })
        var changed = false
        for item in items where !item.name.isEmpty && (item.type == "movie" || item.type == "series") && known.insert(item.id).inserted {
            seen.append(SpotlightTitle(id: item.id, type: item.type, name: item.name, info: item.releaseInfo))
            changed = true
        }
        guard changed else { return }
        if seen.count > seenLimit { seen.removeFirst(seen.count - seenLimit) }
        if let data = try? JSONEncoder().encode(seen) { UserDefaults.standard.set(data, forKey: seenKey) }
        schedule()
    }

    static func setLibrary(_ entries: [LibraryEntry]) {
        library = entries.filter { !$0.isRemoved }.map { SpotlightTitle(id: $0.id, type: $0.type, name: $0.name, info: $0.releaseInfo) }
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
            items.append(CSSearchableItem(uniqueIdentifier: "\(title.type)/\(title.id)", domainIdentifier: domain, attributeSet: attributes))
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            if !items.isEmpty { index.indexSearchableItems(items) { _ in } }
        }
    }

    /// The link `AppRouter` understands for an indexed title.
    static func url(forIdentifier identifier: String) -> URL? {
        let parts = identifier.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = parts[1].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "aether://detail/\(parts[0])/\(id)")
    }
}
