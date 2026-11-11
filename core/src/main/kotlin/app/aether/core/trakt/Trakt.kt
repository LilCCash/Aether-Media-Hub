package app.aether.core.trakt

import app.aether.core.json.Flex
import app.aether.core.json.flexBool
import app.aether.core.json.flexDouble
import app.aether.core.json.flexInt
import app.aether.core.json.flexString
import app.aether.core.net.AddonError
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpLimits
import app.aether.core.net.HttpRequest
import app.aether.core.net.HttpResponse
import app.aether.core.util.SecretStore
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

sealed class TraktError(override val message: String) : Exception(message) {
    object NotConnected : TraktError("Trakt non è collegato.")
    object Unauthorized : TraktError("Il collegamento con Trakt è scaduto: ricollegalo.")
    object RateLimited : TraktError("Trakt chiede di rallentare: riprova tra poco.")
    object AccountLimit : TraktError("Hai raggiunto il limite del tuo account Trakt gratuito (lista o watchlist piena).")
    object VipRequired : TraktError("Questa funzione richiede Trakt VIP.")
    object NotFound : TraktError("Trakt non ha trovato quello che cercavo.")
    class Server(val status: Int) : TraktError("Trakt ha risposto con un errore $status.")
    object Network : TraktError("Impossibile raggiungere Trakt: controlla la connessione.")
    object Malformed : TraktError("Trakt ha risposto in un modo che non so leggere.")
    object Pending : TraktError("In attesa che tu inserisca il codice.")
    object Denied : TraktError("Hai rifiutato il collegamento su Trakt.")
    object Expired : TraktError("Il codice è scaduto: riprova.")
    object NoClientId : TraktError("Trakt non è disponibile in questa versione dell'app.")
}

@Serializable
data class TraktSession(val accessToken: String, val refreshToken: String, val createdAt: Long, val expiresInSeconds: Long) {
    val expiresAt: Long get() = createdAt + expiresInSeconds * 1000
    fun needsRefresh(now: Long = System.currentTimeMillis()) = now + 86_400_000L >= expiresAt
}

data class TraktDeviceCode(val deviceCode: String, val userCode: String, val verificationUrl: String, val expiresIn: Int, val interval: Int)

data class TraktUser(val username: String, val vip: Boolean)

data class TraktTitle(
    val kind: Kind,
    val title: String,
    val year: Int? = null,
    val imdb: String? = null,
    val tmdb: Int? = null,
    val tvdb: Int? = null,
    val note: String? = null,
    val progress: Double? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeTitle: String? = null,
) {
    enum class Kind { MOVIE, SHOW }
}

data class TraktListInfo(val id: Int, val slug: String, val name: String, val itemCount: Int)

@Serializable
enum class TraktCatalogKind(val title: String, val needsLogin: Boolean) {
    CONTINUE_WATCHING("Da riprendere (Trakt)", true),
    CALENDAR("In uscita nei prossimi giorni", true),
    RECOMMENDED_MOVIES("Film consigliati per te", true),
    RECOMMENDED_SHOWS("Serie consigliate per te", true),
    WATCHLIST("La tua watchlist", true),
    TRENDING_MOVIES("Film in tendenza", false),
    TRENDING_SHOWS("Serie in tendenza", false),
    POPULAR_MOVIES("Film popolari", false),
    POPULAR_SHOWS("Serie popolari", false),
    ANTICIPATED_MOVIES("Film più attesi", false),
    ANTICIPATED_SHOWS("Serie più attese", false),
    BOX_OFFICE("Box office della settimana", false),
}

@Serializable
data class TraktSettings(
    val enabled: Boolean = false,
    val scrobble: Boolean = true,
    val syncWatchlist: Boolean = true,
    val syncWatched: Boolean = true,
    val syncOnLaunch: Boolean = true,
    val hiddenCatalogs: List<TraktCatalogKind> = emptyList(),
    val itemsPerCatalog: Int = 20,
    val showLists: Boolean = true,
) {
    fun isCatalogVisible(kind: TraktCatalogKind) = kind !in hiddenCatalogs
}

/**
 * Trakt (api.trakt.tv) with the device-code login: no secret in the app, only the public Client ID of the registered app. The
 * tokens live in the [SecretStore] (encrypted on the device) and are never logged.
 */
