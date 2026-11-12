package app.aether.core.metadata

import kotlinx.coroutines.async
import app.aether.core.model.ExternalIds
import app.aether.core.model.MetaItem
import app.aether.core.model.TrailerRef
import app.aether.core.model.Video
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import app.aether.core.util.SecretStore
import java.net.URLEncoder
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** What the title page shows beyond an addon's meta, read from TMDB with the user's own key. Empty sections are not shown. */
data class RichDetails(
    val tmdbId: Int,
    val isMovie: Boolean,
    val cast: List<Person> = emptyList(),
    val directors: List<String> = emptyList(),
    val creators: List<String> = emptyList(),
    val companies: List<String> = emptyList(),
    val budget: Long? = null,
    val revenue: Long? = null,
    val trailers: List<TrailerRef> = emptyList(),
    val similar: List<Similar> = emptyList(),
    val status: String? = null,
    val countries: List<String> = emptyList(),
    val originalLanguage: String? = null,
    val seasonCount: Int? = null,
    val episodeCount: Int? = null,
    val tagline: String? = null,
    /** The saga the film belongs to (TMDB collection). */
    val collectionId: Int? = null,
    val collectionName: String? = null,
    /** Who made it behind the camera: direction, writing, music, photography. */
    val crew: List<Person> = emptyList(),
    val releaseDate: String? = null,
    val runtimeMinutes: Int? = null,
    val voteAverage: Double? = null,
    val keywords: List<String> = emptyList(),
) {
    data class Person(val name: String, val role: String?, val photo: String?, val id: Int? = null)
    data class Credit(val tmdbId: Int, val isMovie: Boolean, val title: String, val character: String?, val poster: String?, val year: String?)
    data class Similar(val tmdbId: Int, val title: String, val poster: String?, val year: String?, val isMovie: Boolean)
    /** A saga: its films in order of release. */
    data class Collection(val id: Int, val name: String, val overview: String?, val poster: String?, val backdrop: String?, val parts: List<Part>)
    data class Part(val tmdbId: Int, val title: String, val poster: String?, val backdrop: String?, val releaseDate: String?, val overview: String?) {
        val year: String? get() = releaseDate?.take(4)?.takeIf { it.length == 4 }
    }

    val isEmpty: Boolean
        get() = cast.isEmpty() && directors.isEmpty() && creators.isEmpty() && companies.isEmpty() && budget == null &&
            revenue == null && trailers.isEmpty() && similar.isEmpty() && status == null
}

/**
 * Optional metadata from TMDB (v3 key or v4 read token) and TheTVDB (v4 key, optional subscriber PIN). Keys come from the
 * encrypted [SecretStore] and are never logged. Addon metadata stays the source of truth for ids and streams: the providers fill
 * what is missing and add the rich section.
 */
