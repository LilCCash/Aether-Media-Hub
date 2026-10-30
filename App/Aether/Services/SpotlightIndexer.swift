import CoreSpotlight
import UniformTypeIdentifiers
import AetherCore

/// Puts the titles of the library (watchlist and favourites) in the system search, so they can be found from the Home screen.
@MainActor
enum SpotlightIndexer {
    static let domain = "app.aether.library"

    static func reindex(_ entries: [LibraryEntry]) {
        var seen = Set<String>()
        var items: [CSSearchableItem] = []
        for entry in entries where !entry.isRemoved && seen.insert(entry.id).inserted {
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
            attributes.title = entry.name
            attributes.contentDescription = [entry.type == "movie" ? "Film" : "Serie", entry.releaseInfo].compactMap { $0 }.joined(separator: " · ")
            items.append(CSSearchableItem(uniqueIdentifier: "\(entry.type)/\(entry.id)", domainIdentifier: domain, attributeSet: attributes))
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
