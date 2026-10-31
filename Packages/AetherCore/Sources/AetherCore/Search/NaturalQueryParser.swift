import Foundation

/// Livello 2 della ricerca avanzata: capisce in locale frasi italiane come «commedie demenziali degli ultimi anni».
/// Niente rete, niente AI: un dizionario di parole. Quel che non riconosce resta tra le «parole rimaste».
public struct NaturalQueryParser: Sendable {
    public struct Output: Equatable, Sendable {
        public var intent: SearchIntent
        /// Parole non spiegate da nessuna regola: candidate come parole chiave TMDB.
        public var leftovers: [String]
    }

    private let currentYear: Int

    public init(currentYear: Int = Calendar.current.component(.year, from: Date())) {
        self.currentYear = currentYear
    }

    // MARK: Dizionari (radici di parola: il confronto è «inizia con»)

    private static let genreStems: [(IntentGenre, [String])] = [
        (.comedy, ["commedi", "divert", "comic", "ridere", "ridicol", "spassos", "demenzial", "esilarant", "umoristic", "satir"]),
        (.horror, ["horror", "paura", "spavent", "terrore", "splatter", "slasher", "inquiet"]),
        (.thriller, ["thriller", "suspense", "tension", "adrenalin"]),
        (.action, ["azione", "action", "esplosiv", "combattiment"]),
        (.adventure, ["avventur"]),
        (.animation, ["animazion", "animat", "cartoni", "cartone", "pixar", "disney"]),
        (.scifi, ["fantascien", "scifi", "sci-fi", "spaziali", "spazio", "alieni", "distopic", "cyberpunk"]),
        (.fantasy, ["fantasy", "magic", "fantastic", "incantat"]),
        (.drama, ["dramma", "drammatic", "commovent", "strappalacrime"]),
        (.romance, ["romanti", "amore", "d'amore", "sentimental", "storie d'amore"]),
        (.documentary, ["documentar"]),
        (.war, ["guerra", "bellic"]),
        (.western, ["western", "spaghetti"]),
        (.mystery, ["giall", "mister", "investigativ", "detective", "whodunit"]),
        (.crime, ["crimin", "gangster", "mafia", "polizies", "rapin", "heist", "criminal"]),
        (.family, ["famigli", "bambini", "ragazzi", "per tutti"]),
        (.music, ["music", "concert"]),
        (.history, ["storic", "period", "epoca", "d'epoca", "antica", "medieval"]),
    ]

    private static let countryStems: [(String, [String])] = [
        ("IT", ["italian"]), ("US", ["american", "hollywood"]), ("FR", ["francese", "francesi"]),
        ("ES", ["spagnol"]), ("DE", ["tedesch"]), ("GB", ["british", "inglesi", "inglese", "britannic"]),
        ("KR", ["corean"]), ("JP", ["giappones"]), ("IN", ["indian", "bollywood"]), ("CN", ["cines"]),
        ("SE", ["svedes"]), ("DK", ["danes"]), ("MX", ["messican"]), ("BR", ["brasilian"]), ("TR", ["turch"]),
    ]

    private static let stopwords: Set<String> = [
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "di", "del", "dello", "della", "dei", "degli", "delle",
        "da", "dal", "dallo", "dalla", "dai", "dagli", "dalle", "in", "nel", "nello", "nella", "nei", "negli", "nelle",
        "con", "su", "sul", "per", "tra", "fra", "e", "ed", "o", "che", "ci", "sono", "è", "ho", "voglio", "vorrei",
        "cerco", "cercare", "trova", "trovami", "mostrami", "dammi", "qualche", "alcuni", "alcune", "molto", "più", "piu",
        "film", "films", "serie", "serial", "tv", "telefilm", "movie", "movies", "titoli", "roba", "cose", "bei", "bel",
        "belli", "bello", "bella", "belle", "buoni", "buon", "buona", "tipo", "stile", "genere", "ultimi", "ultime",
        "ultimo", "ultima", "anni", "anno", "recenti", "recente", "famosi", "famose", "famoso", "famosa", "più", "visti",
        "dell", "all", "alla", "alle", "agli", "ai", "al", "dell'", "l'", "un'", "quelli", "quelle", "quello", "quella",
        "molti", "tanti", "tante", "mi", "ti", "si", "ne", "non", "ma", "se", "come", "dove", "quando", "anche", "solo",
    ]

    // MARK: Interpretazione

