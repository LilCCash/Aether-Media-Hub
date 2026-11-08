import Foundation

/// The map of an universe as storylines: every title sits on the line of its story (Iron Man, Star Wars' Skywalker saga, Bond's
/// Connery years…), in the chosen order from left to right, joined to the title before it on the same line, and joined across lines
/// where the stories meet (the team-ups, the crossovers, the spin-offs).
public struct UniverseStoryMap: Equatable, Sendable {
    public struct Lane: Equatable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        /// The titles of the line, left to right.
        public var entries: [UniverseEntry]
    }

    public struct Node: Equatable, Sendable, Identifiable {
        public var entry: UniverseEntry
        /// Left to right: the position in the chosen order.
        public var column: Int
        public var lane: Int
        /// Where it is drawn, left to right: titles of different lines can share a place, the order is kept (never left of a title
        /// before it) and a line always goes to the right.
        public var slot: Int = 0
        public var id: String { return entry.id }
    }

    public struct Link: Equatable, Sendable, Hashable {
        public enum Kind: String, Equatable, Sendable {
            /// The next title of the same story.
            case sequel
            /// Stories that meet: a team-up, a crossover, a spin-off.
            case crossover
        }

        public var from: String
        public var to: String
        public var kind: Kind
    }

    public var lanes: [Lane]
    public var nodes: [Node]
    public var links: [Link]
    public var columnCount: Int
    public var slotCount: Int = 0

    public func node(_ id: String) -> Node? { return nodes.first { $0.entry.id == id } }
}

/// How the titles of one universe are put on lines.
struct UniverseStorylines {
    struct Rule {
        var name: String
        /// Lowercased pieces of the title; one starting with "=" must be the whole title.
        var match: [String]
        /// A line where other lines meet (the Avengers, the Justice League): the last title of each of these lines before it joins it.
        var members: [String] = []
    }

    var rules: [Rule]
    /// Titles that continue another story (title piece → title piece).
    var bridges: [(String, String)] = []
    /// The lines follow one another (Bond's actors): the last title of each joins the first of the next.
    var chained = false
    var fallback = "Altri titoli"

    static func matches(_ name: String, _ piece: String) -> Bool {
        let lowered = name.lowercased()
        if piece.hasPrefix("=") { return lowered == String(piece.dropFirst()) }
        return lowered.contains(piece)
    }
}

