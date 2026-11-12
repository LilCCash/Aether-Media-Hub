package app.aether.core.metadata

import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.LocalDate
import java.time.Period
import java.time.format.DateTimeFormatter
import java.util.Locale

/** What a person did in a title. */
enum class PersonRole(val title: String) {
    ACTOR("Attore"), DIRECTOR("Regista"), WRITER("Sceneggiatore"), PRODUCER("Produttore"), COMPOSER("Compositore"), CINEMATOGRAPHER("Fotografia");

    companion object {
        /** The role a TMDB crew job stands for (null for jobs not worth a filter). */
        fun of(job: String?): PersonRole? = when (job?.lowercase()) {
            "director" -> DIRECTOR
            "writer", "screenplay", "story", "novel", "creator", "author" -> WRITER
            "producer", "executive producer" -> PRODUCER
            "original music composer", "composer", "music" -> COMPOSER
            "director of photography", "cinematography" -> CINEMATOGRAPHER
            else -> null
        }
    }
}

/** A title in a person's career, with the roles they had in it. */
data class FilmographyEntry(
    val tmdbId: Int,
    val isMovie: Boolean,
    val title: String,
    val character: String?,
    val roles: List<PersonRole>,
    val poster: String?,
    val year: Int?,
    val genres: List<String>,
    val rating: Double?,
    val popularity: Double,
) {
    val key: String get() = "${if (isMovie) "movie" else "tv"}:$tmdbId"
    val metaType: String get() = if (isMovie) "movie" else "series"
}

/** An award a person received, as Wikidata states it. */
data class PersonAward(val title: String, val year: Int?) {
    val line: String get() = year?.let { "$title ($it)" } ?: title
}

