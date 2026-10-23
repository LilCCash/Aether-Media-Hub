package app.aether.core.playback

/** Language codes of subtitles and audio tracks, as addons and players spell them (639-1, 639-2/B and /T, a few inventions). */
object Languages {
    private class Row(val alpha2: String, val alpha3: List<String>, val italian: String)

    private val rows = listOf(
        Row("it", listOf("ita"), "Italiano"), Row("en", listOf("eng"), "Inglese"), Row("fr", listOf("fra", "fre"), "Francese"),
        Row("es", listOf("spa", "spl"), "Spagnolo"), Row("de", listOf("deu", "ger"), "Tedesco"), Row("pt", listOf("por", "pob"), "Portoghese"),
        Row("ru", listOf("rus"), "Russo"), Row("ja", listOf("jpn"), "Giapponese"), Row("ko", listOf("kor"), "Coreano"),
        Row("zh", listOf("zho", "chi", "zht", "zhe"), "Cinese"), Row("ar", listOf("ara"), "Arabo"), Row("hi", listOf("hin"), "Hindi"),
        Row("tr", listOf("tur"), "Turco"), Row("pl", listOf("pol"), "Polacco"), Row("nl", listOf("nld", "dut"), "Olandese"),
        Row("sv", listOf("swe"), "Svedese"), Row("da", listOf("dan"), "Danese"), Row("no", listOf("nor", "nob"), "Norvegese"),
        Row("fi", listOf("fin"), "Finlandese"), Row("el", listOf("ell", "gre"), "Greco"), Row("he", listOf("heb"), "Ebraico"),
        Row("cs", listOf("ces", "cze"), "Ceco"), Row("hu", listOf("hun"), "Ungherese"), Row("ro", listOf("ron", "rum"), "Rumeno"),
        Row("bg", listOf("bul"), "Bulgaro"), Row("uk", listOf("ukr"), "Ucraino"), Row("hr", listOf("hrv"), "Croato"),
        Row("sr", listOf("srp"), "Serbo"), Row("sk", listOf("slk", "slo"), "Slovacco"), Row("sl", listOf("slv"), "Sloveno"),
        Row("th", listOf("tha"), "Tailandese"), Row("vi", listOf("vie"), "Vietnamita"), Row("id", listOf("ind"), "Indonesiano"),
        Row("ca", listOf("cat"), "Catalano"), Row("fa", listOf("fas", "per"), "Persiano"), Row("lt", listOf("lit"), "Lituano"),
        Row("lv", listOf("lav"), "Lettone"), Row("et", listOf("est"), "Estone"), Row("is", listOf("isl", "ice"), "Islandese"),
    )

    private val byCode: Map<String, Row> = buildMap {
        for (row in rows) { put(row.alpha2, row); row.alpha3.forEach { put(it, row) } }
    }

    /** The two-letter code when the language is known (`ita` → `it`, `pt-BR` → `pt`); other values come back lowercased. */
    fun normalise(code: String?): String {
        val raw = code?.trim()?.lowercase().orEmpty()
        if (raw.isEmpty()) return "und"
        val base = raw.substringBefore('-').substringBefore('_')
        return byCode[base]?.alpha2 ?: base
    }

    /** The Italian name of a language, or the text itself when the code is not known. */
    fun displayName(code: String?): String {
        val raw = code?.trim().orEmpty()
        if (raw.isEmpty() || raw.equals("und", true)) return "Sconosciuta"
        val normalised = normalise(raw)
        return byCode[normalised]?.italian ?: raw.replaceFirstChar { it.uppercase() }
    }

    fun matches(a: String?, b: String?): Boolean = normalise(a) == normalise(b)
}
