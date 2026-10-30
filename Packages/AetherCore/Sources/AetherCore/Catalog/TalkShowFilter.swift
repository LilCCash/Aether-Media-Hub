import Foundation

/// Talk shows, recognised from the genres an addon declares ("Talk-Show", "Talk Show", "Talk").
public enum TalkShowFilter {
    public static func isTalkShow(_ item: MetaItem) -> Bool {
        return item.genres.contains { (genre: String) -> Bool in
            let key = GenreNames.key(genre)
            return key == "talk" || key == "talkshow" || key.hasPrefix("talk-") || key.hasPrefix("talk ")
        }
    }

    public static func hiding(_ items: [MetaItem]) -> [MetaItem] {
        return items.filter { !isTalkShow($0) }
    }
}

/// What the catalogs hide for the viewer's choices, read by `AddonService` on every catalog it returns.
public final class CatalogItemFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var talkShows = false

    public init() {}

    public var hideTalkShows: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return talkShows
        }
        set {
            lock.lock()
            talkShows = newValue
            lock.unlock()
        }
    }

    public func apply(_ items: [MetaItem]) -> [MetaItem] {
        return hideTalkShows ? TalkShowFilter.hiding(items) : items
    }
}
