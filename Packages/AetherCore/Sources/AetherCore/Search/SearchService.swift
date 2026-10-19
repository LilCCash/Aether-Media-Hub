import Foundation

public struct SearchRow: Identifiable, Sendable {
    public var ref: CatalogRef
    public var items: [MetaItem]
    public var error: AddonError?
    public var isStale: Bool

    public var id: String { return ref.id }
}

public struct SearchUpdate: Sendable {
    public var row: SearchRow
    public var completed: Int
    public var total: Int
}

public enum SearchSort: String, CaseIterable, Codable, Sendable {
    case relevance
    case title
    case yearDescending
    case ratingDescending

    public var title: String {
        switch self {
        case .relevance: return "Rilevanza"
        case .title: return "Titolo"
        case .yearDescending: return "Anno"
        case .ratingDescending: return "Valutazione"
        }
    }

    public func apply(to items: [MetaItem]) -> [MetaItem] {
        switch self {
        case .relevance:
            return items
        case .title:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .yearDescending:
            return items.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .ratingDescending:
            return items.sorted { ($0.ratingValue ?? 0) > ($1.ratingValue ?? 0) }
        }
    }
}

/// Remote search across every installed catalog that declares the `search` extra.
/// Nothing is pretended: if no catalog supports search, `searchableCatalogs` is empty and the UI says so.
public final class SearchService: Sendable {
    private let service: AddonService

    public init(service: AddonService) {
        self.service = service
    }

    public func searchableCatalogs(type: String? = nil) async -> [CatalogRef] {
        return RequestPlanner.searchCatalogs(handles: await service.handles(), type: type)
    }

    public static func normalisedQuery(_ raw: String) -> String {
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Streams one row per catalog as soon as that catalog answers. Cancelling the consumer cancels the requests,
    /// which is how superseded queries (typing fast) are abandoned.
    public func search(query rawQuery: String, type: String? = nil, perCatalogLimit: Int = 40) -> AsyncStream<SearchUpdate> {
        let query = SearchService.normalisedQuery(rawQuery)
        return AsyncStream { continuation in
            guard !query.isEmpty else {
                continuation.finish()
                return
            }
            let task = Task {
                let refs = RequestPlanner.searchCatalogs(handles: await self.service.handles(), type: type)
                let total = refs.count
                if total == 0 {
                    continuation.finish()
                    return
                }
                var completed = 0
                await withTaskGroup(of: SearchRow.self) { group in
                    for ref in refs {
                        group.addTask { [service = self.service] in
                            do {
                                let result = try await service.catalog(
                                    ref, extra: [ExtraValue(name: "search", value: query)])
                                let items = Array(result.items.prefix(perCatalogLimit))
                                return SearchRow(ref: ref, items: items, error: nil, isStale: result.isStale)
                            } catch {
                                return SearchRow(ref: ref, items: [], error: AddonService.normalise(error), isStale: false)
                            }
                        }
                    }
                    for await row in group {
                        completed += 1
                        continuation.yield(SearchUpdate(row: row, completed: completed, total: total))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Recognises the same title coming from different addons / id schemes.
public enum MetaDeduper {
    /// Lowercased, diacritics stripped, punctuation removed, whitespace collapsed.
    public static func normalise(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        var lastWasSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// IMDb ids are authoritative. Otherwise type + normalised title (+ year when known).
    public static func key(for item: MetaItem) -> String {
        if let imdb = item.imdbID { return "imdb:\(imdb)" }
        return titleKey(item)
    }

    static func titleKey(_ item: MetaItem) -> String {
        let title = normalise(item.name)
        if let year = item.year { return "title:\(item.type)|\(title)|\(year)" }
        return "title:\(item.type)|\(title)"
    }

    /// Keeps the first occurrence, filling its empty fields from later duplicates. Two items are the same work when
    /// they share an IMDb id, or the same type + normalised title + year — unless both carry *different* IMDb ids.
    public static func dedupe(_ items: [MetaItem]) -> [MetaItem] {
        var slots: [MetaItem] = []
        var imdbIndex: [String: Int] = [:]
        var titleIndex: [String: Int] = [:]
        for item in items {
            let imdb = item.imdbID
            let title = titleKey(item)
            var slot: Int?
            if let imdb = imdb, let found = imdbIndex[imdb] {
                slot = found
            } else if let found = titleIndex[title] {
                let existingIMDb = slots[found].imdbID
                if existingIMDb == nil || imdb == nil || existingIMDb == imdb {
                    slot = found
                }
            }
            if let slot = slot {
                slots[slot] = slots[slot].merging(fallback: item)
                if let imdb = imdb, imdbIndex[imdb] == nil { imdbIndex[imdb] = slot }
                if titleIndex[title] == nil { titleIndex[title] = slot }
            } else {
                slots.append(item)
                let index = slots.count - 1
                if let imdb = imdb { imdbIndex[imdb] = index }
                if titleIndex[title] == nil { titleIndex[title] = index }
            }
        }
        return slots
    }

    /// Round-robin across rows so one chatty addon does not bury the others, then de-duplicated.
    public static func interleave(_ rows: [[MetaItem]]) -> [MetaItem] {
        var merged: [MetaItem] = []
        var index = 0
        var added = true
        while added {
            added = false
            for row in rows where index < row.count {
                merged.append(row[index])
                added = true
            }
            index += 1
        }
        return dedupe(merged)
    }
}