    public func parse(_ raw: String) -> Output {
        let lowered = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .replacingOccurrences(of: "’", with: "'")
        var intent = SearchIntent()
        intent.source = .parser
        var text = " " + lowered + " "
        var used = Set<String>()

        func remove(_ pattern: String) {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        // Anni espliciti e decenni.
        if let value = firstInt(in: text, pattern: "(?:prima del|entro il|fino al|fino a)\\s+((?:19|20)\\d{2})") {
            intent.yearTo = value
            remove("(?:prima del|entro il|fino al|fino a)\\s+(?:19|20)\\d{2}")
        }
        if let value = firstInt(in: text, pattern: "(?:dopo il|dal|a partire dal|da)\\s+((?:19|20)\\d{2})") {
            intent.yearFrom = value
            remove("(?:dopo il|dal|a partire dal|da)\\s+(?:19|20)\\d{2}")
        }
        if let value = firstInt(in: text, pattern: "(?:anni|anni')\\s*'?((?:19|20)?\\d0)\\b") {
            let decade = value < 100 ? (value >= 30 ? 1900 + value : 2000 + value) : value
            intent.yearFrom = decade
            intent.yearTo = decade + 9
            remove("(?:anni|anni')\\s*'?(?:19|20)?\\d0\\b")
        } else if let word = decadeWord(in: text) {
            intent.yearFrom = word.year
            intent.yearTo = word.year + 9
            remove(word.pattern)
        }
        if intent.yearFrom == nil && intent.yearTo == nil, let value = firstInt(in: text, pattern: "\\b((?:19|20)\\d{2})\\b") {
            intent.yearFrom = value
            intent.yearTo = value
            remove("\\b(?:19|20)\\d{2}\\b")
        }

        // Periodi relativi.
        if intent.yearFrom == nil {
            if text.contains("ultimi anni") || text.contains("ultimi tempi") || text.contains("negli ultimi") {
                intent.yearFrom = currentYear - 5
            } else if text.contains("ultimo anno") || text.contains("quest'anno") || text.contains("questanno") {
                intent.yearFrom = currentYear - 1
            } else if text.contains("recent") || text.contains(" nuov") || text.contains("ultime uscite") || text.contains("appena usciti") {
                intent.yearFrom = currentYear - 2
            } else if text.contains("classic") || text.contains("vecchi") || text.contains("d'altri tempi") || text.contains("di una volta") {
                intent.yearTo = 1995
            } else if text.contains("moderni") || text.contains("contemporane") {
                intent.yearFrom = 2010
            }
        }

        // Ordinamento.
        if text.contains("famos") || text.contains("popolar") || text.contains("piu visti") || text.contains("di successo") || text.contains("noti") {
            intent.sort = .popularity
        }
        if text.contains("migliori") || text.contains("capolavor") || text.contains("top ") || text.contains("meglio") || text.contains("ben votat") || text.contains("acclamat") || text.contains("premiati") {
            intent.sort = .rating
            intent.minRating = 7.0
        }
        if text.contains("cult") {
            intent.sort = .rating
            intent.minRating = 6.5
            if intent.yearTo == nil { intent.yearTo = currentYear - 12 }
        }
        if intent.sort == .popularity && (text.contains("ultime uscite") || text.contains("novita") || text.contains("appena usciti")) {
            intent.sort = .newest
        }

        // Tipo.
        let wantsSeries = text.contains(" serie") || text.contains(" telefilm") || text.contains(" tv ") || text.contains("stagion")
        let wantsMovie = text.contains(" film") || text.contains(" movie") || text.contains("lungometragg")
        if wantsSeries && !wantsMovie { intent.kind = .series }
        if wantsMovie && !wantsSeries { intent.kind = .movie }

        // Durata.
        if text.contains("brevi") || text.contains(" corti") || text.contains("breve ") || text.contains("veloci") {
            intent.maxRuntime = 95
        }

        // Generi e paesi.
        let words = tokens(text)
        for (genre, stems) in NaturalQueryParser.genreStems {
            var matched = false
            for word in words {
                if stems.contains(where: { (stem: String) -> Bool in word.hasPrefix(stem) }) {
                    used.insert(word)
                    matched = true
                }
            }
            if !matched {
                for stem in stems where stem.contains(" ") && text.contains(stem) { matched = true }
            }
            if matched && !intent.genres.contains(genre) { intent.genres.append(genre) }
        }
        // «Demenziale», «slasher», «heist»… dicono anche qualcosa di più preciso del genere.
        let keywordHints: [(String, String)] = [
            ("demenzial", "slapstick"), ("slasher", "slasher"), ("heist", "heist"), ("rapin", "heist"),
            ("spaghetti", "spaghetti western"), ("zombie", "zombie"), ("vampir", "vampire"), ("supereroi", "superhero"),
            ("cyberpunk", "cyberpunk"), ("distopic", "dystopia"), ("parodi", "parody"), ("natal", "christmas"),
            ("viaggi nel tempo", "time travel"), ("alieni", "alien"), ("robot", "robot"), ("serial killer", "serial killer"),
            ("mafia", "mafia"), ("tratt da una storia vera", "based on true story"), ("storia vera", "based on true story"),
        ]
        for (stem, keyword) in keywordHints where text.contains(stem) && !intent.keywords.contains(keyword) {
            intent.keywords.append(keyword)
        }
        for (code, stems) in NaturalQueryParser.countryStems {
            for word in words where stems.contains(where: { (stem: String) -> Bool in word.hasPrefix(stem) }) {
                used.insert(word)
                if !intent.countries.contains(code) { intent.countries.append(code) }
            }
        }

        let leftovers = words.filter { (word: String) -> Bool in
            word.count > 2 && !used.contains(word) && !NaturalQueryParser.stopwords.contains(word) && !isNoise(word)
        }
        return Output(intent: intent, leftovers: leftovers)
    }

    // MARK: Helpers

    private func tokens(_ text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted
        return text.components(separatedBy: separators).filter { !$0.isEmpty }.map { (word: String) -> String in
            // «l'ultimo» → «ultimo», «d'azione» resta intero perché tra le radici.
            if word.hasPrefix("l'") || word.hasPrefix("un'") || word.hasPrefix("dell'") {
                return String(word.drop(while: { $0 != "'" }).dropFirst())
            }
            return word
        }
    }

    private func isNoise(_ word: String) -> Bool {
        return word.allSatisfy { $0.isNumber }
    }

    private func firstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private func decadeWord(in text: String) -> (year: Int, pattern: String)? {
        let table: [(String, Int)] = [("sessanta", 1960), ("settanta", 1970), ("ottanta", 1980), ("novanta", 1990), ("duemila", 2000)]
        for (word, year) in table where text.contains("anni " + word) || text.contains("anni '" + word) {
            return (year, "anni '?" + word)
        }
        return nil
    }
}
