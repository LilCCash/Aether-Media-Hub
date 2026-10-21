import Foundation

// The user's own order and visibility of the content types shown in Discover. The list of types itself is dynamic
// (it comes from the installed addons, see `CatalogCapabilities`), so the stored setting must survive addons coming
// and going: an entry for a type nobody serves right now is kept (reinstalling the addon restores the choice) but
// never shown, and a type seen for the first time is appended, visible.

// MARK: - Persisted setting

/// One persisted entry: a type id (`ContentTypes.canonicalID`) and whether the user wants it in Discover.
///
/// Decoding is lenient like `AppSettings`: a missing or malformed `isVisible` means visible; an entry without a
/// usable `id` fails to decode, so `lossyArray` drops it instead of invalidating the whole list.
public struct DiscoverTypeSetting: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var isVisible: Bool

    public init(id: String, isVisible: Bool = true) {
        self.id = id
        self.isVisible = isVisible
    }

    private enum CodingKeys: String, CodingKey {
        case id, isVisible
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let rawID = container.flexString(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "type id"))
        }
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "blank type id"))
        }
        self.id = trimmed
        self.isVisible = container.flexBool(.isVisible) ?? true
    }
}

// MARK: - Resolved layout

/// A stored layout reconciled with the types available right now.
///
/// `entries` is what to persist back: it keeps entries of types that are not available at the moment. Everything the
/// UI shows comes from `exposed` and `visibleTypes`, which only contain available types.
public struct DiscoverLayoutState: Equatable, Sendable {
    /// The full list in the user's order, unavailable types included. Persist this.
    public private(set) var entries: [DiscoverTypeSetting]
    /// Canonical ids of the types available right now.
    public private(set) var availableIDs: Set<String>

    public init(entries: [DiscoverTypeSetting], availableIDs: Set<String>) {
        self.entries = entries
        self.availableIDs = availableIDs
    }

    /// Available types in the user's order, hidden ones included (what a settings screen lists).
    public var exposed: [DiscoverTypeSetting] {
        return entries.filter { (entry: DiscoverTypeSetting) -> Bool in availableIDs.contains(entry.id) }
    }

    /// Available types the user wants to see, in the user's order (what Discover's chip row shows).
    public var visibleTypes: [String] {
        var result: [String] = []
        for entry in entries where entry.isVisible && availableIDs.contains(entry.id) {
            result.append(entry.id)
        }
        return result
    }

    /// Some types are available but the user hid all of them: Discover has nothing to show and should say why.
    public var isEverythingHidden: Bool {
        return !availableIDs.isEmpty && visibleTypes.isEmpty
    }

    public func isAvailable(_ type: String) -> Bool {
        return availableIDs.contains(ContentTypes.canonicalID(type))
    }

    /// True when the type is available and not hidden by the user.
    public func isVisible(_ type: String) -> Bool {
        let key = ContentTypes.canonicalID(type)
        if !availableIDs.contains(key) { return false }
        for entry in entries where entry.id == key {
            return entry.isVisible
        }
        return false
    }

    /// Shows or hides a type. Works for types that are not available right now too, so a choice is never lost.
    public mutating func setVisible(_ visible: Bool, for type: String) {
        let key = ContentTypes.canonicalID(type)
        for index in entries.indices where entries[index].id == key {
            entries[index].isVisible = visible
        }
    }

    /// Reorders the available types with the semantics of `List.onMove`: the elements at `source` (offsets into
    /// `exposed`) end up before `destination` (an offset into `exposed` as it was before the move).
    /// Entries of unavailable types keep their place relative to the types around them.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var order = exposed
        let sortedSource: [Int] = source.sorted()
        let count = order.count
        let validSource: [Int] = sortedSource.filter { (index: Int) -> Bool in index >= 0 && index < count }
        if validSource.isEmpty { return }

        var moving: [DiscoverTypeSetting] = []
        for index in validSource {
            moving.append(order[index])
        }
        for index in validSource.reversed() {
            order.remove(at: index)
        }
        let removedBefore = validSource.filter { (index: Int) -> Bool in index < destination }.count
        let target = max(0, min(order.count, destination - removedBefore))
        order.insert(contentsOf: moving, at: target)

        var rebuilt: [DiscoverTypeSetting] = []
        var cursor = 0
        for entry in entries {
            if availableIDs.contains(entry.id) && cursor < order.count {
                rebuilt.append(order[cursor])
                cursor += 1
            } else {
                rebuilt.append(entry)
            }
        }
        entries = rebuilt
    }
}

// MARK: - Normalisation

public enum DiscoverLayout {
    /// Reconciles the stored setting with the types available now.
    ///
    /// - The user's order and visibility are kept; ids are folded with `ContentTypes.canonicalID`, so "Sport" and
    ///   "sports" are the same entry (the first one in the stored list wins). Blank ids are dropped.
    /// - A type available now but absent from `stored` is appended, visible, in canonical order.
    /// - A stored type that is not available now stays in `entries` (reinstalling an addon restores the choice) but
    ///   is left out of `exposed` and `visibleTypes`.
    ///
    /// - Parameters:
    ///   - stored: the persisted list; empty on first launch.
    ///   - available: type ids Discover can serve, e.g. `capabilities.availableTypes.map { $0.id }`; any spelling.
    public static func normalise(stored: [DiscoverTypeSetting], available: [String]) -> DiscoverLayoutState {
        var availableIDs = Set<String>()
        var availableOrdered: [String] = []
        for raw in available {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let key = ContentTypes.canonicalID(trimmed)
            if availableIDs.insert(key).inserted {
                availableOrdered.append(key)
            }
        }

        var entries: [DiscoverTypeSetting] = []
        var seen = Set<String>()
        for item in stored {
            let trimmed = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let key = ContentTypes.canonicalID(trimmed)
            if seen.insert(key).inserted {
                entries.append(DiscoverTypeSetting(id: key, isVisible: item.isVisible))
            }
        }

        var newcomers: [String] = []
        for key in availableOrdered where !seen.contains(key) {
            newcomers.append(key)
        }
        for key in ContentTypes.sorted(newcomers) {
            entries.append(DiscoverTypeSetting(id: key, isVisible: true))
        }
        return DiscoverLayoutState(entries: entries, availableIDs: availableIDs)
    }

    /// Shortcut for `normalise(stored:available:).visibleTypes`.
    public static func visibleTypes(stored: [DiscoverTypeSetting], available: [String]) -> [String] {
        return normalise(stored: stored, available: available).visibleTypes
    }

    /// Which type Discover should select: `current` while it is still visible, otherwise the first visible one.
    /// Nil when nothing is visible.
    public static func resolveSelection(current: String?, visible: [String]) -> String? {
        if let current = current {
            let key = ContentTypes.canonicalID(current)
            for candidate in visible where ContentTypes.canonicalID(candidate) == key {
                return candidate
            }
        }
        return visible.first
    }
}
