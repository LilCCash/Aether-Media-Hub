package app.aether.core.search

import java.text.Normalizer

enum class IntentGenre(val movieId: Int?, val tvId: Int?, val italian: String) {
    ACTION(28, 10759, "azione"), ADVENTURE(12, 10759, "avventura"), ANIMATION(16, 16, "animazione"), COMEDY(35, 35, "commedia"),
    CRIME(80, 80, "crimine"), DOCUMENTARY(99, 99, "documentario"), DRAMA(18, 18, "drammatico"), FAMILY(10751, 10751, "famiglia"),
    FANTASY(14, 10765, "fantasy"), HISTORY(36, null, "storico"), HORROR(27, null, "horror"), MUSIC(10402, null, "musicale"),
    MYSTERY(9648, 9648, "mistero"), ROMANCE(10749, 10749, "romantico"), SCIFI(878, 10765, "fantascienza"), THRILLER(53, null, "thriller"),
    WAR(10752, 10768, "guerra"), WESTERN(37, 37, "western"),
}

enum class IntentKind { MOVIE, SERIES }

enum class IntentSort(val italian: String) { POPULARITY("più popolari"), RATING("meglio votati"), NEWEST("più recenti"), OLDEST("più vecchi") }

/** What the viewer wants, as filters: produced by the parser, run on TMDB. */
data class SearchIntent(
    val kind: IntentKind? = null,
    val genres: List<IntentGenre> = emptyList(),
    /** TMDB keywords, in English ("heist", "slasher"). */
    val keywords: List<String> = emptyList(),
    val yearFrom: Int? = null,
    val yearTo: Int? = null,
    val sort: IntentSort = IntentSort.POPULARITY,
    val minRating: Double? = null,
    val countries: List<String> = emptyList(),
    val maxRuntime: Int? = null,
    val similarTo: String? = null,
) {
    val hasFilters: Boolean
        get() = genres.isNotEmpty() || keywords.isNotEmpty() || yearFrom != null || yearTo != null || minRating != null ||
            countries.isNotEmpty() || maxRuntime != null || similarTo != null

    /** The sentence as the app understood it, in Italian. */
    val summary: String
        get() {
            similarTo?.let { return "${if (kind == IntentKind.SERIES) "serie" else if (kind == IntentKind.MOVIE) "film" else "titoli"} simili a «$it»" }
            val parts = ArrayList<String>()
            kind?.let { parts += if (it == IntentKind.MOVIE) "film" else "serie" }
            if (genres.isNotEmpty()) parts += genres.joinToString(" + ") { it.italian }
            if (keywords.isNotEmpty()) parts += "«${keywords.joinToString()}»"
            when {
                yearFrom != null && yearTo != null -> parts += if (yearFrom == yearTo) "$yearFrom" else "$yearFrom–$yearTo"
                yearFrom != null -> parts += "dal $yearFrom"
                yearTo != null -> parts += "fino al $yearTo"
            }
            if (countries.isNotEmpty()) parts += countries.joinToString()
            maxRuntime?.let { parts += "sotto i $it minuti" }
            if (sort != IntentSort.POPULARITY || minRating != null) parts += sort.italian
            return parts.joinToString(" · ")
        }
}

/**
 * Understands Italian sentences such as «commedie demenziali degli ultimi anni» on the device: a dictionary of word stems, no
 * network and no AI (the same rules as the iPhone). What no rule explains is returned as leftovers.
 */
class NaturalQueryParser(private val currentYear: Int = java.time.Year.now().value) {
    data class Output(val intent: SearchIntent, val leftovers: List<String>)

