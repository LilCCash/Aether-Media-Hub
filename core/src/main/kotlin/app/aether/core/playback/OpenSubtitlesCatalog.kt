package app.aether.core.playback

import app.aether.core.json.flexString
import app.aether.core.model.AddonSubtitle
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * The full OpenSubtitles.org catalogue, asked directly (its public REST interface, no account needed), as on the iPhone. The
 * OpenSubtitles v3 addon answers with a small selection: for many titles it has no Italian subtitle while the site has dozens.
 * Only the viewer's languages are asked; the answers are added to the addons' ones.
 */
object OpenSubtitlesCatalog {
    const val NAME = "OpenSubtitles.org"
    /** The catalogue's documented agent for clients without a registered one. */
    const val USER_AGENT = "TemporaryUserAgent"
    private const val BASE = "https://rest.opensubtitles.org/search"
    private val formats = setOf("srt", "ass", "ssa", "vtt", "sub", "txt")
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private val table = mapOf(
        "it" to "ita", "en" to "eng", "fr" to "fre", "de" to "ger", "es" to "spa", "pt" to "por", "nl" to "dut", "ru" to "rus", "ja" to "jpn",
        "ko" to "kor", "zh" to "chi", "ar" to "ara", "pl" to "pol", "tr" to "tur", "sv" to "swe", "no" to "nor", "da" to "dan", "fi" to "fin",
        "el" to "ell", "he" to "heb", "hu" to "hun", "ro" to "rum", "cs" to "cze", "sk" to "slo", "sl" to "slv", "hr" to "hrv", "sr" to "scc",
        "bg" to "bul", "uk" to "ukr", "fa" to "per", "hi" to "hin", "id" to "ind", "ms" to "may", "th" to "tha", "vi" to "vie", "ca" to "cat",
        "et" to "est", "lv" to "lav", "lt" to "lit", "sq" to "alb", "mk" to "mac", "bs" to "bos", "is" to "ice", "ga" to "gle", "eu" to "baq",
        "gl" to "glg", "bn" to "ben", "ta" to "tam", "te" to "tel", "ur" to "urd", "ka" to "geo", "hy" to "arm", "az" to "aze", "kk" to "kaz",
    )

    /** The catalogue's language code (ISO 639-2/B) for a language of the app ("it", "ita", "pt-BR"…), or null. */
    fun catalogLanguage(raw: String?): String? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty() || trimmed.equals("off", true) || trimmed.equals("und", true)) return null
        if (trimmed.equals("pt-BR", true) || trimmed.equals("pob", true)) return "pob"
        val base = Languages.normalise(trimmed)
        return table[base] ?: base.takeIf { it.length == 3 && it.all(Char::isLetter) }
    }

    /** The search for one language: `tt0111161` for a film, `tt0944947:1:3` for an episode; parameters in alphabetical order. */
    fun searchUrl(videoId: String, language: String): String? {
        val parts = videoId.split(':')
        val first = parts.first()
        if (!first.startsWith("tt") || first.length <= 2) return null
        val digits = first.drop(2)
        if (!digits.all(Char::isDigit)) return null
        val segments = ArrayList<String>()
        val season = parts.getOrNull(1)?.toIntOrNull()
        val episode = parts.getOrNull(2)?.toIntOrNull()
        if (season != null && episode != null) {
            segments += "episode-$episode"; segments += "imdbid-$digits"; segments += "season-$season"
        } else segments += "imdbid-$digits"
        segments += "sublanguageid-$language"
        return BASE + "/" + segments.joinToString("/")
    }

    val headers: Map<String, String> = mapOf("User-Agent" to USER_AGENT, "X-User-Agent" to USER_AGENT, "Accept" to "application/json")

    /** The subtitles of an answer, most downloaded first, one per file, at most [limit]. */
    fun parse(body: String, limit: Int = 25): List<AddonSubtitle> {
        val list = runCatching { json.parseToJsonElement(body) as? JsonArray }.getOrNull() ?: return emptyList()
        val seen = HashSet<String>()
        val found = ArrayList<Pair<AddonSubtitle, Int>>()
        for (element in list) {
            val item = element as? JsonObject ?: continue
            val link = item.flexString("SubDownloadLink")?.trim() ?: continue
            if (!link.startsWith("https://")) continue
            val language = item.flexString("SubLanguageID")?.trim().orEmpty()
            if (language.isEmpty()) continue
            val format = (item.flexString("SubFormat") ?: "srt").lowercase()
            if (format !in formats) continue
            val fileId = item.flexString("IDSubtitleFile") ?: link
            if (!seen.add(fileId)) continue
            var label = item.flexString("MovieReleaseName")?.trim()?.takeIf { it.isNotEmpty() } ?: item.flexString("SubFileName")?.trim()?.takeIf { it.isNotEmpty() } ?: NAME
            if (item.flexString("SubHearingImpaired") == "1") label += " · non udenti"
            val downloads = item.flexString("SubDownloadsCnt")?.toIntOrNull() ?: 0
            found += AddonSubtitle(id = "osorg-$fileId", url = link, lang = language, label = label, addonName = NAME) to downloads
        }
        return found.sortedByDescending { it.second }.take(limit.coerceAtLeast(0)).map { it.first }
    }

    /** Asks the catalogue in each language (in parallel); a language that fails is left out. */
    suspend fun search(http: HttpClient, videoId: String, languages: List<String>, limitPerLanguage: Int = 15): List<AddonSubtitle> = coroutineScope {
        languages.mapNotNull { catalogLanguage(it) }.distinct().map { lang ->
            async {
                val url = searchUrl(videoId, lang) ?: return@async emptyList()
                try {
                    val response = http.send(HttpRequest(url, headers = headers, timeoutSeconds = 12))
                    if (response.isSuccess) parse(response.text, limitPerLanguage) else emptyList()
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    emptyList()
                }
            }
        }.flatMap { it.await() }
    }
}
