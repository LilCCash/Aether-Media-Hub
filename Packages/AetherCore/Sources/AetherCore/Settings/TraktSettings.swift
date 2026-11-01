import Foundation

/// Impostazioni ▸ Trakt: cosa fare con l'account collegato.
public struct TraktSettings: Codable, Equatable, Sendable {
    /// Interruttore generale (spento di default).
    public var enabled: Bool = false
    /// Mentre guardi, dice a Trakt cosa stai guardando e quando finisci («scrobble»).
    public var scrobble: Bool = true
    /// Lista (watchlist) in comune: quello che aggiungi o togli qui lo fai anche su Trakt, e viceversa.
    public var syncWatchlist: Bool = true
    /// Cosa hai già visto: lo porta da Trakt ad Aether e viceversa.
    public var syncWatched: Bool = true
    /// Sincronizza da sola ogni volta che apri l'app.
    public var syncOnLaunch: Bool = true
    /// Cataloghi nascosti nella pagina Trakt.
    public var hiddenCatalogs: [String] = []
    /// Titoli per catalogo.
    public var itemsPerCatalog: Int = 20
    /// Mostra le liste personali nella pagina Trakt.
    public var showLists: Bool = true

    public init() {}

    public func isCatalogVisible(_ kind: TraktCatalogKind) -> Bool { return !hiddenCatalogs.contains(kind.rawValue) }

    public mutating func setCatalog(_ kind: TraktCatalogKind, visible: Bool) {
        hiddenCatalogs.removeAll { $0 == kind.rawValue }
        if !visible { hiddenCatalogs.append(kind.rawValue) }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, scrobble, syncWatchlist, syncWatched, syncOnLaunch, hiddenCatalogs, itemsPerCatalog, showLists
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: false)
        scrobble = c.value(.scrobble, default: true)
        syncWatchlist = c.value(.syncWatchlist, default: true)
        syncWatched = c.value(.syncWatched, default: true)
        syncOnLaunch = c.value(.syncOnLaunch, default: true)
        hiddenCatalogs = c.value(.hiddenCatalogs, default: [])
        itemsPerCatalog = min(50, max(5, c.value(.itemsPerCatalog, default: 20)))
        showLists = c.value(.showLists, default: true)
    }
}
