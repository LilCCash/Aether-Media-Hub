import Foundation

/// A title that belongs to an universe: its IMDb id (the id the addons use), the name, the year and whether it is a series.
public struct UniverseEntry: Hashable, Identifiable, Sendable, Codable {
    public var id: String
    public var name: String
    public var year: Int
    public var isSeries: Bool
    public var type: String { return isSeries ? "series" : "movie" }
    public init(id: String, name: String, year: Int, isSeries: Bool) {
        self.id = id
        self.name = name
        self.year = year
        self.isSeries = isSeries
    }
}

/// How sure we are about an order of viewing.
public enum UniverseOrderTrust: String, Sendable, Codable {
    /// The order the titles came out: a fact.
    case release
    /// Rebuilt from the stories by editors: the notes of the universe say so.
    case editorial
    /// The viewer's own.
    case custom

    public var label: String {
        switch self {
        case .release: return "Ordine di uscita (dato certo)"
        case .editorial: return "Ordine editoriale (ricostruito, non ufficiale)"
        case .custom: return "Ordine personalizzato"
        }
    }
}

public enum UniverseOrder: String, CaseIterable, Sendable, Codable {
    case release, chronological, custom
    public var title: String {
        switch self {
        case .release: return "Ordine di uscita"
        case .chronological: return "Ordine cronologico"
        case .custom: return "Il mio ordine"
        }
    }
}

public struct UniverseDefinition: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    /// The IMDb id of the title whose artwork opens the universe page.
    public var hero: String
    /// In order of release.
    public var entries: [UniverseEntry]
    /// Ids in the order of the story; titles not listed follow in order of release. Nil = same as release.
    public var chronological: [String]?
    public var chronologicalNote: String?

    init(id: String, name: String, summary: String, hero: String, entries: [(String, String, Int, Bool)], chronological: [String]?, chronologicalNote: String?) {
        self.id = id
        self.name = name
        self.summary = summary
        self.hero = hero
        self.entries = entries.map { UniverseEntry(id: $0.0, name: $0.1, year: $0.2, isSeries: $0.3) }
        self.chronological = chronological
        self.chronologicalNote = chronologicalNote
    }

    public var films: [UniverseEntry] { return entries.filter { !$0.isSeries } }
    public var series: [UniverseEntry] { return entries.filter { $0.isSeries } }
    public var hasChronological: Bool { return chronological != nil }
    public var years: ClosedRange<Int>? {
        guard let low = entries.map({ $0.year }).min(), let high = entries.map({ $0.year }).max() else { return nil }
        return low...high
    }

    /// The titles in the chosen order. A custom order lists what the viewer arranged; titles added later to the universe follow.
    public func ordered(_ order: UniverseOrder, custom: [String]? = nil) -> [UniverseEntry] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        func complete(_ ids: [String]) -> [UniverseEntry] {
            var seen = Set<String>()
            var result: [UniverseEntry] = []
            for id in ids {
                if let entry = byID[id], seen.insert(id).inserted { result.append(entry) }
            }
            for entry in entries where seen.insert(entry.id).inserted { result.append(entry) }
            return result
        }
        switch order {
        case .release: return entries
        case .chronological: return complete(chronological ?? entries.map { $0.id })
        case .custom: return complete(custom ?? entries.map { $0.id })
        }
    }

    public func trust(of order: UniverseOrder) -> UniverseOrderTrust {
        switch order {
        case .release: return .release
        case .chronological: return chronological == nil ? .release : .editorial
        case .custom: return .custom
        }
    }
}

/// How far the viewer is in an universe.
public struct UniverseProgress: Equatable, Sendable {
    public var watched: Int
    public var total: Int
    public var next: UniverseEntry?
    public var missing: [UniverseEntry]

    public var fraction: Double { return total == 0 ? 0 : Double(watched) / Double(total) }
    public var percent: Int { return Int((fraction * 100).rounded()) }
    public var isComplete: Bool { return total > 0 && watched == total }

    public static func compute(_ universe: UniverseDefinition, order: UniverseOrder, custom: [String]? = nil, watchedIDs: Set<String>) -> UniverseProgress {
        let ordered = universe.ordered(order, custom: custom)
        let missing = ordered.filter { !watchedIDs.contains($0.id) }
        return UniverseProgress(watched: ordered.count - missing.count, total: ordered.count, next: missing.first, missing: missing)
    }
}

