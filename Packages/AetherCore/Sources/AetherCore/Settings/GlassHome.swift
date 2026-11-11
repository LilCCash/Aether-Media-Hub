import Foundation

/// The two Homes the viewer can choose between (Impostazioni ▸ Aspetto ▸ Personalizza la Home).
public enum HomeLayout: String, Codable, CaseIterable, Sendable {
    /// The Home of Aether 2.0: the featured carousel and the rows.
    case classic
    /// «Vetrina»: a header with the name and the profile picture, the search field, the categories and the rows on glass cards. The
    /// bar at the bottom becomes Home, Libreria, Impostazioni (and Cerca apart); the profile opens from the picture.
    case glass

    public var title: String {
        switch self {
        case .classic: return "Classica"
        case .glass: return "Vetrina"
        }
    }
}

/// A shortcut of the glass Home: a content type of Scopri, or Live TV.
public struct HomeCategory: Codable, Hashable, Identifiable, Sendable {
    /// `movie`, `series`, `anime`… (a content type that Scopri opens on) or `live` (Live TV).
    public var id: String
    public var title: String
    public var symbol: String
    public var isVisible: Bool

    public init(id: String, title: String, symbol: String, isVisible: Bool = true) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.isVisible = isVisible
    }

    private enum CodingKeys: String, CodingKey { case id, title, symbol, isVisible }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decode(String.self, forKey: .id)
        id = key
        let fallback = HomeCategory.available.first { $0.id == key }
        title = (try? c.decode(String.self, forKey: .title)) ?? fallback?.title ?? id
        symbol = (try? c.decode(String.self, forKey: .symbol)) ?? fallback?.symbol ?? "square.grid.2x2"
        isVisible = c.value(.isVisible, default: true)
    }

    public static let live = "live"

    /// Live TV, or a content type of Scopri.
    public var opensLiveTV: Bool { return id == HomeCategory.live }

    public static let defaults: [HomeCategory] = [
        HomeCategory(id: ContentType.movie, title: "Film", symbol: "film.stack"),
        HomeCategory(id: ContentType.series, title: "Serie TV", symbol: "tv"),
        HomeCategory(id: ContentType.anime, title: "Anime", symbol: "sparkles"),
        HomeCategory(id: HomeCategory.live, title: "Live TV", symbol: "antenna.radiowaves.left.and.right"),
    ]

    /// Every destination a category can have (the ones not in the defaults are added hidden, ready to be switched on).
    public static let available: [HomeCategory] = defaults + [
        HomeCategory(id: ContentType.tv, title: "TV in diretta", symbol: "play.tv", isVisible: false),
        HomeCategory(id: "sports", title: "Sport", symbol: "sportscourt", isVisible: false),
        HomeCategory(id: "events", title: "Eventi", symbol: "calendar", isVisible: false),
        HomeCategory(id: ContentType.channel, title: "Canali", symbol: "play.rectangle", isVisible: false),
    ]

    /// Symbols the viewer can choose for a category.
    public static let symbols: [String] = [
        "film.stack", "film", "tv", "play.tv", "sparkles", "antenna.radiowaves.left.and.right", "sportscourt", "soccerball",
        "trophy", "calendar", "play.rectangle", "popcorn", "theatermasks", "star", "heart", "music.note", "gamecontroller",
        "figure.and.child.holdinghands", "globe", "bolt",
    ]

    /// Known destinations only, each once, in the stored order; destinations added in a later version are appended (hidden).
    public static func normalise(_ stored: [HomeCategory]) -> [HomeCategory] {
        let known = Set(available.map { $0.id })
        var seen = Set<String>()
        var result: [HomeCategory] = []
        for var category in stored where known.contains(category.id) && seen.insert(category.id).inserted {
            category.title = String(category.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            if category.title.isEmpty { category.title = available.first { $0.id == category.id }?.title ?? category.id }
            result.append(category)
        }
        for category in available where !seen.contains(category.id) {
            var added = category
            if !stored.isEmpty { added.isVisible = false }
            result.append(added)
        }
        return result
    }
}

/// What the glass Home shows: its header, and its sections (the classic ones plus the search field and the categories), in the
/// viewer's order.
public struct GlassHomeSettings: Codable, Equatable, Sendable {
    public var showLogo: Bool = true
    public var showAvatar: Bool = true
    /// «Ciao!» and «Cosa vuoi guardare oggi?» under the header.
    public var showGreeting: Bool = true
    public var categories: [HomeCategory] = HomeCategory.normalise([])
    public var sections: [HomeSectionConfig] = GlassHomeSettings.defaultSections

    public static let search = "search"
    public static let categoriesID = "categories"

    public static let defaultSections: [HomeSectionConfig] = [
        HomeSectionConfig(id: search), HomeSectionConfig(id: categoriesID), HomeSectionConfig(id: HomeSectionConfig.hero, isVisible: false),
        HomeSectionConfig(id: HomeSectionConfig.continueWatching), HomeSectionConfig(id: HomeSectionConfig.nextUp),
        HomeSectionConfig(id: HomeSectionConfig.forYou), HomeSectionConfig(id: HomeSectionConfig.watchlist),
        HomeSectionConfig(id: HomeSectionConfig.catalogs), HomeSectionConfig(id: HomeSectionConfig.universes),
    ]

    public init() {}

    private enum CodingKeys: String, CodingKey { case showLogo, showAvatar, showGreeting, categories, sections }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showLogo = c.value(.showLogo, default: true)
        showAvatar = c.value(.showAvatar, default: true)
        showGreeting = c.value(.showGreeting, default: true)
        categories = HomeCategory.normalise(c.lossyArray(HomeCategory.self, forKey: .categories))
        sections = GlassHomeSettings.normalise(c.lossyArray(HomeSectionConfig.self, forKey: .sections))
    }

    public static func title(for id: String) -> String {
        switch id {
        case search: return "Barra di ricerca"
        case categoriesID: return "Categorie"
        default: return HomeSectionConfig.title(for: id)
        }
    }

    /// Known sections, each once, in the stored order; sections added in a later version come at the end.
    public static func normalise(_ stored: [HomeSectionConfig]) -> [HomeSectionConfig] {
        let known = Set(defaultSections.map { $0.id })
        var seen = Set<String>()
        var result: [HomeSectionConfig] = []
        for var section in stored where known.contains(section.id) && seen.insert(section.id).inserted {
            if let style = section.style, !HomeCardStyle.allowed(for: section.id).contains(style) { section.style = nil }
            result.append(section)
        }
        for section in defaultSections where !seen.contains(section.id) { result.append(section) }
        return result
    }
}
