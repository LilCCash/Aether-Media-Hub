import Foundation

public struct CollectionItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: String?
    public init(id: String, type: String, name: String, poster: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
    }
}

/// A list the viewer made ("Da vedere con Marta", "Horror anni 80"…).
public struct LibraryCollection: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var items: [CollectionItem]
    public var createdAt: Date
    public init(id: String = UUID().uuidString, name: String, items: [CollectionItem] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
    }
}

public struct CollectionsSettings: Codable, Equatable, Sendable {
    public var collections: [LibraryCollection] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case collections }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collections = (try? c.decode([LibraryCollection].self, forKey: .collections)) ?? []
    }

    @discardableResult
    public mutating func create(name: String) -> LibraryCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        if let existing = collections.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { return existing }
        let made = LibraryCollection(name: trimmed)
        collections.append(made)
        return made
    }

    public mutating func rename(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40, let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = trimmed
    }

    public mutating func delete(id: String) { collections.removeAll { $0.id == id } }

    public mutating func add(_ item: CollectionItem, to id: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }), !collections[index].items.contains(where: { $0.id == item.id }) else { return }
        collections[index].items.insert(item, at: 0)
    }

    public mutating func remove(itemID: String, from id: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].items.removeAll { $0.id == itemID }
    }

    public func collections(containing itemID: String) -> [LibraryCollection] {
        return collections.filter { $0.items.contains { $0.id == itemID } }
    }
}