/// The viewer's choices about universes: the order they arranged, and the ones they follow.
public struct UniverseSettings: Codable, Equatable, Sendable {
    public var customOrders: [String: [String]] = [:]
    public var followed: [String] = []
    public var lastOrder: [String: UniverseOrder] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey { case customOrders, followed, lastOrder }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customOrders = (try? c.decode([String: [String]].self, forKey: .customOrders)) ?? [:]
        followed = (try? c.decode([String].self, forKey: .followed)) ?? []
        lastOrder = (try? c.decode([String: UniverseOrder].self, forKey: .lastOrder)) ?? [:]
    }

    public mutating func toggleFollow(_ id: String) {
        if let index = followed.firstIndex(of: id) { followed.remove(at: index) } else { followed.append(id) }
    }
}

public enum UniverseCatalog {
    public static func universe(id: String) -> UniverseDefinition? { return all.first { $0.id == id } }

    /// The universes an IMDb id belongs to (a title may be in more than one).
    public static func universes(containing imdbID: String) -> [UniverseDefinition] {
        return all.filter { universe in universe.entries.contains { $0.id == imdbID } }
    }

    /// Universes whose name, or one of whose titles, contains the words (case and accents ignored), the name matches first.
    public static func search(_ text: String) -> [UniverseDefinition] {
        func fold(_ s: String) -> String { return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")) }
        let needle = fold(text).trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        let byName = all.filter { fold($0.name).contains(needle) || fold($0.id) == needle }
        let byTitle = all.filter { universe in !byName.contains(universe) && universe.entries.contains { fold($0.name).contains(needle) } }
        return byName + byTitle
    }

    /// The titles of the data below were matched one by one against Cinemeta (name and year); the orders of the story are editorial.
    public static let all: [UniverseDefinition] = [
    UniverseDefinition(id: "mcu", name: "Marvel Cinematic Universe", summary: "Il grande universo condiviso di supereroi: dagli Avengers ai Guardiani, dal multiverso agli spin-off in serie.", hero: "tt4154796",
        entries: [
            ("tt0371746", "Iron Man", 2008, false),
            ("tt0800080", "The Incredible Hulk", 2008, false),
            ("tt1228705", "Iron Man 2", 2010, false),
            ("tt0800369", "Thor", 2011, false),
            ("tt0458339", "Captain America: The First Avenger", 2011, false),
            ("tt0848228", "The Avengers", 2012, false),
            ("tt1300854", "Iron Man 3", 2013, false),
            ("tt1981115", "Thor: The Dark World", 2013, false),
            ("tt1843866", "Captain America: The Winter Soldier", 2014, false),
            ("tt2015381", "Guardians of the Galaxy", 2014, false),
            ("tt2395427", "Avengers: Age of Ultron", 2015, false),
            ("tt0478970", "Ant-Man", 2015, false),
            ("tt3498820", "Captain America: Civil War", 2016, false),
            ("tt1211837", "Doctor Strange", 2016, false),
            ("tt3896198", "Guardians of the Galaxy: Vol. 2", 2017, false),
            ("tt2250912", "Spider-Man: Homecoming", 2017, false),
            ("tt3501632", "Thor: Ragnarok", 2017, false),
            ("tt1825683", "Black Panther", 2018, false),
            ("tt4154756", "Avengers: Infinity War", 2018, false),
            ("tt5095030", "Ant-Man and the Wasp", 2018, false),
            ("tt4154664", "Captain Marvel", 2019, false),
            ("tt4154796", "Avengers: Endgame", 2019, false),
            ("tt6320628", "Spider-Man: Far from Home", 2019, false),
            ("tt3480822", "Black Widow", 2021, false),
            ("tt9376612", "Shang-Chi and the Legend of the Ten Rings", 2021, false),
            ("tt9032400", "Eternals", 2021, false),
            ("tt10872600", "Spider-Man: No Way Home", 2021, false),
            ("tt9419884", "Doctor Strange in the Multiverse of Madness", 2022, false),
            ("tt10648342", "Thor: Love and Thunder", 2022, false),
            ("tt9114286", "Black Panther: Wakanda Forever", 2022, false),
            ("tt10954600", "Ant-Man and the Wasp: Quantumania", 2023, false),
            ("tt6791350", "Guardians of the Galaxy Vol. 3", 2023, false),
            ("tt10676048", "The Marvels", 2023, false),
            ("tt6263850", "Deadpool & Wolverine", 2024, false),
            ("tt14513804", "Captain America: Brave New World", 2025, false),
            ("tt20969586", "Thunderbolts*", 2025, false),
            ("tt9140560", "WandaVision", 2021, true),
            ("tt9208876", "The Falcon and the Winter Soldier", 2021, true),
            ("tt9140554", "Loki", 2021, true),
            ("tt10168312", "What If...?", 2021, true),
            ("tt10160804", "Hawkeye", 2021, true),
            ("tt10234724", "Moon Knight", 2022, true),
            ("tt10857164", "Ms. Marvel", 2022, true),
            ("tt10857160", "She Hulk: Attorney at Law", 2022, true),
            ("tt13157618", "Secret Invasion", 2023, true),
            ("tt15571732", "Agatha All Along", 2024, true),
        ],
        chronological: ["tt0458339", "tt4154664", "tt0371746", "tt1228705", "tt0800080", "tt0800369", "tt0848228", "tt1981115", "tt1300854", "tt1843866", "tt2015381", "tt3896198", "tt2395427", "tt0478970", "tt3498820", "tt3480822", "tt1825683", "tt2250912", "tt3501632", "tt1211837", "tt4154756", "tt5095030", "tt4154796", "tt9140560", "tt6320628", "tt10872600"],
        chronologicalNote: "Ordine cronologico ricostruito da fonti editoriali: può differire dalle timeline pubblicate dagli studi."),
    UniverseDefinition(id: "starwars", name: "Star Wars", summary: "La saga della galassia lontana lontana: trilogie, film antologici e serie.", hero: "tt0080684",
        entries: [
            ("tt0076759", "Star Wars: Episode IV - A New Hope", 1977, false),
            ("tt0080684", "Star Wars: Episode V - The Empire Strikes Back", 1980, false),
            ("tt0086190", "Star Wars: Episode VI - Return of the Jedi", 1983, false),
            ("tt0120915", "Star Wars: Episode I - The Phantom Menace", 1999, false),
            ("tt0121765", "Star Wars: Episode II - Attack of the Clones", 2002, false),
            ("tt0121766", "Star Wars: Episode III - Revenge of the Sith", 2005, false),
            ("tt2488496", "Star Wars: Episode VII - The Force Awakens", 2015, false),
            ("tt3748528", "Rogue One: A Star Wars Story", 2016, false),
            ("tt2527336", "Star Wars: Episode VIII - The Last Jedi", 2017, false),
            ("tt3778644", "Solo: A Star Wars Story", 2018, false),
            ("tt2527338", "Star Wars: Episode IX - The Rise of Skywalker", 2019, false),
            ("tt0458290", "Star Wars: The Clone Wars", 2008, true),
            ("tt2930604", "Star Wars: Rebels", 2014, true),
            ("tt8111088", "The Mandalorian", 2019, true),
            ("tt13668894", "The Book of Boba Fett", 2021, true),
            ("tt8466564", "Obi-Wan Kenobi", 2022, true),
            ("tt9253284", "Andor", 2022, true),
            ("tt13622776", "Ahsoka", 2023, true),
        ],
        chronological: ["tt0120915", "tt0121765", "tt0458290", "tt0121766", "tt8466564", "tt3778644", "tt9253284", "tt3748528", "tt0076759", "tt0080684", "tt0086190", "tt8111088", "tt13668894", "tt13622776", "tt2488496", "tt2527336", "tt2527338"],
        chronologicalNote: "Ordine cronologico della storia ricostruito da fonti editoriali."),
    UniverseDefinition(id: "hp", name: "Wizarding World", summary: "Il mondo di Harry Potter e degli Animali fantastici.", hero: "tt1201607",
        entries: [
            ("tt0241527", "Harry Potter and the Sorcerer's Stone", 2001, false),
            ("tt0295297", "Harry Potter and the Chamber of Secrets", 2002, false),
            ("tt0304141", "Harry Potter and the Prisoner of Azkaban", 2004, false),
            ("tt0330373", "Harry Potter and the Goblet of Fire", 2005, false),
            ("tt0373889", "Harry Potter and the Order of the Phoenix", 2007, false),
            ("tt0417741", "Harry Potter and the Half-Blood Prince", 2009, false),
            ("tt0926084", "Harry Potter and the Deathly Hallows: Part 1", 2010, false),
            ("tt1201607", "Harry Potter and the Deathly Hallows: Part 2", 2011, false),
            ("tt3183660", "Fantastic Beasts and Where to Find Them", 2016, false),
            ("tt4123430", "Fantastic Beasts: The Crimes of Grindelwald", 2018, false),
            ("tt4123432", "Fantastic Beasts: The Secrets of Dumbledore", 2022, false),
        ],
        chronological: ["tt3183660", "tt4123430", "tt4123432"],
        chronologicalNote: "Per la saga principale ordine di uscita e ordine della storia coincidono; gli Animali fantastici sono ambientati prima."),
    UniverseDefinition(id: "lotr", name: "Middle-earth", summary: "La Terra di Mezzo di Tolkien al cinema e in serie.", hero: "tt0167260",
        entries: [
            ("tt0120737", "The Lord of the Rings: The Fellowship of the Ring", 2001, false),
            ("tt0167261", "The Lord of the Rings: The Two Towers", 2002, false),
            ("tt0167260", "The Lord of the Rings: The Return of the King", 2003, false),
            ("tt0903624", "The Hobbit: An Unexpected Journey", 2012, false),
            ("tt1170358", "The Hobbit: The Desolation of Smaug", 2013, false),
            ("tt2310332", "The Hobbit: The Battle of the Five Armies", 2014, false),
            ("tt7631058", "The Lord of the Rings: The Rings of Power", 2022, true),
        ],
        chronological: ["tt7631058", "tt0903624", "tt1170358", "tt2310332", "tt0120737", "tt0167261", "tt0167260"],
        chronologicalNote: "Ordine della storia ricostruito da fonti editoriali."),
    UniverseDefinition(id: "alien", name: "Alien", summary: "Il terrore nello spazio: dalla Nostromo alle colonie.", hero: "tt0090605",
        entries: [
            ("tt0078748", "Alien", 1979, false),
            ("tt0090605", "Aliens", 1986, false),
            ("tt0103644", "Alien³", 1992, false),
            ("tt0118583", "Alien: Resurrection", 1997, false),
            ("tt0370263", "Alien vs. Predator", 2004, false),
            ("tt0758730", "Aliens vs. Predator: Requiem", 2007, false),
            ("tt1446714", "Prometheus", 2012, false),
            ("tt2316204", "Alien: Covenant", 2017, false),
            ("tt18412256", "Alien: Romulus", 2024, false),
            ("tt13623632", "Alien: Earth", 2025, true),
        ],
        chronological: ["tt1446714", "tt2316204", "tt13623632", "tt0078748", "tt18412256", "tt0090605", "tt0103644", "tt0118583"],
        chronologicalNote: "Ordine della storia ricostruito da fonti editoriali (i due crossover con Predator sono considerati a parte)."),
    UniverseDefinition(id: "predator", name: "Predator", summary: "Il cacciatore più letale della galassia.", hero: "tt0093773",
        entries: [
            ("tt0093773", "Predator", 1987, false),
            ("tt0100403", "Predator 2", 1990, false),
            ("tt1424381", "Predators", 2010, false),
            ("tt3829266", "The Predator", 2018, false),
            ("tt11866324", "Prey", 2022, false),
            ("tt36463894", "Predator: Killer of Killers", 2025, false),
            ("tt31227572", "Predator: Badlands", 2025, false),
        ],
        chronological: ["tt11866324", "tt0093773", "tt0100403", "tt1424381", "tt3829266"],
        chronologicalNote: "Ordine della storia ricostruito da fonti editoriali (esclusi i titoli più recenti)."),
    UniverseDefinition(id: "jurassic", name: "Jurassic Park", summary: "Dinosauri tornati in vita: dal parco alle isole del dominio.", hero: "tt0107290",
        entries: [
            ("tt0107290", "Jurassic Park", 1993, false),
            ("tt0119567", "The Lost World: Jurassic Park", 1997, false),
            ("tt0163025", "Jurassic Park III", 2001, false),
            ("tt0369610", "Jurassic World", 2015, false),
            ("tt4881806", "Jurassic World: Fallen Kingdom", 2018, false),
            ("tt8041270", "Jurassic World: Dominion", 2022, false),
            ("tt31036941", "Jurassic World: Rebirth", 2025, false),
            ("tt10436228", "Jurassic World: Camp Cretaceous", 2020, true),
        ],
        chronological: nil,
        chronologicalNote: nil),
    UniverseDefinition(id: "ff", name: "Fast & Furious", summary: "Corse, famiglia e imprese impossibili.", hero: "tt1596343",
        entries: [
            ("tt0232500", "The Fast and the Furious", 2001, false),
            ("tt0322259", "2 Fast 2 Furious", 2003, false),
            ("tt0463985", "The Fast and the Furious: Tokyo Drift", 2006, false),
            ("tt1013752", "Fast & Furious", 2009, false),
            ("tt1596343", "Fast Five", 2011, false),
            ("tt1905041", "Fast & Furious 6", 2013, false),
            ("tt2820852", "Furious 7", 2015, false),
            ("tt4630562", "The Fate of the Furious", 2017, false),
            ("tt6806448", "Fast & Furious Presents: Hobbs & Shaw", 2019, false),
            ("tt5433138", "F9: The Fast Saga", 2021, false),
            ("tt5433140", "Fast X", 2023, false),
        ],
        chronological: ["tt0232500", "tt0322259", "tt1013752", "tt1596343", "tt1905041", "tt0463985", "tt2820852", "tt4630562", "tt6806448", "tt5433138", "tt5433140"],
        chronologicalNote: "Tokyo Drift è collocato dopo il sesto film, come mostra la trama."),
    UniverseDefinition(id: "mi", name: "Mission: Impossible", summary: "Le missioni di Ethan Hunt.", hero: "tt4912910",
        entries: [
            ("tt0117060", "Mission: Impossible", 1996, false),
            ("tt0120755", "Mission: Impossible II", 2000, false),
            ("tt0317919", "Mission: Impossible III", 2006, false),
            ("tt1229238", "Mission: Impossible - Ghost Protocol", 2011, false),
            ("tt2381249", "Mission: Impossible - Rogue Nation", 2015, false),
            ("tt4912910", "Mission: Impossible - Fallout", 2018, false),
            ("tt9603212", "Mission: Impossible - Dead Reckoning Part One", 2023, false),
            ("tt9603208", "Mission: Impossible - The Final Reckoning", 2025, false),
        ],
        chronological: nil,
        chronologicalNote: nil),
    UniverseDefinition(id: "bond", name: "James Bond", summary: "Le missioni dell'agente 007 prodotte da Eon.", hero: "tt1074638",
        entries: [
            ("tt0055928", "Dr. No", 1962, false),
            ("tt0057076", "From Russia with Love", 1963, false),
            ("tt0058150", "Goldfinger", 1964, false),
            ("tt0059800", "Thunderball", 1965, false),
            ("tt0062512", "You Only Live Twice", 1967, false),
            ("tt0064757", "On Her Majesty's Secret Service", 1969, false),
            ("tt0066995", "Diamonds Are Forever", 1971, false),
            ("tt0070328", "Live and Let Die", 1973, false),
            ("tt0071807", "The Man with the Golden Gun", 1974, false),
            ("tt0076752", "The Spy Who Loved Me", 1977, false),
            ("tt0079574", "Moonraker", 1979, false),
            ("tt0082398", "For Your Eyes Only", 1981, false),
            ("tt0086034", "Octopussy", 1983, false),
            ("tt0090264", "A View to a Kill", 1985, false),
            ("tt0093428", "The Living Daylights", 1987, false),
            ("tt0097742", "Licence to Kill", 1989, false),
            ("tt0113189", "GoldenEye", 1995, false),
            ("tt0120347", "Tomorrow Never Dies", 1997, false),
            ("tt0143145", "The World Is Not Enough", 1999, false),
            ("tt0246460", "Die Another Day", 2002, false),
            ("tt0381061", "Casino Royale", 2006, false),
            ("tt0830515", "Quantum of Solace", 2008, false),
            ("tt1074638", "Skyfall", 2012, false),
            ("tt2379713", "Spectre", 2015, false),
            ("tt2382320", "No Time to Die", 2021, false),
        ],
        chronological: nil,
        chronologicalNote: nil),
    UniverseDefinition(id: "monsterverse", name: "MonsterVerse", summary: "I titani di Monarch: Godzilla, Kong e i loro mondi.", hero: "tt5034838",
        entries: [
            ("tt0831387", "Godzilla", 2014, false),
            ("tt3731562", "Kong: Skull Island", 2017, false),
            ("tt3741700", "Godzilla: King of the Monsters", 2019, false),
            ("tt5034838", "Godzilla vs. Kong", 2021, false),
            ("tt14539740", "Godzilla X Kong: The New Empire", 2024, false),
            ("tt17220216", "Monarch: Legacy of Monsters", 2023, true),
        ],
        chronological: ["tt17220216", "tt3731562", "tt0831387", "tt3741700", "tt5034838", "tt14539740"],
        chronologicalNote: "Ordine della storia ricostruito da fonti editoriali."),
    UniverseDefinition(id: "dc", name: "DC Universe", summary: "I supereroi DC sul grande schermo: il DCEU e il nuovo DCU.", hero: "tt0974015",
        entries: [
            ("tt0770828", "Man of Steel", 2013, false),
            ("tt2975590", "Batman v Superman: Dawn of Justice", 2016, false),
            ("tt1386697", "Suicide Squad", 2016, false),
            ("tt0451279", "Wonder Woman", 2017, false),
            ("tt0974015", "Justice League", 2017, false),
            ("tt1477834", "Aquaman", 2018, false),
            ("tt0448115", "Shazam!", 2019, false),
            ("tt7713068", "Birds of Prey and the Fantabulous Emancipation of One Harley Quinn", 2020, false),
            ("tt7126948", "Wonder Woman 1984", 2020, false),
            ("tt6334354", "The Suicide Squad", 2021, false),
            ("tt6443346", "Black Adam", 2022, false),
            ("tt10151854", "Shazam! Fury of the Gods", 2023, false),
            ("tt0439572", "The Flash", 2023, false),
            ("tt9362930", "Blue Beetle", 2023, false),
            ("tt9663764", "Aquaman and the Lost Kingdom", 2023, false),
            ("tt13146488", "Peacemaker", 2022, true),
            ("tt5950044", "Superman", 2025, false),
        ],
        chronological: nil,
        chronologicalNote: "Mescola il DCEU (2013–2023) e l'inizio del nuovo DCU (dal 2022)."),
    UniverseDefinition(id: "got", name: "Game of Thrones", summary: "Il Trono di Spade e le sue storie ambientate a Westeros.", hero: "tt0944947",
        entries: [
            ("tt0944947", "Game of Thrones", 2011, true),
            ("tt11198330", "House of the Dragon", 2022, true),
        ],
        chronological: ["tt11198330", "tt0944947"],
        chronologicalNote: "Ordine della storia: House of the Dragon è ambientata circa 200 anni prima."),
    UniverseDefinition(id: "twd", name: "The Walking Dead", summary: "L'universo degli zombie di Robert Kirkman in serie.", hero: "tt1520211",
        entries: [
            ("tt1520211", "The Walking Dead", 2010, true),
            ("tt3743822", "Fear the Walking Dead", 2015, true),
            ("tt10148174", "The Walking Dead: World Beyond", 2020, true),
            ("tt15669534", "Tales of the Walking Dead", 2022, true),
            ("tt18546730", "The Walking Dead: Dead City", 2023, true),
            ("tt13062500", "The Walking Dead: Daryl Dixon", 2023, true),
            ("tt9859436", "The Walking Dead: The Ones Who Live", 2024, true),
        ],
        chronological: nil,
        chronologicalNote: nil),
    ]
}