class TraktClient(
    private val http: HttpClient,
    private val secrets: SecretStore,
    private val clientId: String,
    private val base: String = "https://api.trakt.tv",
) {
    private val lock = Mutex()
    private val json = Json { ignoreUnknownKeys = true }

    val isAvailable: Boolean get() = clientId.isNotBlank()

    private var session: TraktSession? = secrets.get(SESSION_SECRET)?.let { runCatching { json.decodeFromString(TraktSession.serializer(), it) }.getOrNull() }

    val isConnected: Boolean get() = session != null

    private fun save(value: TraktSession?) {
        session = value
        if (value == null) secrets.remove(SESSION_SECRET) else secrets.put(SESSION_SECRET, json.encodeToString(TraktSession.serializer(), value))
    }

    // MARK: Device code

    suspend fun startDeviceLogin(): TraktDeviceCode {
        if (!isAvailable) throw TraktError.NoClientId
        val obj = call("POST", "/oauth/device/code", buildJsonObject { put("client_id", clientId) }, authorized = false) as? JsonObject ?: throw TraktError.Malformed
        return TraktDeviceCode(
            obj.flexString("device_code") ?: throw TraktError.Malformed,
            obj.flexString("user_code") ?: throw TraktError.Malformed,
            obj.flexString("verification_url") ?: throw TraktError.Malformed,
            obj.flexInt("expires_in") ?: 600,
            maxOf(1, obj.flexInt("interval") ?: 5),
        )
    }

    /** One check: [TraktError.Pending] until the viewer has typed the code. */
    suspend fun pollDeviceLogin(code: TraktDeviceCode) {
        val response = send(request("POST", "/oauth/device/token", buildJsonObject { put("code", code.deviceCode); put("client_id", clientId) }, null))
        when (response.status) {
            200 -> save(parseSession(response.text))
            400 -> throw TraktError.Pending
            429 -> throw TraktError.RateLimited
            418 -> throw TraktError.Denied
            404, 409, 410 -> throw TraktError.Expired
            else -> throw TraktError.Server(response.status)
        }
    }

    suspend fun logout() {
        session?.accessToken?.let { token ->
            runCatching { call("POST", "/oauth/revoke", buildJsonObject { put("token", token); put("client_id", clientId) }, authorized = false) }
        }
        save(null)
    }

    private fun parseSession(text: String): TraktSession {
        val obj = Flex.parse(text) as? JsonObject ?: throw TraktError.Malformed
        return TraktSession(
            obj.flexString("access_token") ?: throw TraktError.Malformed,
            obj.flexString("refresh_token") ?: throw TraktError.Malformed,
            obj.flexDouble("created_at")?.let { (it * 1000).toLong() } ?: System.currentTimeMillis(),
            obj.flexDouble("expires_in")?.toLong() ?: 7 * 86_400L,
        )
    }

    private suspend fun validSession(): TraktSession {
        val current = session ?: throw TraktError.NotConnected
        return if (current.needsRefresh()) refresh(current) else current
    }

    /** The refresh token works once: the new one is saved at once. */
    private suspend fun refresh(stale: TraktSession): TraktSession = lock.withLock {
        val current = session ?: throw TraktError.NotConnected
        if (current != stale && !current.needsRefresh()) return@withLock current
        val response = send(request("POST", "/oauth/token", buildJsonObject {
            put("refresh_token", current.refreshToken); put("client_id", clientId); put("redirect_uri", "http://localhost"); put("grant_type", "refresh_token")
        }, null))
        if (response.status == 400 || response.status == 401) { save(null); throw TraktError.Unauthorized }
        if (!response.isSuccess) throw TraktError.Server(response.status)
        parseSession(response.text).also { save(it) }
    }

    // MARK: User and catalogs

    suspend fun user(): TraktUser {
        val obj = call("GET", "/users/settings", null, authorized = true) as? JsonObject ?: throw TraktError.Malformed
        val user = obj["user"] as? JsonObject ?: throw TraktError.Malformed
        return TraktUser(user.flexString("username") ?: throw TraktError.Malformed, user.flexBool("vip") ?: false)
    }

    suspend fun titles(kind: TraktCatalogKind, limit: Int): List<TraktTitle> {
        val q = "?limit=$limit"
        return when (kind) {
            TraktCatalogKind.TRENDING_MOVIES -> wrapped(get("/movies/trending$q", false), "movie", TraktTitle.Kind.MOVIE) { it.flexInt("watchers")?.let { w -> "$w spettatori ora" } }
            TraktCatalogKind.TRENDING_SHOWS -> wrapped(get("/shows/trending$q", false), "show", TraktTitle.Kind.SHOW) { it.flexInt("watchers")?.let { w -> "$w spettatori ora" } }
            TraktCatalogKind.POPULAR_MOVIES -> plain(get("/movies/popular$q", false), TraktTitle.Kind.MOVIE)
            TraktCatalogKind.POPULAR_SHOWS -> plain(get("/shows/popular$q", false), TraktTitle.Kind.SHOW)
            TraktCatalogKind.ANTICIPATED_MOVIES -> wrapped(get("/movies/anticipated$q", false), "movie", TraktTitle.Kind.MOVIE) { it.flexInt("list_count")?.let { c -> "in $c liste" } }
            TraktCatalogKind.ANTICIPATED_SHOWS -> wrapped(get("/shows/anticipated$q", false), "show", TraktTitle.Kind.SHOW) { it.flexInt("list_count")?.let { c -> "in $c liste" } }
            TraktCatalogKind.BOX_OFFICE -> wrapped(get("/movies/boxoffice", false), "movie", TraktTitle.Kind.MOVIE) { e ->
                e.flexLong("revenue")?.let { r -> "incasso " + if (r >= 1_000_000) "%.1f M$".format(Locale.ITALY, r / 1_000_000.0) else "$r $" }
            }
            TraktCatalogKind.RECOMMENDED_MOVIES -> plain(get("/recommendations/movies$q", true), TraktTitle.Kind.MOVIE)
            TraktCatalogKind.RECOMMENDED_SHOWS -> plain(get("/recommendations/shows$q", true), TraktTitle.Kind.SHOW)
            TraktCatalogKind.WATCHLIST -> (wrapped(get("/sync/watchlist/movies?sort=added,desc", true), "movie", TraktTitle.Kind.MOVIE, null) +
                wrapped(get("/sync/watchlist/shows?sort=added,desc", true), "show", TraktTitle.Kind.SHOW, null)).take(maxOf(limit, 50))
            TraktCatalogKind.CONTINUE_WATCHING -> parsePlayback(get("/sync/playback?limit=$limit", true)).take(limit)
            TraktCatalogKind.CALENDAR -> {
                val day = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())
                parseCalendar(get("/calendars/my/shows/$day/14", true)).take(limit)
            }
        }
    }

    suspend fun lists(): List<TraktListInfo> = (get("/users/me/lists", true) as? JsonArray).orEmpty().mapNotNull { e ->
        val o = e as? JsonObject ?: return@mapNotNull null
        val ids = o["ids"] as? JsonObject ?: return@mapNotNull null
        TraktListInfo(ids.flexInt("trakt") ?: return@mapNotNull null, ids.flexString("slug") ?: "", o.flexString("name") ?: return@mapNotNull null, o.flexInt("item_count") ?: 0)
    }

    suspend fun listItems(list: TraktListInfo, limit: Int): List<TraktTitle> = (get("/users/me/lists/${list.id}/items/movie,show?limit=$limit", true) as? JsonArray).orEmpty().mapNotNull { e ->
        val o = e as? JsonObject ?: return@mapNotNull null
        (o["movie"] as? JsonObject)?.let { title(it, TraktTitle.Kind.MOVIE) } ?: (o["show"] as? JsonObject)?.let { title(it, TraktTitle.Kind.SHOW) }
    }

    // MARK: Sync

    suspend fun watchedMovies(): List<TraktTitle> = wrapped(get("/sync/watched/movies", true), "movie", TraktTitle.Kind.MOVIE, null)

    /** For every series, the watched episodes as (season, number). */
    suspend fun watchedShows(): List<Pair<TraktTitle, List<Pair<Int, Int>>>> = (get("/sync/watched/shows", true) as? JsonArray).orEmpty().mapNotNull { e ->
        val o = e as? JsonObject ?: return@mapNotNull null
        val show = (o["show"] as? JsonObject)?.let { title(it, TraktTitle.Kind.SHOW) } ?: return@mapNotNull null
        val episodes = (o["seasons"] as? JsonArray).orEmpty().flatMap { s ->
            val season = s as? JsonObject ?: return@flatMap emptyList()
            val number = season.flexInt("number") ?: return@flatMap emptyList()
            (season["episodes"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.flexInt("number")?.let { n -> number to n } }
        }
        show to episodes
    }

    suspend fun addToWatchlist(movies: List<String>, shows: List<String>) = syncIds("/sync/watchlist", movies, shows)
    suspend fun removeFromWatchlist(movies: List<String>, shows: List<String>) = syncIds("/sync/watchlist/remove", movies, shows)

    private suspend fun syncIds(path: String, movies: List<String>, shows: List<String>) {
        if (movies.isEmpty() && shows.isEmpty()) return
        call("POST", path, buildJsonObject {
            if (movies.isNotEmpty()) putJsonArray("movies") { movies.forEach { add(buildJsonObject { putJsonObject("ids") { put("imdb", it) } }) } }
            if (shows.isNotEmpty()) putJsonArray("shows") { shows.forEach { add(buildJsonObject { putJsonObject("ids") { put("imdb", it) } }) } }
        }, authorized = true)
    }

    /** Marks films and episodes (series IMDb, season, number) as watched. */
    suspend fun addToHistory(movies: List<String>, episodes: List<Triple<String, Int, Int>>, watchedAt: Long = System.currentTimeMillis()) {
        if (movies.isEmpty() && episodes.isEmpty()) return
        val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(watchedAt))
        call("POST", "/sync/history", buildJsonObject {
            if (movies.isNotEmpty()) putJsonArray("movies") { movies.forEach { add(buildJsonObject { putJsonObject("ids") { put("imdb", it) }; put("watched_at", stamp) }) } }
            if (episodes.isNotEmpty()) putJsonArray("shows") {
                episodes.groupBy { it.first }.forEach { (show, list) ->
                    add(buildJsonObject {
                        putJsonObject("ids") { put("imdb", show) }
                        putJsonArray("seasons") {
                            list.groupBy { it.second }.forEach { (season, items) ->
                                add(buildJsonObject {
                                    put("number", season)
                                    put("episodes", buildJsonArray { items.forEach { add(buildJsonObject { put("number", it.third); put("watched_at", stamp) }) } })
                                })
                            }
                        }
                    })
                }
            }
        }, authorized = true)
    }

    enum class ScrobbleAction(val path: String) { START("start"), PAUSE("pause"), STOP("stop") }

    /** [progress] 0–100. For episodes, season and number are needed. */
    suspend fun scrobble(action: ScrobbleAction, imdb: String, season: Int?, episode: Int?, progress: Double) {
        val body = buildJsonObject {
            put("progress", (progress.coerceIn(0.0, 100.0) * 100).toLong() / 100.0)
            if (season != null && episode != null) {
                putJsonObject("show") { putJsonObject("ids") { put("imdb", imdb) } }
                putJsonObject("episode") { put("season", season); put("number", episode) }
            } else {
                putJsonObject("movie") { putJsonObject("ids") { put("imdb", imdb) } }
            }
        }
        try { call("POST", "/scrobble/${action.path}", body, authorized = true) } catch (e: TraktError.Server) { if (e.status != 409) throw e }
    }

    // MARK: Transport

    private suspend fun get(path: String, authorized: Boolean) = call("GET", path, null, authorized)

    private fun request(method: String, path: String, body: JsonObject?, token: String?): HttpRequest {
        val headers = buildMap {
            put("Accept", "application/json"); put("trakt-api-version", "2"); put("trakt-api-key", clientId)
            token?.let { put("Authorization", "Bearer $it") }
        }
        return HttpRequest(base + path, method, headers, body?.toString(), if (body != null) "application/json" else null, 20, HttpLimits.RESOURCE)
    }

    private suspend fun send(request: HttpRequest): HttpResponse {
        var attempt = 0
        while (true) {
            try {
                return http.send(request)
            } catch (e: CancellationException) {
                throw e
            } catch (e: AddonError) {
                if (attempt < 2 && e.isTransient) { attempt++; delay(600L * attempt); continue }
                throw TraktError.Network
            } catch (_: Throwable) {
                throw TraktError.Network
            }
        }
    }

    private suspend fun call(method: String, path: String, body: JsonObject?, authorized: Boolean): JsonElement? {
        if (!isAvailable) throw TraktError.NoClientId
        val token = if (authorized) validSession().accessToken else null
        var request = request(method, path, body, token)
        var response = send(request)
        if (response.status == 429) {
            val wait = response.headers.entries.firstOrNull { it.key.equals("retry-after", true) }?.value?.toDoubleOrNull()
            if (wait != null && wait > 0 && wait <= 5) { delay((wait * 1000).toLong()); response = send(request) }
        }
        if (response.status == 401 && authorized) {
            val renewed = refresh(session ?: throw TraktError.Unauthorized)
            request = request(method, path, body, renewed.accessToken)
            response = send(request)
        }
        return when (response.status) {
            in 200..299 -> if (response.body.isEmpty()) null else Flex.parse(response.text) ?: throw TraktError.Malformed
            401, 403 -> throw TraktError.Unauthorized
            404 -> throw TraktError.NotFound
            420 -> throw TraktError.AccountLimit
            426 -> throw TraktError.VipRequired
            429 -> throw TraktError.RateLimited
            else -> throw TraktError.Server(response.status)
        }
    }

    companion object {
        const val SESSION_SECRET = "trakt.session"

        fun title(o: JsonObject, kind: TraktTitle.Kind): TraktTitle? {
            val name = o.flexString("title") ?: return null
            val ids = o["ids"] as? JsonObject
            return TraktTitle(kind, name, o.flexInt("year"), ids?.flexString("imdb"), ids?.flexInt("tmdb"), ids?.flexInt("tvdb"))
        }

        fun plain(element: JsonElement?, kind: TraktTitle.Kind) = (element as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.let { o -> title(o, kind) } }

        fun wrapped(element: JsonElement?, key: String, kind: TraktTitle.Kind, note: ((JsonObject) -> String?)?) =
            (element as? JsonArray).orEmpty().mapNotNull { e ->
                val o = e as? JsonObject ?: return@mapNotNull null
                val inner = o[key] as? JsonObject ?: return@mapNotNull null
                title(inner, kind)?.copy(note = note?.invoke(o))
            }

        fun parsePlayback(element: JsonElement?): List<TraktTitle> {
            val result = (element as? JsonArray).orEmpty().mapNotNull { e ->
                val o = e as? JsonObject ?: return@mapNotNull null
                val progress = o.flexDouble("progress")
                (o["movie"] as? JsonObject)?.let { m -> title(m, TraktTitle.Kind.MOVIE)?.copy(progress = progress, note = progress?.let { "visto al ${it.toInt()}%" }) }
                    ?: (o["show"] as? JsonObject)?.let { s ->
                        val ep = o["episode"] as? JsonObject
                        val season = ep?.flexInt("season"); val number = ep?.flexInt("number")
                        val label = listOfNotNull(season?.let { "S$it" }, number?.let { "E$it" }).joinToString("")
                        title(s, TraktTitle.Kind.SHOW)?.copy(season = season, episode = number, episodeTitle = ep?.flexString("title"), progress = progress,
                            note = listOfNotNull(label.ifEmpty { null }, progress?.let { "${it.toInt()}%" }).joinToString(" · "))
                    }
            }
            val seen = HashSet<String>()
            return result.filter { seen.add(it.imdb ?: it.title) }
        }

        fun parseCalendar(element: JsonElement?) = (element as? JsonArray).orEmpty().mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            val show = (o["show"] as? JsonObject)?.let { title(it, TraktTitle.Kind.SHOW) } ?: return@mapNotNull null
            val ep = o["episode"] as? JsonObject
            val season = ep?.flexInt("season"); val number = ep?.flexInt("number")
            show.copy(season = season, episode = number, episodeTitle = ep?.flexString("title"),
                note = listOfNotNull("S${season ?: 0}E${number ?: 0}", o.flexString("first_aired")?.take(10)).joinToString(" · "))
        }
    }
}

private fun JsonObject.flexLong(key: String): Long? = (this[key] as? JsonPrimitive)?.content?.toDoubleOrNull()?.toLong()