extension UniverseStoryMap {
    public static func build(_ universe: UniverseDefinition, order: UniverseOrder, custom: [String]? = nil) -> UniverseStoryMap {
        let ordered = universe.ordered(order, custom: custom)
        let storylines = UniverseStorylines.catalog[universe.id] ?? UniverseStorylines(rules: [])

        // Lines, in the order of their first title.
        var laneOf: [String: String] = [:]
        for entry in ordered {
            let rule = storylines.rules.first { rule in rule.match.contains { UniverseStorylines.matches(entry.name, $0) } }
            laneOf[entry.id] = rule?.name ?? (storylines.rules.isEmpty ? (entry.isSeries ? "Serie" : "Film") : storylines.fallback)
        }
        var laneNames: [String] = []
        for entry in ordered {
            if let name = laneOf[entry.id], !laneNames.contains(name) { laneNames.append(name) }
        }
        // The lines where others meet go first (on top), the leftovers last.
        let hubs = Set(storylines.rules.filter { !$0.members.isEmpty }.map { $0.name })
        laneNames = laneNames.filter { hubs.contains($0) } + laneNames.filter { !hubs.contains($0) && $0 != storylines.fallback }
            + laneNames.filter { $0 == storylines.fallback }
        let laneIndex = Dictionary(uniqueKeysWithValues: laneNames.enumerated().map { ($1, $0) })

        var nodes: [Node] = []
        var lanes = laneNames.enumerated().map { Lane(id: $0, name: $1, entries: []) }
        for (column, entry) in ordered.enumerated() {
            guard let name = laneOf[entry.id], let lane = laneIndex[name] else { continue }
            nodes.append(Node(entry: entry, column: column, lane: lane))
            lanes[lane].entries.append(entry)
        }

        var links: [Link] = []
        var seen = Set<Link>()
        func add(_ from: String, _ to: String, _ kind: Link.Kind) {
            guard from != to else { return }
            let link = Link(from: from, to: to, kind: kind)
            let reversed = Link(from: to, to: from, kind: kind)
            if seen.contains(link) || seen.contains(reversed) { return }
            seen.insert(link)
            links.append(link)
        }
        for lane in lanes {
            for (first, second) in zip(lane.entries, lane.entries.dropFirst()) { add(first.id, second.id, .sequel) }
        }
        let columnOf = Dictionary(uniqueKeysWithValues: nodes.map { ($0.entry.id, $0.column) })
        // Team-ups: the last title of each member line since the previous team-up joins it, and the next title of that line leaves it.
        for rule in storylines.rules where !rule.members.isEmpty {
            guard let hub = laneIndex[rule.name] else { continue }
            let hubEntries = lanes[hub].entries
            for (position, teamUp) in hubEntries.enumerated() {
                guard let column = columnOf[teamUp.id] else { continue }
                let previousColumn = position > 0 ? (columnOf[hubEntries[position - 1].id] ?? -1) : -1
                for member in rule.members {
                    guard let memberLane = laneIndex[member] else { continue }
                    let entries = lanes[memberLane].entries
                    if let before = entries.last(where: { (columnOf[$0.id] ?? 0) < column && (columnOf[$0.id] ?? 0) > previousColumn }) {
                        add(before.id, teamUp.id, .crossover)
                        if let after = entries.first(where: { (columnOf[$0.id] ?? 0) > column }) { add(teamUp.id, after.id, .crossover) }
                    }
                }
            }
        }
        // Stories that continue one another.
        for (fromPiece, toPiece) in storylines.bridges {
            guard let from = ordered.first(where: { UniverseStorylines.matches($0.name, fromPiece) }),
                  let to = ordered.first(where: { UniverseStorylines.matches($0.name, toPiece) }) else { continue }
            // The arrow goes the way of the chosen order.
            let (a, b) = (columnOf[from.id] ?? 0) <= (columnOf[to.id] ?? 0) ? (from, to) : (to, from)
            add(a.id, b.id, .crossover)
        }
        if storylines.chained {
            for (first, second) in zip(lanes, lanes.dropFirst()) {
                guard let next = second.entries.first, let nextColumn = columnOf[next.id] else { continue }
                if let last = first.entries.last(where: { (columnOf[$0.id] ?? 0) < nextColumn }) { add(last.id, next.id, .crossover) }
            }
        }
        // Places: as far left as the order, the line before on the same story and the titles joining it allow.
        var slotOf: [String: Int] = [:]
        var lastOnLane: [Int: Int] = [:]
        var previous = 0
        let incoming = Dictionary(grouping: links, by: { $0.to })
        for index in nodes.indices {
            var slot = previous
            if let last = lastOnLane[nodes[index].lane] { slot = max(slot, last + 1) }
            for link in incoming[nodes[index].entry.id] ?? [] {
                if let from = slotOf[link.from] { slot = max(slot, from + 1) }
            }
            nodes[index].slot = slot
            slotOf[nodes[index].entry.id] = slot
            lastOnLane[nodes[index].lane] = slot
            previous = slot
        }
        return UniverseStoryMap(lanes: lanes, nodes: nodes, links: links, columnCount: ordered.count,
                                slotCount: (nodes.map { $0.slot }.max() ?? -1) + 1)
    }
}

extension UniverseStorylines {
    typealias R = Rule