data class PersonProfile(
    val id: Int,
    val name: String,
    val photo: String?,
    val biography: String,
    val birthday: String?,
    val deathday: String?,
    val placeOfBirth: String?,
    val profession: String?,
    val filmography: List<FilmographyEntry>,
    val wikidataId: String? = null,
    val awards: List<PersonAward> = emptyList(),
) {
    val roles: List<PersonRole> get() { val present = filmography.flatMap { it.roles }.toSet(); return PersonRole.entries.filter { it in present } }

    /** "12 aprile 1965 (60 anni)", or with the date of death; null without a date of birth. */
    fun lifeLine(today: LocalDate = LocalDate.now()): String? {
        val born = birthday?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: return null
        val format = DateTimeFormatter.ofPattern("d MMMM yyyy", Locale.ITALIAN)
        val died = deathday?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        return if (died != null) "${born.format(format)} – ${died.format(format)} (${Period.between(born, died).years} anni)"
        else "${born.format(format)} (${Period.between(born, today).years} anni)"
    }

    companion object {
        fun professionName(department: String?): String? = when (department) {
            "Acting" -> "Attore/attrice"
            "Directing" -> "Regista"
            "Writing" -> "Sceneggiatore/trice"
            "Production" -> "Produttore/trice"
            "Sound" -> "Compositore/trice"
            "Camera" -> "Direttore/trice della fotografia"
            null, "" -> null
            else -> department
        }

        /** Talk shows, news and reality are left out: they are «as himself» appearances, not a career. */
        private val excludedGenres = setOf(10767, 10763, 10764)

        val genreNames: Map<Int, String> = mapOf(
            28 to "Azione", 12 to "Avventura", 16 to "Animazione", 35 to "Commedia", 80 to "Crime", 99 to "Documentario", 18 to "Dramma", 10751 to "Famiglia",
            14 to "Fantasy", 36 to "Storia", 27 to "Horror", 10402 to "Musica", 9648 to "Mistero", 10749 to "Romantico", 878 to "Fantascienza", 53 to "Thriller",
            10752 to "Guerra", 37 to "Western", 10759 to "Azione e avventura", 10765 to "Fantascienza e fantasy", 10768 to "Guerra e politica", 10762 to "Bambini",
        )

        /** Builds the profile from TMDB's `/person/{id}` with `combined_credits` and `external_ids` appended. */
        fun fromTmdb(id: Int, detail: JsonObject, fallbackName: String, imageBase: String): PersonProfile {
            val table = LinkedHashMap<String, FilmographyEntry>()
            fun add(entry: JsonObject, role: PersonRole) {
                val tid = entry.int("id") ?: return
                val title = (entry.str("title") ?: entry.str("name"))?.takeIf { it.isNotBlank() } ?: return
                val genres = entry.arr("genre_ids").mapNotNull { (it as? JsonPrimitive)?.content?.toIntOrNull() }
                if (genres.any { it in excludedGenres }) return
                val movie = entry.str("media_type") != "tv"
                val key = "${if (movie) "movie" else "tv"}:$tid"
                val current = table[key] ?: FilmographyEntry(
                    tid, movie, title, null, emptyList(), entry.str("poster_path")?.let { safePath(it) }?.let { "$imageBase/w342$it" },
                    (entry.str("release_date") ?: entry.str("first_air_date"))?.take(4)?.toIntOrNull(), genres.mapNotNull { genreNames[it] },
                    entry.str("vote_average")?.toDoubleOrNull()?.takeIf { it > 0 }, entry.str("popularity")?.toDoubleOrNull() ?: 0.0,
                )
                var updated = if (role in current.roles) current else current.copy(roles = current.roles + role)
                if (role == PersonRole.ACTOR) entry.str("character")?.trim()?.takeIf { it.isNotEmpty() }?.let { updated = updated.copy(character = it) }
                table[key] = updated
            }
            val credits = detail["combined_credits"] as? JsonObject
            for (e in credits?.arr("cast").orEmpty()) {
                val o = e as? JsonObject ?: continue
                if (o.str("poster_path") == null || o.str("character").isNullOrBlank()) continue
                add(o, PersonRole.ACTOR)
            }
            for (e in credits?.arr("crew").orEmpty()) {
                val o = e as? JsonObject ?: continue
                if (o.str("poster_path") == null) continue
                PersonRole.of(o.str("job"))?.let { add(o, it) }
            }
            val sorted = table.values.sortedWith(compareByDescending<FilmographyEntry> { it.popularity }.thenBy { it.title }).take(400)
            return PersonProfile(
                id = id,
                name = detail.str("name") ?: fallbackName,
                photo = detail.str("profile_path")?.let { safePath(it) }?.let { "$imageBase/w500$it" },
                biography = detail.str("biography")?.trim().orEmpty(),
                birthday = detail.str("birthday")?.takeIf { it.isNotBlank() },
                deathday = detail.str("deathday")?.takeIf { it.isNotBlank() },
                placeOfBirth = detail.str("place_of_birth")?.takeIf { it.isNotBlank() },
                profession = professionName(detail.str("known_for_department")),
                filmography = sorted,
                wikidataId = (detail["external_ids"] as? JsonObject)?.str("wikidata_id")?.takeIf { WikidataAwards.validId(it) },
            )
        }

        private fun safePath(path: String) = path.takeIf { it.startsWith("/") && ".." !in it }
    }
}

/** How the filmography is cut. */
data class PersonFilter(val role: PersonRole? = null, val genre: String? = null, val onlyMovies: Boolean? = null, val decade: Int? = null) {
    fun apply(entries: List<FilmographyEntry>): List<FilmographyEntry> = entries.filter { e ->
        (role == null || role in e.roles) && (genre == null || genre in e.genres) && (onlyMovies == null || e.isMovie == onlyMovies) &&
            (decade == null || (e.year != null && e.year / 10 * 10 == decade))
    }

    companion object {
        fun genres(entries: List<FilmographyEntry>): List<String> = entries.flatMap { it.genres }.distinct().sorted()
        fun decades(entries: List<FilmographyEntry>): List<Int> = entries.mapNotNull { it.year?.let { y -> y / 10 * 10 } }.distinct().sortedDescending()
    }
}

/** A person found by a search. */
data class PersonSearchResult(val id: Int, val name: String, val photo: String?, val profession: String?, val knownFor: List<String>)

