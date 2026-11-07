import Foundation

/// How much the companion may tell, from nothing that touches the story to everything the metadata knows.
public enum SpoilerLevel: Int, CaseIterable, Codable, Sendable {
    case none = 0, context = 1, deep = 2

    public var title: String {
        switch self {
        case .none: return "Nessuno spoiler"
        case .context: return "Contesto"
        case .deep: return "Approfondimenti"
        }
    }

    public var explanation: String {
        switch self {
        case .none: return "Solo chi c'è dietro e dentro il titolo e il suo posto nell'universo."
        case .context: return "In più produzione, lingue, premi e dati di uscita."
        case .deep: return "In più la trama dichiarata dall'addon, i titoli che precedono e seguono nell'universo."
        }
    }
}

public struct CompanionCard: Equatable, Identifiable, Sendable {
    public var id: String
    public var heading: String
    public var lines: [String]
    public var level: SpoilerLevel
}

/// What accompanies a viewing: facts taken from the metadata and from Aether's universes, never invented. A card appears only if
/// there is something real to say.
public enum CompanionPlanner {
    public static func cards(for meta: MetaItem, level: SpoilerLevel, watched: Set<String> = []) -> [CompanionCard] {
        var cards: [CompanionCard] = []
        func add(_ id: String, _ heading: String, _ lines: [String], _ minimum: SpoilerLevel) {
            let useful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !useful.isEmpty, level.rawValue >= minimum.rawValue else { return }
            cards.append(CompanionCard(id: id, heading: heading, lines: useful, level: minimum))
        }
        var basics: [String] = []
        if let year = meta.releaseInfo, !year.isEmpty { basics.append("Uscita: \(year)") }
        if let runtime = meta.runtime, !runtime.isEmpty { basics.append("Durata: \(runtime)") }
        if !meta.genres.isEmpty { basics.append("Genere: " + meta.genres.joined(separator: ", ")) }
        add("basics", "Il titolo", basics, .none)
        add("directors", meta.directors.count > 1 ? "Regia" : "Regista", meta.directors, .none)
        add("writers", "Sceneggiatura", meta.writers, .none)
        add("cast", "Interpreti principali", Array(meta.cast.prefix(8)), .none)

        let universes = UniverseCatalog.universes(containing: meta.id)
        var place: [String] = []
        for universe in universes {
            let release = universe.ordered(.release)
            if let index = release.firstIndex(where: { $0.id == meta.id }) {
                place.append("\(index + 1)° titolo di \(universe.name) in ordine di uscita (su \(release.count)).")
                if universe.hasChronological, let story = universe.ordered(.chronological).firstIndex(where: { $0.id == meta.id }) {
                    place.append("\(story + 1)° nell'ordine della storia (ordine editoriale, non ufficiale).")
                }
            }
        }
        add("universe", "Nel suo universo", place, .none)

        var production: [String] = []
        if let language = meta.language, !language.isEmpty { production.append("Lingua originale: \(language)") }
        if let country = meta.country, !country.isEmpty { production.append("Paese: \(country)") }
        if let awards = meta.awards, !awards.isEmpty, awards.lowercased() != "n/a" { production.append("Premi: \(awards)") }
        if let rating = meta.imdbRating, !rating.isEmpty { production.append("Valutazione IMDb: \(rating)") }
        add("production", "Produzione e premi", production, .context)

        var around: [String] = []
        for universe in universes {
            let release = universe.ordered(.release)
            guard let index = release.firstIndex(where: { $0.id == meta.id }) else { continue }
            if index > 0 { around.append("Prima: \(release[index - 1].name)\(watched.contains(release[index - 1].id) ? " (visto)" : "")") }
            if index + 1 < release.count { around.append("Dopo: \(release[index + 1].name)\(watched.contains(release[index + 1].id) ? " (visto)" : "")") }
        }
        add("around", "Prima e dopo", around, .deep)
        if let plot = meta.description, !plot.isEmpty { add("plot", "Trama (da addon)", [plot], .deep) }
        return cards
    }
}