class MetadataEnrichment(private val http: HttpClient, private val secrets: SecretStore, private val language: () -> String = { "it-IT" }) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val richCache = ConcurrentHashMap<String, RichDetails>()
    private val episodeCache = ConcurrentHashMap<String, List<TvdbEpisode>>()
    private val tvdbIdCache = ConcurrentHashMap<String, Int>()
    @Volatile private var tvdbToken: Pair<String, String>? = null

    val hasTmdb: Boolean get() = tmdbKey().isNotEmpty()
    val hasTvdb: Boolean get() = tvdbKey().isNotEmpty()

    private fun tmdbKey() = secrets.get(TMDbKey).orEmpty().trim()
    private fun tvdbKey() = secrets.get(TVDbKey).orEmpty().trim()
    private fun tvdbPin() = secrets.get(TVDbPin).orEmpty().trim()

    private class ProviderError(message: String) : Exception(message)

    // MARK: Public

    /** Fills the missing descriptive fields from TMDB, then from TheTVDB; episode thumbnails and summaries come from TheTVDB. */
    suspend fun enrich(meta: MetaItem): MetaItem {
        if (!isTitle(meta)) return meta
        var result = meta
        if (hasTmdb) result = runCatching { applyTmdb(result) }.getOrDefault(result)
        if (hasTvdb) result = runCatching { applyTvdb(result) }.getOrDefault(result)
        return result
    }

    /** The rich section for the title page, or null when TMDB is not configured or knows nothing. */
    suspend fun rich(meta: MetaItem): RichDetails? {
        if (!hasTmdb || !isTitle(meta)) return null
        return runCatching { loadRich(meta) }.getOrNull()?.takeIf { !it.isEmpty }
    }

    /** The IMDb id of a similar title, so it can be opened like any catalog entry. */
    suspend fun imdbIdFor(similar: RichDetails.Similar): String? = imdbIdFor(similar.tmdbId, similar.isMovie)

    suspend fun imdbIdFor(tmdbId: Int, isMovie: Boolean): String? = runCatching {
        tmdbGet("/${if (isMovie) "movie" else "tv"}/$tmdbId/external_ids").str("imdb_id")?.takeIf { it.isNotBlank() }
    }.getOrNull()

    /** What a person appeared in (most known first), with the character they played. */
    suspend fun personCredits(personId: Int): List<RichDetails.Credit> = runCatching {
        val rows = tmdbGet("/person/$personId/combined_credits").arr("cast")
        rows.filter { r -> r.str("poster_path") != null && !r.str("character").isNullOrBlank() && r.arr("genre_ids").none { it.int() in setOf(10767, 10763, 10764) } }
            .sortedByDescending { it.dbl("popularity") ?: 0.0 }
            .take(80)
            .mapNotNull { r ->
                val id = r.int("id") ?: return@mapNotNull null
                val movie = r.str("media_type") != "tv"
                RichDetails.Credit(id, movie, r.str("title") ?: r.str("name") ?: return@mapNotNull null, r.str("character"), r.str("poster_path")?.let { "$IMAGE_BASE/w342$it" },
                    (r.str("release_date") ?: r.str("first_air_date"))?.take(4))
            }
    }.getOrDefault(emptyList())

    private val wikidata = WikidataAwards(http)
    private val profileCache = ConcurrentHashMap<Int, PersonProfile>()

    /** A person's page: biography, life, the whole filmography (as actor and behind the camera) and the awards from Wikidata. */
    suspend fun personProfile(personId: Int, fallbackName: String): PersonProfile? {
        profileCache[personId]?.let { return it }
        val detail = runCatching { tmdbGet("/person/$personId", "append_to_response" to "combined_credits,external_ids") }.getOrNull() ?: return null
        if (detail.isEmpty()) return null
        var profile = PersonProfile.fromTmdb(personId, detail, fallbackName, IMAGE_BASE)
        // An empty Italian biography falls back to the English one.
        if (profile.biography.isEmpty() && !language().startsWith("en")) {
            runCatching { tmdbGet("/person/$personId", "language" to "en-US").str("biography") }.getOrNull()?.trim()?.takeIf { it.isNotEmpty() }?.let { profile = profile.copy(biography = it) }
        }
        profile.wikidataId?.let { profile = profile.copy(awards = wikidata.awards(it, language())) }
        profileCache[personId] = profile
        return profile
    }

    /** People whose name matches, the best known first (only those with a photo, as on the iPhone). */
    suspend fun searchPeople(query: String, limit: Int = 12): List<PersonSearchResult> {
        if (!hasTmdb || query.isBlank()) return emptyList()
        return runCatching {
            tmdbGet("/search/person", "query" to query.trim(), "include_adult" to "false").arr("results")
                .filter { it.int("id") != null && !it.str("name").isNullOrBlank() && it.str("profile_path") != null }
                .distinctBy { it.int("id") }
                .sortedByDescending { it.dbl("popularity") ?: 0.0 }
                .take(limit)
                .map { r ->
                    PersonSearchResult(
                        r.int("id")!!, r.str("name")!!, r.str("profile_path")?.takeIf { it.startsWith("/") && ".." !in it }?.let { "$IMAGE_BASE/w185$it" },
                        PersonProfile.professionName(r.str("known_for_department")),
                        r.arr("known_for").mapNotNull { it.str("title") ?: it.str("name") }.take(3),
                    )
                }
        }.getOrDefault(emptyList())
    }

    /** What an advanced search found: openable titles (IMDb ids) and short notes on how the request was read. */
    data class DiscoverOutcome(val items: List<MetaItem>, val notes: List<String>)

    /**
     * Runs a [app.aether.core.search.SearchIntent] on TMDB: «similar to» through its recommendations, otherwise discover with genres,
     * keywords, years, rating, countries and length. Every result gets its IMDb id so the addons can play it.
     */
    suspend fun discover(intent: app.aether.core.search.SearchIntent, limit: Int = 40): DiscoverOutcome = kotlinx.coroutines.coroutineScope {
        if (!hasTmdb) return@coroutineScope DiscoverOutcome(emptyList(), listOf("La ricerca avanzata usa TMDB: aggiungi la chiave nelle impostazioni."))
        val notes = ArrayList<String>()
        val kinds = when (intent.kind) { app.aether.core.search.IntentKind.MOVIE -> listOf("movie"); app.aether.core.search.IntentKind.SERIES -> listOf("tv"); null -> listOf("movie", "tv") }
        val found = ArrayList<Pair<String, JsonElement>>()
        val reference = intent.similarTo
        if (reference != null) {
            for (kind in kinds) {
                val match = runCatching { tmdbGet("/search/$kind", "query" to reference).arr("results").firstOrNull() }.getOrNull() ?: continue
                val id = match.int("id") ?: continue
                val list = runCatching { tmdbGet("/$kind/$id/recommendations").arr("results") }.getOrDefault(emptyList())
                found += list.filter { it.int("id") != id }.map { kind to it }
                notes += "Titolo di partenza: «${match.str("title") ?: match.str("name") ?: reference}»" + ((match.str("release_date") ?: match.str("first_air_date"))?.take(4)?.let { " ($it)" } ?: "") + "."
                break
            }
            if (notes.isEmpty()) notes += "Non ho trovato «$reference» su TMDB."
        } else {
            val keywordIds = intent.keywords.take(4).mapNotNull { word -> runCatching { tmdbGet("/search/keyword", "query" to word).arr("results").firstOrNull()?.int("id") }.getOrNull() }
            suspend fun fetch(withKeywords: List<Int>): List<Pair<String, JsonElement>> = kinds.map { kind ->
                async {
                    val q = ArrayList<Pair<String, String>>()
                    q += "include_adult" to "false"; q += "page" to "1"
                    val genreIds = intent.genres.mapNotNull { if (kind == "movie") it.movieId else it.tvId }.distinct()
                    if (genreIds.size < intent.genres.size && kind == "tv") synchronized(notes) { notes += "Per le serie TMDB non ha alcuni generi richiesti: li ho ignorati." }
                    if (genreIds.isNotEmpty()) q += "with_genres" to genreIds.sorted().joinToString(",")
                    if (withKeywords.isNotEmpty()) q += "with_keywords" to withKeywords.joinToString("|")
                    val dateKey = if (kind == "movie") "primary_release_date" else "first_air_date"
                    intent.yearFrom?.let { q += "$dateKey.gte" to "$it-01-01" }
                    intent.yearTo?.let { q += "$dateKey.lte" to "$it-12-31" }
                    intent.minRating?.let { q += "vote_average.gte" to "%.1f".format(java.util.Locale.ROOT, it) }
                    if (intent.countries.isNotEmpty()) q += "with_origin_country" to intent.countries.joinToString("|")
                    if (kind == "movie") intent.maxRuntime?.let { q += "with_runtime.lte" to "$it" }
                    when (intent.sort) {
                        app.aether.core.search.IntentSort.POPULARITY -> { q += "sort_by" to "popularity.desc"; q += "vote_count.gte" to "20" }
                        app.aether.core.search.IntentSort.RATING -> { q += "sort_by" to "vote_average.desc"; q += "vote_count.gte" to "200" }
                        app.aether.core.search.IntentSort.NEWEST -> { q += "sort_by" to "$dateKey.desc"; q += "vote_count.gte" to "30" }
                        app.aether.core.search.IntentSort.OLDEST -> { q += "sort_by" to "$dateKey.asc"; q += "vote_count.gte" to "200" }
                    }
                    runCatching { tmdbGet("/discover/$kind", *q.toTypedArray()).arr("results") }.getOrDefault(emptyList()).map { kind to it }
                }
            }.flatMap { it.await() }
            found += fetch(keywordIds)
            if (intent.keywords.isNotEmpty() && keywordIds.isEmpty()) notes += "Nessuna parola chiave TMDB corrisponde a «${intent.keywords.joinToString()}»: ho usato solo gli altri filtri."
            if (keywordIds.isNotEmpty() && found.size < limit) {
                val seen = found.map { "${it.first}-${it.second.int("id")}" }.toHashSet()
                val more = fetch(emptyList()).filter { seen.add("${it.first}-${it.second.int("id")}") }
                if (more.isNotEmpty()) notes += "Prima i titoli con la parola chiave, poi altri dello stesso genere."
                found += more
            }
            // Movies and series alternate, so neither kind hides the other.
            if (kinds.size == 2) {
                val movies = found.filter { it.first == "movie" }; val shows = found.filter { it.first == "tv" }
                found.clear(); for (i in 0 until maxOf(movies.size, shows.size)) { movies.getOrNull(i)?.let { found += it }; shows.getOrNull(i)?.let { found += it } }
            }
        }
        val items = found.take(limit + 8).map { (kind, item) ->
            async {
                val id = item.int("id") ?: return@async null
                val imdb = imdbIdFor(id, kind == "movie") ?: return@async null
                val title = item.str("title") ?: item.str("name") ?: return@async null
                fun image(path: String?, size: String) = path?.takeIf { it.startsWith("/") && ".." !in it }?.let { "$IMAGE_BASE/$size$it" }
                MetaItem(
                    imdb, if (kind == "movie") "movie" else "series", title, poster = image(item.str("poster_path"), "w342"), background = image(item.str("backdrop_path"), "w780"),
                    description = item.str("overview"), releaseInfo = (item.str("release_date") ?: item.str("first_air_date"))?.take(4)?.takeIf { it.length == 4 },
                    imdbRating = item.dbl("vote_average")?.takeIf { it > 0 }?.let { "%.1f".format(java.util.Locale.ROOT, it) },
                    externalIds = app.aether.core.model.ExternalIds(imdb = imdb, tmdb = id),
                )
            }
        }.mapNotNull { it.await() }
        val seen = HashSet<String>()
        DiscoverOutcome(items.filter { seen.add(it.id) }.take(limit), notes)
    }

    private val collectionCache = ConcurrentHashMap<Int, RichDetails.Collection>()

    /** The films of a saga, in order of release (unreleased ones last). */
    suspend fun collection(id: Int): RichDetails.Collection? {
        collectionCache[id]?.let { return it }
        val d = runCatching { tmdbGet("/collection/$id") }.getOrNull()?.takeIf { it.isNotEmpty() } ?: return null
        fun image(path: String?, size: String) = path?.takeIf { it.startsWith("/") && ".." !in it }?.let { "$IMAGE_BASE/$size$it" }
        val parts = d.arr("parts").mapNotNull { p ->
            RichDetails.Part(p.int("id") ?: return@mapNotNull null, p.str("title") ?: p.str("name") ?: return@mapNotNull null, image(p.str("poster_path"), "w342"), image(p.str("backdrop_path"), "w780"), p.str("release_date")?.takeIf { it.isNotBlank() }, p.str("overview"))
        }.sortedWith(compareBy<RichDetails.Part> { it.releaseDate == null }.thenBy { it.releaseDate })
        val c = RichDetails.Collection(id, d.str("name") ?: "Saga", d.str("overview"), image(d.str("poster_path"), "w342"), image(d.str("backdrop_path"), "w1280"), parts)
        collectionCache[id] = c
        return c
    }

    private val logoCache = ConcurrentHashMap<String, String>()

    /** The title's transparent logo from fanart.tv (movies by IMDb/TMDB id, series by TheTVDB id), or null. */
    suspend fun titleLogo(meta: MetaItem): String? {
        val series = meta.type in SERIES
        val id = if (series) meta.externalIds.tvdb?.toString() else (meta.imdbId ?: meta.externalIds.imdb ?: meta.externalIds.tmdb?.toString())
        if (id == null) return null
        val cacheKey = "${meta.type}:$id"
        logoCache[cacheKey]?.let { return it.takeIf { u -> u.isNotEmpty() } }
        val key = secrets.get(FanartKey)?.takeIf { it.isNotBlank() } ?: return null
        val found = runCatching {
            val response = http.send(HttpRequest("https://webservice.fanart.tv/v3/${if (series) "tv" else "movies"}/$id?api_key=${enc(key)}", headers = mapOf("Accept" to "application/json"), timeoutSeconds = 6, maxBytes = 1024 * 1024))
            if (!response.isSuccess) null else {
                val root = json.parseToJsonElement(response.text) as? JsonObject
                val logos = listOf("hdmovielogo", "hdtvlogo", "movielogo", "clearlogo").flatMap { root?.arr(it).orEmpty() }
                val wanted = language().take(2)
                logos.sortedWith(compareByDescending<JsonElement> { it.str("lang") == wanted }.thenByDescending { it.str("lang") == "en" }.thenByDescending { it.str("likes")?.toIntOrNull() ?: 0 })
                    .firstNotNullOfOrNull { it.str("url")?.takeIf { u -> u.startsWith("https://") } }
            }
        }.getOrNull()
        logoCache[cacheKey] = found.orEmpty()
        return found
    }

    /** Settings: null when the key is accepted, else a short reason. */
    suspend fun checkTmdb(): String? = try { tmdbGet("/configuration"); null } catch (e: Throwable) { reason(e) }
    suspend fun checkTvdb(): String? = try { tvdbBearer(force = true); null } catch (e: Throwable) { reason(e) }

    private val summaryCache = ConcurrentHashMap<String, MetaItem>()

    /**
     * A light fill for shelves (Trakt, lists): name, plot, poster and backdrop from one TMDB call, in the viewer's language.
     * Without a TMDB key, or on any failure, the item comes back as it was.
     */
    suspend fun summary(meta: MetaItem): MetaItem {
        val id = meta.externalIds.tmdb ?: return meta
        if (!hasTmdb) return meta
        val kind = if (isSeries(meta)) "tv" else "movie"
        val cacheKey = "$kind-$id-${language()}"
        summaryCache[cacheKey]?.let { return it }
        val detail = runCatching { tmdbGet("/$kind/$id") }.getOrNull() ?: return meta
        fun image(path: String?, size: String) = path?.takeIf { it.startsWith("/") && ".." !in it }?.let { "$IMAGE_BASE/$size$it" }
        val filled = meta.copy(
            name = detail.str(if (kind == "tv") "name" else "title")?.takeIf { it.isNotBlank() } ?: meta.name,
            description = meta.description ?: detail.str("overview")?.takeIf { it.isNotBlank() },
            poster = meta.poster ?: image(detail.str("poster_path"), "w342"),
            background = meta.background ?: image(detail.str("backdrop_path"), "w780"),
        )
        if (summaryCache.size > 1500) summaryCache.clear()
        summaryCache[cacheKey] = filled
        return filled
    }

    fun clearCaches() {
        summaryCache.clear(); richCache.clear(); episodeCache.clear(); tvdbIdCache.clear(); tvdbToken = null }

    private fun isTitle(meta: MetaItem) = meta.type in SERIES || meta.type == "movie"
    private fun reason(e: Throwable) = (e as? ProviderError)?.message ?: app.aether.core.net.AddonError.from(e).message

    // MARK: TMDB

    private fun isSeries(meta: MetaItem) = meta.type in SERIES

    private suspend fun resolveTmdb(meta: MetaItem): Pair<String, Int>? {
        val kind = if (isSeries(meta)) "tv" else "movie"
        meta.externalIds.tmdb?.let { return kind to it }
        val imdb = meta.externalIds.imdb ?: meta.imdbId
        if (imdb != null) {
            val found = tmdbGet("/find/$imdb", "external_source" to "imdb_id")
            val hit = found.arr(if (kind == "tv") "tv_results" else "movie_results").firstOrNull()?.int("id")
            if (hit != null) return kind to hit
        }
        val year = meta.year?.let { if (kind == "tv") "first_air_date_year" to "$it" else "year" to "$it" }
        val query = listOfNotNull("query" to meta.name, year)
        val hit = tmdbGet("/search/$kind", *query.toTypedArray()).arr("results").firstOrNull()?.int("id") ?: return null
        return kind to hit
    }

    private suspend fun tmdbDetails(kind: String, id: Int): JsonObject = tmdbGet(
        "/$kind/$id",
        "append_to_response" to "credits,videos,similar,external_ids,keywords,recommendations",
        "include_video_language" to "${language().take(2)},en,null",
    )

    private suspend fun applyTmdb(meta: MetaItem): MetaItem {
        val (kind, id) = resolveTmdb(meta) ?: return meta
        val detail = tmdbDetails(kind, id)
        val series = kind == "tv"
        val credits = detail.obj("credits")
        val genres = detail.arr("genres").mapNotNull { it.str("name") }
        val cast = credits?.arr("cast").orEmpty().take(12).mapNotNull { it.str("name") }
        val directors = credits?.arr("crew").orEmpty().filter { it.str("job") == "Director" }.take(4).mapNotNull { it.str("name") }
        val date = detail.str(if (series) "first_air_date" else "release_date")
        val external = detail.obj("external_ids")
        val trailers = trailersOf(detail)
        return meta.copy(
            poster = meta.poster ?: detail.str("poster_path")?.let { "$IMAGE_BASE/w500$it" },
            background = meta.background ?: detail.str("backdrop_path")?.let { "$IMAGE_BASE/w1280$it" },
            // The viewer's language wins over the addon's text (Cinemeta is English).
            description = detail.str("overview")?.takeIf { it.isNotBlank() } ?: meta.description?.takeIf { it.isNotBlank() },
            releaseInfo = meta.releaseInfo ?: date?.take(4),
            imdbRating = meta.imdbRating ?: detail.dbl("vote_average")?.takeIf { it > 0 }?.let { "%.1f".format(java.util.Locale.US, it) },
            releasedMillis = meta.releasedMillis ?: dateMillis(date),
            runtime = meta.runtime ?: (detail.int("runtime") ?: detail.arr("episode_run_time").firstOrNull()?.int())?.let { "$it min" },
            genres = genres.ifEmpty { meta.genres },
            cast = meta.cast.ifEmpty { cast },
            directors = meta.directors.ifEmpty { directors },
            trailers = meta.trailers.ifEmpty { trailers },
            externalIds = meta.externalIds.filling(ExternalIds(imdb = external?.str("imdb_id")?.takeIf { it.isNotBlank() }, tmdb = id, tvdb = external?.int("tvdb_id"))),
        )
    }

    private suspend fun loadRich(meta: MetaItem): RichDetails? {
        val (kind, id) = resolveTmdb(meta) ?: return null
        richCache["$kind:$id"]?.let { return it }
        val detail = tmdbDetails(kind, id)
        val series = kind == "tv"
        val credits = detail.obj("credits")
        val rich = RichDetails(
            tmdbId = id, isMovie = !series,
            cast = credits?.arr("cast").orEmpty().take(16).mapNotNull { p ->
                RichDetails.Person(p.str("name") ?: return@mapNotNull null, p.str("character")?.takeIf { it.isNotBlank() }, p.str("profile_path")?.let { "$IMAGE_BASE/w185$it" }, p.int("id"))
            }.distinctBy { it.name + it.role.orEmpty() },
            directors = if (series) emptyList() else credits?.arr("crew").orEmpty().filter { it.str("job") == "Director" }.mapNotNull { it.str("name") }.distinct(),
            creators = detail.arr("created_by").mapNotNull { it.str("name") },
            companies = detail.arr("production_companies").mapNotNull { it.str("name") }.take(6),
            budget = if (series) null else detail.lng("budget")?.takeIf { it > 0 },
            revenue = if (series) null else detail.lng("revenue")?.takeIf { it > 0 },
            trailers = trailersOf(detail),
            similar = detail.obj("similar")?.arr("results").orEmpty().take(16).mapNotNull { s ->
                val sid = s.int("id") ?: return@mapNotNull null
                RichDetails.Similar(sid, s.str("title") ?: s.str("name") ?: return@mapNotNull null, s.str("poster_path")?.let { "$IMAGE_BASE/w342$it" },
                    (s.str("release_date") ?: s.str("first_air_date"))?.take(4), !series)
            }.filter { it.poster != null }.distinctBy { it.tmdbId },
            status = detail.str("status")?.takeIf { it.isNotBlank() },
            countries = detail.arr("production_countries").mapNotNull { it.str("name") },
            originalLanguage = detail.str("original_language"),
            seasonCount = detail.int("number_of_seasons"),
            episodeCount = detail.int("number_of_episodes"),
            tagline = detail.str("tagline")?.trim()?.takeIf { it.isNotEmpty() },
            collectionId = detail.obj("belongs_to_collection")?.int("id"),
            collectionName = detail.obj("belongs_to_collection")?.str("name"),
            crew = credits?.arr("crew").orEmpty().mapNotNull { p ->
                val job = p.str("job") ?: return@mapNotNull null
                val label = when (job) { "Director" -> "Regia"; "Screenplay", "Writer" -> "Sceneggiatura"; "Original Music Composer" -> "Musiche"; "Director of Photography" -> "Fotografia"; "Novel" -> "Romanzo"; else -> null } ?: return@mapNotNull null
                RichDetails.Person(p.str("name") ?: return@mapNotNull null, label, p.str("profile_path")?.let { "$IMAGE_BASE/w185$it" }, p.int("id"))
            }.distinctBy { it.name + it.role }.take(10),
            releaseDate = detail.str("release_date") ?: detail.str("first_air_date"),
            runtimeMinutes = detail.int("runtime") ?: detail.arr("episode_run_time").firstOrNull()?.int(),
            voteAverage = detail.dbl("vote_average")?.takeIf { it > 0 },
            keywords = (detail.obj("keywords")?.arr("keywords").orEmpty() + detail.obj("keywords")?.arr("results").orEmpty()).mapNotNull { it.str("name") }.take(12),
        )
        richCache["$kind:$id"] = rich
        return rich
    }

    private fun trailersOf(detail: JsonObject): List<TrailerRef> = detail.obj("videos")?.arr("results").orEmpty()
        .filter { it.str("site") == "YouTube" && it.str("type") in setOf("Trailer", "Teaser") }
        .sortedByDescending { it.str("type") == "Trailer" }
        .mapNotNull { v -> v.str("key")?.takeIf { k -> k.all { it.isLetterOrDigit() || it == '-' || it == '_' } }?.let { TrailerRef(it, v.str("type") ?: "Trailer") } }
        .take(4)

    private suspend fun tmdbGet(path: String, vararg query: Pair<String, String>): JsonObject {
        val key = tmdbKey()
        if (key.isEmpty()) throw ProviderError("Chiave TMDB non impostata.")
        val bearer = key.startsWith("eyJ") && key.count { it == '.' } == 2
        val params = buildList {
            if (query.none { it.first == "language" }) add("language" to language())
            addAll(query)
            if (!bearer) add("api_key" to key)
        }
        val url = "https://api.themoviedb.org/3$path?" + params.joinToString("&") { "${it.first}=${enc(it.second)}" }
        val response = http.send(HttpRequest(url, headers = if (bearer) mapOf("Authorization" to "Bearer $key", "Accept" to "application/json") else mapOf("Accept" to "application/json"), timeoutSeconds = 12, maxBytes = 2 * 1024 * 1024))
        when {
            response.status == 401 || response.status == 403 -> throw ProviderError("TMDB non accetta la chiave (controlla di aver copiato la chiave API v3 o il token di lettura v4).")
            response.status == 404 -> return JsonObject(emptyMap())
            response.status == 429 -> throw ProviderError("TMDB: troppe richieste, riprova tra poco.")
            !response.isSuccess -> throw ProviderError("TMDB ha risposto con errore HTTP ${response.status}.")
        }
        return json.parseToJsonElement(response.text) as? JsonObject ?: throw ProviderError("Risposta TMDB non valida.")
    }

    // MARK: TheTVDB

    data class TvdbEpisode(val season: Int, val number: Int, val name: String?, val overview: String?, val image: String?)

    private suspend fun tvdbBearer(force: Boolean = false): String {
        val key = tvdbKey()
        if (key.isEmpty()) throw ProviderError("Chiave TheTVDB non impostata.")
        val pin = tvdbPin()
        val fingerprint = "$key|$pin"
        tvdbToken?.takeIf { !force && it.first == fingerprint }?.let { return it.second }
        val body = buildJsonObject { put("apikey", key); if (pin.isNotEmpty()) put("pin", pin) }.toString()
        val response = http.send(HttpRequest("https://api4.thetvdb.com/v4/login", method = "POST", body = body, contentType = "application/json", headers = mapOf("Accept" to "application/json"), timeoutSeconds = 12))
        when {
            response.status == 401 || response.status == 403 -> throw ProviderError("TheTVDB non accetta la chiave (o il PIN). Serve la chiave API v4; se è di un abbonato aggiungi anche il PIN.")
            !response.isSuccess -> throw ProviderError("TheTVDB ha risposto con errore HTTP ${response.status}.")
        }
        val token = (json.parseToJsonElement(response.text) as? JsonObject)?.obj("data")?.str("token") ?: throw ProviderError("Risposta TheTVDB non valida.")
        tvdbToken = fingerprint to token
        return token
    }

    private suspend fun tvdbGet(path: String): JsonObject? {
        repeat(2) { attempt ->
            val response = http.send(HttpRequest("https://api4.thetvdb.com/v4$path", headers = mapOf("Authorization" to "Bearer ${tvdbBearer(force = attempt > 0)}", "Accept" to "application/json"), timeoutSeconds = 12, maxBytes = 4 * 1024 * 1024))
            if (response.status == 401 && attempt == 0) return@repeat
            if (response.status == 404) return null
            if (!response.isSuccess) throw ProviderError("TheTVDB ha risposto con errore HTTP ${response.status}.")
            return json.parseToJsonElement(response.text) as? JsonObject
        }
        return null
    }

    private suspend fun tvdbId(meta: MetaItem): Int? {
        meta.externalIds.tvdb?.let { return it }
        val imdb = meta.externalIds.imdb ?: meta.imdbId ?: return null
        tvdbIdCache[imdb]?.let { return it }
        val rows = tvdbGet("/search/remoteid/$imdb")?.arr("data").orEmpty()
        val id = rows.firstNotNullOfOrNull { (it.obj("series") ?: it.obj("movie"))?.int("id") } ?: return null
        tvdbIdCache[imdb] = id
        return id
    }

    private suspend fun applyTvdb(meta: MetaItem): MetaItem {
        val needsBasics = meta.description.isNullOrBlank() || meta.poster.isNullOrBlank() || meta.background.isNullOrBlank()
        val series = isSeries(meta)
        val id = tvdbId(meta) ?: return meta
        var result = meta
        if (needsBasics) {
            val detail = tvdbGet("/${if (series) "series" else "movies"}/$id/extended?short=true")?.obj("data")
            if (detail != null) {
                val date = detail.str("firstAired") ?: detail.str("releaseDate") ?: detail.arr("releases").firstOrNull()?.str("date")
                result = result.copy(
                    poster = result.poster ?: detail.str("image"),
                    description = result.description?.takeIf { it.isNotBlank() } ?: detail.str("overview"),
                    releaseInfo = result.releaseInfo ?: date?.take(4),
                    genres = result.genres.ifEmpty { detail.arr("genres").mapNotNull { it.str("name") } },
                    externalIds = result.externalIds.filling(ExternalIds(tvdb = id)),
                )
            }
        }
        if (series && result.videos.any { it.isEpisode && (it.thumbnail == null || it.overview.isNullOrBlank()) }) {
            val episodes = episodeCache.getOrPut("$id") { loadTvdbEpisodes(id) }
            if (episodes.isNotEmpty()) {
                val index = episodes.associateBy { it.season to it.number }
                result = result.copy(videos = result.videos.map { v ->
                    val e = if (v.season != null && v.episode != null) index[v.season to v.episode] else null
                    if (e == null) v else v.copy(
                        thumbnail = v.thumbnail ?: e.image,
                        overview = v.overview?.takeIf { it.isNotBlank() } ?: e.overview,
                        title = v.title.ifBlank { e.name.orEmpty() },
                    )
                })
            }
        }
        return result
    }

    private suspend fun loadTvdbEpisodes(id: Int): List<TvdbEpisode> {
        val all = mutableListOf<TvdbEpisode>()
        for (page in 0 until 8) {
            val data = tvdbGet("/series/$id/episodes/default?page=$page") ?: break
            val rows = data.obj("data")?.arr("episodes").orEmpty()
            if (rows.isEmpty()) break
            rows.forEach { r ->
                val s = r.int("seasonNumber") ?: return@forEach
                val n = r.int("number") ?: return@forEach
                all += TvdbEpisode(s, n, r.str("name"), r.str("overview"), r.str("image"))
            }
            if (data.obj("links")?.str("next") == null) break
        }
        return all
    }

    // MARK: Helpers

    private fun dateMillis(value: String?): Long? = runCatching { LocalDate.parse(value).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
    private fun enc(value: String) = URLEncoder.encode(value, "UTF-8")

    private fun JsonElement.obj(key: String): JsonObject? = (this as? JsonObject)?.get(key) as? JsonObject
    private fun JsonElement.arr(key: String): List<JsonElement> = ((this as? JsonObject)?.get(key) as? JsonArray)?.toList().orEmpty()
    private fun JsonElement.str(key: String): String? = ((this as? JsonObject)?.get(key) as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonElement.int(key: String): Int? = str(key)?.toDoubleOrNull()?.toInt()
    private fun JsonElement.lng(key: String): Long? = str(key)?.toDoubleOrNull()?.toLong()
    private fun JsonElement.dbl(key: String): Double? = str(key)?.toDoubleOrNull()
    private fun JsonElement.int(): Int? = (this as? JsonPrimitive)?.content?.toDoubleOrNull()?.toInt()

    companion object {
        const val TMDbKey = "metadata.tmdb.apiKey"
        const val TVDbKey = "metadata.tvdb.apiKey"
        const val TVDbPin = "metadata.tvdb.pin"
        const val FanartKey = "metadata.fanart.apiKey"
        private const val IMAGE_BASE = "https://image.tmdb.org/t/p"
        private val SERIES = setOf("series", "tv", "show")
    }
}
