import Foundation

/// The places where talk shows can be hidden, each one chosen on its own.
public enum ContentScope: String, CaseIterable, Sendable {
    case home, discover, search, cast, similar
}

/// Talk shows, recognised from the genres an addon declares ("Talk-Show", "Talk Show", "Talk") or from TMDB's genre code.
public enum TalkShowFilter {
    /// TMDB's genre code for talk shows.
    public static let tmdbGenre = 10767

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

/// What the catalogs hide for the viewer's choices, read by `AddonService` on the catalogs it returns for a place.
public final class CatalogItemFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var hidden = Set<ContentScope>()

    public init() {}

    public func setHidden(_ scopes: Set<ContentScope>) {
        lock.lock()
        hidden = scopes
        lock.unlock()
    }

    public func hides(_ scope: ContentScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hidden.contains(scope)
    }

    public func apply(_ items: [MetaItem], scope: ContentScope) -> [MetaItem] {
        return hides(scope) ? TalkShowFilter.hiding(items) : items
    }
}

/// Told about the titles the catalogs showed (the app uses it to put them in the system search).
public final class CatalogObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([MetaItem]) -> Void)?

    public init() {}

    public func set(_ new: (@Sendable ([MetaItem]) -> Void)?) {
        lock.lock()
        handler = new
        lock.unlock()
    }

    func notify(_ items: [MetaItem]) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(items)
    }
}