/** Awards from Wikidata: no key, no account; any failure gives an empty list. */
class WikidataAwards(private val http: HttpClient) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    suspend fun awards(wikidataId: String, language: String, limit: Int = 14): List<PersonAward> {
        if (!validId(wikidataId)) return emptyList()
        val claims = fetch(mapOf("action" to "wbgetentities", "ids" to wikidataId, "props" to "claims", "format" to "json")) ?: return emptyList()
        val found = awardClaims(claims, wikidataId)
        if (found.isEmpty()) return emptyList()
        val ids = found.map { it.first }.distinct().take(50)
        val italian = language.startsWith("it")
        val labels = fetch(mapOf("action" to "wbgetentities", "ids" to ids.joinToString("|"), "props" to "labels", "languages" to if (italian) "it|en" else "en|it", "format" to "json")) ?: return emptyList()
        return awards(found, labels, if (italian) listOf("it", "en") else listOf("en", "it"), limit)
    }

    private suspend fun fetch(query: Map<String, String>): String? = try {
        val url = "https://www.wikidata.org/w/api.php?" + query.toSortedMap().entries.joinToString("&") { "${it.key}=${java.net.URLEncoder.encode(it.value, "UTF-8")}" }
        val response = http.send(HttpRequest(url, headers = mapOf("Accept" to "application/json", "User-Agent" to "Aether/2 (media hub; personal use)"), timeoutSeconds = 15, maxBytes = 6 * 1024 * 1024))
        if (response.isSuccess) response.text else null
    } catch (error: Throwable) {
        if (error is kotlinx.coroutines.CancellationException) throw error
        null
    }

    /** The «award received» (P166) statements: the award's id and the year of «point in time» (P585) when there is one. */
    fun awardClaims(body: String, personId: String): List<Pair<String, Int?>> {
        val root = runCatching { json.parseToJsonElement(body) as? JsonObject }.getOrNull() ?: return emptyList()
        val list = (((root["entities"] as? JsonObject)?.get(personId) as? JsonObject)?.get("claims") as? JsonObject)?.get("P166") as? JsonArray ?: return emptyList()
        return list.mapNotNull { claim ->
            val c = claim as? JsonObject ?: return@mapNotNull null
            val value = ((c["mainsnak"] as? JsonObject)?.get("datavalue") as? JsonObject)?.get("value") as? JsonObject
            val id = value?.str("id")?.takeIf { validId(it) } ?: return@mapNotNull null
            val time = ((((c["qualifiers"] as? JsonObject)?.get("P585") as? JsonArray)?.firstOrNull() as? JsonObject)?.get("datavalue") as? JsonObject)
                ?.let { (it["value"] as? JsonObject)?.str("time") }
            id to time?.trimStart('+', '-')?.take(4)?.toIntOrNull()
        }
    }

    fun awards(claims: List<Pair<String, Int?>>, labels: String, languages: List<String>, limit: Int): List<PersonAward> {
        val entities = runCatching { (json.parseToJsonElement(labels) as? JsonObject)?.get("entities") as? JsonObject }.getOrNull() ?: return emptyList()
        fun title(id: String): String? {
            val l = (entities[id] as? JsonObject)?.get("labels") as? JsonObject ?: return null
            for (lang in languages) (l[lang] as? JsonObject)?.str("value")?.takeIf { it.isNotEmpty() }?.let { return it }
            return null
        }
        val seen = HashSet<String>()
        return claims.mapNotNull { (id, year) -> title(id)?.let { PersonAward(it, year) } }
            .filter { seen.add(it.line) }
            .sortedWith(compareByDescending<PersonAward> { it.year ?: 0 }.thenBy { it.title })
            .take(limit)
    }

    companion object {
        fun validId(id: String) = Regex("^Q[0-9]{1,12}$").matches(id)
    }
}

private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it !is kotlinx.serialization.json.JsonNull }?.content
private fun JsonObject.int(key: String): Int? = str(key)?.toDoubleOrNull()?.toInt()
private fun JsonObject.arr(key: String): List<kotlinx.serialization.json.JsonElement> = (this[key] as? JsonArray)?.toList().orEmpty()