    static let catalog: [String: UniverseStorylines] = [
        "mcu": UniverseStorylines(rules: [
            R(name: "Avengers", match: ["avengers"],
              members: ["Iron Man", "Captain America", "Thor e Loki", "Hulk", "Guardiani della Galassia", "Spider-Man", "Doctor Strange",
                        "Black Panther", "Ant-Man", "Captain Marvel", "Black Widow"]),
            R(name: "Defenders", match: ["defenders"], members: ["Daredevil e le strade"]),
            R(name: "Iron Man", match: ["iron man", "ironheart"]),
            R(name: "Captain America", match: ["captain america", "falcon and the winter soldier"]),
            R(name: "Thor e Loki", match: ["thor:", "=thor", "loki"]),
            R(name: "Hulk", match: ["hulk"]),
            R(name: "Guardiani della Galassia", match: ["guardians", "i am groot"]),
            R(name: "Spider-Man", match: ["spider-man"]),
            R(name: "Doctor Strange", match: ["doctor strange", "what if", "marvel zombies"]),
            R(name: "Wanda e Visione", match: ["wandavision", "agatha", "visionquest"]),
            R(name: "Black Panther", match: ["black panther", "wakanda"]),
            R(name: "Ant-Man", match: ["ant-man"]),
            R(name: "Captain Marvel", match: ["captain marvel", "the marvels", "ms. marvel", "secret invasion"]),
            R(name: "Black Widow", match: ["black widow", "thunderbolts", "hawkeye", "echo"]),
            R(name: "Daredevil e le strade", match: ["daredevil", "jessica jones", "luke cage", "iron fist", "punisher"]),
            R(name: "S.H.I.E.L.D.", match: ["s.h.i.e.l.d", "agent carter"]),
            R(name: "Mutanti e Fantastici Quattro", match: ["deadpool", "fantastic four"]),
            R(name: "Eroi solitari", match: ["shang-chi", "eternals", "werewolf", "moon knight", "wonder man"]),
        ], bridges: [
            ("avengers: endgame", "wandavision"), ("avengers: endgame", "falcon and the winter soldier"), ("avengers: endgame", "loki"),
            ("avengers: endgame", "far from home"), ("wandavision", "multiverse of madness"), ("no way home", "multiverse of madness"),
            ("hawkeye", "echo"), ("loki", "deadpool"), ("what if", "marvel zombies"), ("the marvels", "ms. marvel"),
            ("captain marvel", "the marvels"), ("secret invasion", "the marvels"), ("civil war", "black panther"), ("civil war", "homecoming"),
            ("the defenders", "daredevil: born again"), ("black panther: wakanda forever", "ironheart"), ("thunderbolts", "fantastic four"),
        ]),
        "spiderman": UniverseStorylines(rules: [
            R(name: "Trilogia di Raimi", match: ["=spider-man", "=spider-man 2", "=spider-man 3"]),
            R(name: "The Amazing Spider-Man", match: ["amazing"]),
            R(name: "Spider-Man con Tom Holland", match: ["homecoming", "far from home", "no way home", "brand new day", "friendly neighborhood"]),
            R(name: "Spider-Verse", match: ["spider-verse"]),
            R(name: "Universo Sony", match: ["venom", "morbius", "madame web", "kraven"]),
        ], bridges: [
            ("=spider-man 3", "no way home"), ("the amazing spider-man 2", "no way home"), ("let there be carnage", "no way home"),
        ]),
        "starwars": UniverseStorylines(rules: [
            R(name: "Saga degli Skywalker", match: ["episode", "obi-wan"]),
            R(name: "Storie della ribellione", match: ["rogue one", "andor", "solo"]),
            R(name: "Animazione", match: ["clone wars", "rebels"]),
            R(name: "Era del Mandaloriano", match: ["mandalorian", "boba fett", "ahsoka"]),
        ], bridges: [
            ("revenge of the sith", "obi-wan"), ("andor", "rogue one"), ("rogue one", "a new hope"), ("clone wars", "ahsoka"),
            ("rebels", "ahsoka"), ("return of the jedi", "mandalorian"), ("attack of the clones", "clone wars"),
        ]),
        "hp": UniverseStorylines(rules: [
            R(name: "Harry Potter", match: ["harry potter"]),
            R(name: "Animali fantastici", match: ["fantastic beasts"]),
        ], bridges: [("secrets of dumbledore", "sorcerer's stone")]),
        "lotr": UniverseStorylines(rules: [
            R(name: "La Seconda Era", match: ["rings of power"]),
            R(name: "Lo Hobbit", match: ["hobbit"]),
            R(name: "Il Signore degli Anelli", match: ["lord of the rings"]),
        ], bridges: [("battle of the five armies", "fellowship of the ring")]),
        "alien": UniverseStorylines(rules: [
            R(name: "Alien vs. Predator", match: ["vs. predator"]),
            R(name: "Prequel", match: ["prometheus", "covenant"]),
            R(name: "Saga di Ripley e le colonie", match: ["alien"]),
        ], bridges: [("covenant", "=alien"), ("=aliens", "romulus")]),
        "predator": UniverseStorylines(rules: [
            R(name: "Predator", match: ["=predator", "predator 2", "predators", "the predator"]),
            R(name: "Cacciatori di ogni epoca", match: ["prey", "killer of killers", "badlands"]),
        ], bridges: [("the predator", "prey")]),
        "jurassic": UniverseStorylines(rules: [
            R(name: "Jurassic Park", match: ["jurassic park", "lost world"]),
            R(name: "Camp Cretaceous", match: ["camp cretaceous"]),
            R(name: "Jurassic World", match: ["jurassic world"]),
        ], bridges: [("jurassic park iii", "=jurassic world"), ("=jurassic world", "camp cretaceous"), ("camp cretaceous", "fallen kingdom")]),
        "ff": UniverseStorylines(rules: [
            R(name: "La saga", match: ["fast", "furious", "f9"]),
        ], bridges: []),
        "mi": UniverseStorylines(rules: [R(name: "Le missioni di Ethan Hunt", match: ["mission"])]),
        "bond": UniverseStorylines(rules: [
            R(name: "Sean Connery", match: ["=dr. no", "=from russia with love", "=goldfinger", "=thunderball", "=you only live twice", "=diamonds are forever"]),
            R(name: "George Lazenby", match: ["on her majesty"]),
            R(name: "Roger Moore", match: ["live and let die", "golden gun", "spy who loved me", "moonraker", "for your eyes only", "octopussy", "view to a kill"]),
            R(name: "Timothy Dalton", match: ["living daylights", "licence to kill"]),
            R(name: "Pierce Brosnan", match: ["goldeneye", "tomorrow never dies", "world is not enough", "die another day"]),
            R(name: "Daniel Craig", match: ["casino royale", "quantum of solace", "skyfall", "spectre", "no time to die"]),
        ], chained: true),
        "monsterverse": UniverseStorylines(rules: [
            R(name: "Godzilla e Kong", match: ["vs. kong", "x kong"], members: ["Godzilla", "Kong"]),
            R(name: "Godzilla", match: ["godzilla"]),
            R(name: "Kong", match: ["kong"]),
            R(name: "Monarch", match: ["monarch"]),
        ], bridges: [("=godzilla", "monarch")]),
        "dc": UniverseStorylines(rules: [
            R(name: "Justice League", match: ["batman v superman", "justice league"], members: ["Superman", "Wonder Woman", "Aquaman", "The Flash"]),
            R(name: "Superman", match: ["man of steel", "superman"]),
            R(name: "Wonder Woman", match: ["wonder woman"]),
            R(name: "Aquaman", match: ["aquaman"]),
            R(name: "The Flash", match: ["the flash"]),
            R(name: "Shazam e Black Adam", match: ["shazam", "black adam"]),
            R(name: "Suicide Squad", match: ["suicide squad", "peacemaker", "birds of prey"]),
            R(name: "Blue Beetle", match: ["blue beetle"]),
        ], bridges: [("the flash", "=superman"), ("peacemaker", "=superman")]),
        "got": UniverseStorylines(rules: [
            R(name: "Il Trono di Spade", match: ["game of thrones"]),
            R(name: "La casa Targaryen", match: ["house of the dragon"]),
        ], bridges: [("house of the dragon", "game of thrones")]),
        "twd": UniverseStorylines(rules: [
            R(name: "The Walking Dead", match: ["=the walking dead", "ones who live", "daryl dixon", "dead city"]),
            R(name: "Fear the Walking Dead", match: ["fear the"]),
            R(name: "Altre storie", match: ["world beyond", "tales"]),
        ], bridges: [("=the walking dead", "fear the walking dead"), ("=the walking dead", "world beyond"), ("fear the walking dead", "tales")]),
    ]
}