    private val genreStems = listOf(
        IntentGenre.COMEDY to listOf("commedi", "divert", "comic", "ridere", "ridicol", "spassos", "demenzial", "esilarant", "umoristic", "satir"),
        IntentGenre.HORROR to listOf("horror", "paura", "spavent", "terrore", "splatter", "slasher", "inquiet"),
        IntentGenre.THRILLER to listOf("thriller", "suspense", "tension", "adrenalin"),
        IntentGenre.ACTION to listOf("azione", "action", "esplosiv", "combattiment"),
        IntentGenre.ADVENTURE to listOf("avventur"),
        IntentGenre.ANIMATION to listOf("animazion", "animat", "cartoni", "cartone", "pixar", "disney"),
        IntentGenre.SCIFI to listOf("fantascien", "scifi", "sci-fi", "spaziali", "spazio", "alieni", "distopic", "cyberpunk"),
        IntentGenre.FANTASY to listOf("fantasy", "magic", "fantastic", "incantat"),
        IntentGenre.DRAMA to listOf("dramma", "drammatic", "commovent", "strappalacrime"),
        IntentGenre.ROMANCE to listOf("romanti", "amore", "d'amore", "sentimental"),
        IntentGenre.DOCUMENTARY to listOf("documentar"),
        IntentGenre.WAR to listOf("guerra", "bellic"),
        IntentGenre.WESTERN to listOf("western", "spaghetti"),
        IntentGenre.MYSTERY to listOf("giall", "mister", "investigativ", "detective", "whodunit"),
        IntentGenre.CRIME to listOf("crimin", "gangster", "mafia", "polizies", "rapin", "heist"),
        IntentGenre.FAMILY to listOf("famigli", "bambini", "ragazzi"),
        IntentGenre.MUSIC to listOf("music", "concert"),
        IntentGenre.HISTORY to listOf("storic", "period", "epoca", "d'epoca", "antica", "medieval"),
    )
    private val countryStems = listOf(
        "IT" to listOf("italian"), "US" to listOf("american", "hollywood"), "FR" to listOf("francese", "francesi"), "ES" to listOf("spagnol"),
        "DE" to listOf("tedesch"), "GB" to listOf("british", "inglesi", "inglese", "britannic"), "KR" to listOf("corean"), "JP" to listOf("giappones"),
        "IN" to listOf("indian", "bollywood"), "CN" to listOf("cines"), "SE" to listOf("svedes"), "DK" to listOf("danes"), "MX" to listOf("messican"),
        "BR" to listOf("brasilian"), "TR" to listOf("turch"),
    )
    private val keywordHints = listOf(
        "demenzial" to "slapstick", "slasher" to "slasher", "heist" to "heist", "rapin" to "heist", "spaghetti" to "spaghetti western",
        "zombie" to "zombie", "vampir" to "vampire", "supereroi" to "superhero", "cyberpunk" to "cyberpunk", "distopic" to "dystopia",
        "parodi" to "parody", "natal" to "christmas", "viaggi nel tempo" to "time travel", "alieni" to "alien", "robot" to "robot",
        "serial killer" to "serial killer", "mafia" to "mafia", "storia vera" to "based on true story",
    )
    private val stopwords = setOf(
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "di", "del", "dello", "della", "dei", "degli", "delle", "da", "dal", "dallo", "dalla",
        "dai", "dagli", "dalle", "in", "nel", "nello", "nella", "nei", "negli", "nelle", "con", "su", "sul", "per", "tra", "fra", "e", "ed", "o", "che",
        "ci", "sono", "ho", "voglio", "vorrei", "cerco", "cercare", "trova", "trovami", "mostrami", "dammi", "qualche", "alcuni", "alcune", "molto",
        "piu", "film", "films", "serie", "serial", "tv", "telefilm", "movie", "movies", "titoli", "roba", "cose", "bei", "bel", "belli", "bello",
        "bella", "belle", "buoni", "buon", "buona", "tipo", "stile", "genere", "ultimi", "ultime", "ultimo", "ultima", "anni", "anno", "recenti",
        "recente", "famosi", "famose", "famoso", "famosa", "visti", "dell", "all", "alla", "alle", "agli", "ai", "al", "quelli", "quelle", "quello",
        "quella", "molti", "tanti", "tante", "mi", "ti", "si", "ne", "non", "ma", "se", "come", "dove", "quando", "anche", "solo",
    )

    fun parse(raw: String): Output {
        similarRequest(raw)?.let { (title, kind) -> return Output(SearchIntent(kind = kind, similarTo = title), emptyList()) }
        var text = " " + fold(raw).replace('’', '\'') + " "
        var intent = SearchIntent()
        fun remove(pattern: String) { text = text.replace(Regex(pattern), " ") }
        fun firstInt(pattern: String): Int? = Regex(pattern).find(text)?.groupValues?.getOrNull(1)?.toIntOrNull()

        firstInt("""(?:prima del|entro il|fino al|fino a)\s+((?:19|20)\d{2})""")?.let { intent = intent.copy(yearTo = it); remove("""(?:prima del|entro il|fino al|fino a)\s+(?:19|20)\d{2}""") }
        firstInt("""(?:dopo il|dal|a partire dal|da)\s+((?:19|20)\d{2})""")?.let { intent = intent.copy(yearFrom = it); remove("""(?:dopo il|dal|a partire dal|da)\s+(?:19|20)\d{2}""") }
        val decadeNumber = firstInt("""anni\s*'?((?:19|20)?\d0)\b""")
        if (decadeNumber != null) {
            val decade = if (decadeNumber < 100) (if (decadeNumber >= 30) 1900 + decadeNumber else 2000 + decadeNumber) else decadeNumber
            intent = intent.copy(yearFrom = decade, yearTo = decade + 9)
            remove("""anni\s*'?(?:19|20)?\d0\b""")
        } else {
            listOf("sessanta" to 1960, "settanta" to 1970, "ottanta" to 1980, "novanta" to 1990, "duemila" to 2000)
                .firstOrNull { (w, _) -> text.contains("anni $w") || text.contains("anni '$w") }
                ?.let { (w, y) -> intent = intent.copy(yearFrom = y, yearTo = y + 9); remove("anni '?$w") }
        }
        if (intent.yearFrom == null && intent.yearTo == null) {
            firstInt("""\b((?:19|20)\d{2})\b""")?.let { intent = intent.copy(yearFrom = it, yearTo = it); remove("""\b(?:19|20)\d{2}\b""") }
        }
        if (intent.yearFrom == null) {
            intent = when {
                "ultimi anni" in text || "ultimi tempi" in text || "negli ultimi" in text -> intent.copy(yearFrom = currentYear - 5)
                "ultimo anno" in text || "quest'anno" in text || "questanno" in text -> intent.copy(yearFrom = currentYear - 1)
                "recent" in text || " nuov" in text || "ultime uscite" in text || "appena usciti" in text -> intent.copy(yearFrom = currentYear - 2)
                "classic" in text || "vecchi" in text || "d'altri tempi" in text || "di una volta" in text -> intent.copy(yearTo = intent.yearTo ?: 1995)
                "moderni" in text || "contemporane" in text -> intent.copy(yearFrom = 2010)
                else -> intent
            }
        }
        if (listOf("famos", "popolar", "piu visti", "di successo", "noti").any { it in text }) intent = intent.copy(sort = IntentSort.POPULARITY)
        if (listOf("migliori", "capolavor", "top ", "meglio", "ben votat", "acclamat", "premiati").any { it in text }) intent = intent.copy(sort = IntentSort.RATING, minRating = 7.0)
        if ("cult" in text) intent = intent.copy(sort = IntentSort.RATING, minRating = 6.5, yearTo = intent.yearTo ?: (currentYear - 12))
        if (listOf("ultime uscite", "novita", "appena usciti").any { it in text } && intent.sort == IntentSort.POPULARITY) intent = intent.copy(sort = IntentSort.NEWEST)

        val wantsSeries = listOf(" serie", " telefilm", " tv ", "stagion").any { it in text }
        val wantsMovie = listOf(" film", " movie", "lungometragg").any { it in text }
        if (wantsSeries && !wantsMovie) intent = intent.copy(kind = IntentKind.SERIES)
        if (wantsMovie && !wantsSeries) intent = intent.copy(kind = IntentKind.MOVIE)
        if (listOf("brevi", " corti", "breve ", "veloci").any { it in text }) intent = intent.copy(maxRuntime = 95)

        val words = tokens(text)
        val used = HashSet<String>()
        val genres = ArrayList<IntentGenre>()
        for ((genre, stems) in genreStems) {
            var matched = false
            for (word in words) if (stems.any { word.startsWith(it) }) { used += word; matched = true }
            if (matched && genre !in genres) genres += genre
        }
        val keywords = keywordHints.filter { (stem, _) -> stem in text }.map { it.second }.distinct()
        val countries = ArrayList<String>()
        for ((code, stems) in countryStems) for (word in words) if (stems.any { word.startsWith(it) }) { used += word; if (code !in countries) countries += code }
        intent = intent.copy(genres = genres, keywords = keywords, countries = countries)
        val leftovers = words.filter { it.length > 2 && it !in used && it !in stopwords && !it.all(Char::isDigit) }
        return Output(intent, leftovers)
    }

    /** «film simili a Toy Story», «film tipo Scary Movie», «serie come Lost». */
    private fun similarRequest(raw: String): Pair<String, IntentKind?>? {
        val prefix = """^\s*(film|serie tv|serie|telefilm|titoli)?\s*"""
        val patterns = listOf(
            Regex(prefix + """(?:simil[ei]\s+(?:alle|alla|allo|all'|agli|ai|al|ad|a)\s*|tipo\s+|(?:sullo\s+)?stile\s+di\s+|che\s+ricordano\s+|che\s+assomigliano\s+a\s+)(.+?)\s*$""", RegexOption.IGNORE_CASE) to false,
            Regex(prefix + """come\s+(.+?)\s*$""", RegexOption.IGNORE_CASE) to true,
        )
        for ((regex, needsPrefix) in patterns) {
            val m = regex.find(raw) ?: continue
            val kindWord = m.groups[1]?.value?.lowercase()
            if (needsPrefix && kindWord == null) continue
            val title = m.groupValues[2].trim(' ', '.', ',', ';', ':', '!', '?', '"', '“', '”', '«', '»')
            if (title.length < 2 || title.split(' ').size > 8) continue
            val kind = when { kindWord == "film" -> IntentKind.MOVIE; kindWord != null && (kindWord.startsWith("serie") || kindWord == "telefilm") -> IntentKind.SERIES; else -> null }
            return title to kind
        }
        return null
    }

    private fun tokens(text: String): List<String> = text.split(Regex("""[^\p{L}\p{N}'\-]+""")).filter { it.isNotEmpty() }.map { w ->
        if (w.startsWith("l'") || w.startsWith("un'") || w.startsWith("dell'")) w.substringAfter('\'') else w
    }

    companion object {
        fun fold(text: String): String = Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")

        /** True when the text reads like a request rather than a title: a phrase the parser explains at least in part. */
        fun looksNatural(text: String): Boolean {
            val words = text.trim().split(Regex("\\s+"))
            if (words.size < 2) return false
            val out = NaturalQueryParser().parse(text)
            return out.intent.hasFilters && (out.intent.genres.isNotEmpty() || out.intent.similarTo != null || out.intent.yearFrom != null || out.intent.yearTo != null || out.intent.countries.isNotEmpty())
        }
    }
}
