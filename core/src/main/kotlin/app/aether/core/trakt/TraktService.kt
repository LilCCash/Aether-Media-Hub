package app.aether.core.trakt

import app.aether.core.library.LibraryStore
import app.aether.core.metadata.MetadataEnrichment
import app.aether.core.model.ExternalIds
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.core.settings.SettingsStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

data class TraktShelfItem(val meta: MetaItem, val note: String?)

/**
 * Trakt in the app: the device-code link, the two-way sync of watchlist and watched titles (never deletes: it adds what one side
 * lacks), the scrobble from the player and the catalogs. Everything stays off until the viewer turns it on.
 */
class TraktService(
    val client: TraktClient,
    private val library: LibraryStore,
    private val metadata: MetadataEnrichment,
    private val settings: SettingsStore,
    private val scope: CoroutineScope,
) {
    sealed class Link {
        object Disconnected : Link()
        data class Waiting(val code: String, val url: String, val expiresAt: Long) : Link()
        object Connected : Link()
    }

    data class State(
        val link: Link = Link.Disconnected,
        val user: TraktUser? = null,
        val syncing: Boolean = false,
        val lastReport: String? = null,
        val lastSync: Long? = null,
        val message: String? = null,
    )

    private val _state = MutableStateFlow(State(link = if (client.isConnected) Link.Connected else Link.Disconnected))
    val state: StateFlow<State> get() = _state
    private var pollJob: Job? = null
    private var lastScrobble: Pair<TraktClient.ScrobbleAction, String>? = null

    private val options: TraktSettings get() = settings.value.value.trakt
    val isActive: Boolean get() = client.isConnected && options.enabled

    fun bootstrap() = scope.launch {
        if (!client.isConnected) return@launch
        refreshUser()
        if (options.enabled && options.syncOnLaunch) syncNow()
    }

    fun connect() {
        pollJob?.cancel()
        _state.update { it.copy(message = null) }
        pollJob = scope.launch {
            val code = try { client.startDeviceLogin() } catch (e: CancellationException) { throw e } catch (e: TraktError) { _state.update { s -> s.copy(message = e.message) }; return@launch } catch (_: Throwable) { _state.update { s -> s.copy(message = TraktError.Network.message) }; return@launch }
            val deadline = System.currentTimeMillis() + code.expiresIn * 1000L
            _state.update { it.copy(link = Link.Waiting(code.userCode, code.verificationUrl, deadline)) }
            var interval = code.interval
            while (System.currentTimeMillis() < deadline) {
                delay(interval * 1000L)
                try {
                    client.pollDeviceLogin(code)
                    _state.update { it.copy(link = Link.Connected, message = null) }
                    if (!options.enabled) settings.update { it.copy(trakt = it.trakt.copy(enabled = true)) }
                    refreshUser()
                    syncNow()
                    return@launch
                } catch (e: CancellationException) {
                    throw e
                } catch (_: TraktError.Pending) {
                    continue
                } catch (_: TraktError.RateLimited) {
                    interval++
                } catch (e: TraktError) {
                    _state.update { it.copy(link = Link.Disconnected, message = e.message) }; return@launch
                } catch (_: Throwable) {
                    _state.update { it.copy(link = Link.Disconnected, message = TraktError.Network.message) }; return@launch
                }
            }
            _state.update { it.copy(link = Link.Disconnected, message = TraktError.Expired.message) }
        }
    }

    fun cancelConnect() {
        pollJob?.cancel()
        if (_state.value.link is Link.Waiting) _state.update { it.copy(link = Link.Disconnected) }
    }

    fun disconnect() = scope.launch {
        pollJob?.cancel()
        client.logout()
        _state.value = State()
    }

    suspend fun refreshUser() {
        try {
            val user = client.user()
            _state.update { it.copy(user = user) }
        } catch (e: CancellationException) {
            throw e
        } catch (_: TraktError.Unauthorized) {
            _state.update { it.copy(link = Link.Disconnected, message = TraktError.Unauthorized.message) }
        } catch (_: Throwable) {
            // Offline: the link stays, it is tried again later.
        }
    }

    suspend fun syncNow() {
        if (!client.isConnected || _state.value.syncing) return
        _state.update { it.copy(syncing = true, message = null) }
        try {
            val report = sync(options)
            _state.update { it.copy(lastReport = report, lastSync = System.currentTimeMillis()) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: TraktError) {
            _state.update { it.copy(message = e.message, link = if (e is TraktError.Unauthorized) Link.Disconnected else it.link) }
        } catch (_: Throwable) {
            _state.update { it.copy(message = TraktError.Network.message) }
        } finally {
            _state.update { it.copy(syncing = false) }
        }
    }

    /** A change of the Aether list, repeated on Trakt. */
    fun watchlistChanged(meta: MetaItem, enabled: Boolean) {
        if (!isActive || !options.syncWatchlist || !meta.id.startsWith("tt")) return
        val movie = meta.type == "movie"
        scope.launch {
            runCatching {
                if (enabled) client.addToWatchlist(if (movie) listOf(meta.id) else emptyList(), if (movie) emptyList() else listOf(meta.id))
                else client.removeFromWatchlist(if (movie) listOf(meta.id) else emptyList(), if (movie) emptyList() else listOf(meta.id))
            }
        }
    }

    /** Tells Trakt what the player is doing; failures never disturb playback. */
    fun scrobble(action: TraktClient.ScrobbleAction, meta: MetaItem, video: Video?, position: Double, duration: Double) {
        if (!isActive || !options.scrobble) return
        val imdb = (if (meta.id.startsWith("tt")) meta.id.substringBefore(':') else meta.externalIds.imdb)?.takeIf { it.startsWith("tt") } ?: return
        var season: Int? = null
        var episode: Int? = null
        if (meta.type == "series") {
            val s = video?.season ?: return
            val e = video.episode ?: return
            if (s <= 0) return
            season = s; episode = e
        }
        val identifier = "$imdb|${season ?: 0}|${episode ?: 0}"
        val last = lastScrobble
        if (last != null && last.first == action && last.second == identifier && action != TraktClient.ScrobbleAction.PAUSE) return
        lastScrobble = action to identifier
        val progress = if (duration > 0) (position / duration * 100).coerceIn(0.0, 100.0) else 0.0
        scope.launch { runCatching { client.scrobble(action, imdb, season, episode, progress) } }
    }

    // MARK: Catalogs

    suspend fun items(kind: TraktCatalogKind, limit: Int = options.itemsPerCatalog): List<TraktShelfItem> = shelf(client.titles(kind, limit))

    suspend fun lists(): List<TraktListInfo> = client.lists()

    suspend fun listItems(list: TraktListInfo, limit: Int = options.itemsPerCatalog): List<TraktShelfItem> = shelf(client.listItems(list, limit))

    /** Gives every title name, poster and plot (from TMDB, when there is a key); titles without an IMDb id are left out. */
    suspend fun shelf(titles: List<TraktTitle>): List<TraktShelfItem> = coroutineScope {
        val gate = Semaphore(6)
        val seen = HashSet<String>()
        titles.filter { it.imdb != null }.map { title ->
            async {
                gate.withPermit {
                    val meta = MetaItem(title.imdb!!, if (title.kind == TraktTitle.Kind.MOVIE) "movie" else "series", title.title,
                        releaseInfo = title.year?.toString(), externalIds = ExternalIds(title.imdb, title.tmdb, title.tvdb))
                    TraktShelfItem(metadata.summary(meta), title.note)
                }
            }
        }.awaitAll().filter { seen.add(it.meta.id) }
    }

    // MARK: Sync

    private suspend fun sync(options: TraktSettings): String {
        var wlIn = 0; var wlOut = 0; var wIn = 0; var wOut = 0
        if (options.syncWatchlist) {
            val remote = client.titles(TraktCatalogKind.WATCHLIST, 1000)
            val local = library.watchlist()
            val localIds = local.map { it.id }.toSet()
            val remoteIds = remote.mapNotNull { it.imdb }.toSet()
            for (item in shelf(remote.filter { it.imdb != null && it.imdb !in localIds }.take(IMPORT_CAP))) { library.setWatchlist(true, item.meta); wlIn++ }
            val push = local.filter { it.id.startsWith("tt") && it.id !in remoteIds }.take(PUSH_CAP)
            val movies = push.filter { it.type == "movie" }.map { it.id }
            val shows = push.filter { it.type == "series" }.map { it.id }
            if (movies.isNotEmpty() || shows.isNotEmpty()) { client.addToWatchlist(movies, shows); wlOut = movies.size + shows.size }
        }
        if (options.syncWatched) {
            val history = library.history(20_000).filter { it.isCompleted }
            val localMovies = history.filter { it.type == "movie" }.map { it.metaId }.toSet()
            val localEpisodes = history.filter { it.type == "series" && it.season != null && it.episode != null }.map { "${it.metaId}|${it.season}|${it.episode}" }.toSet()
            val remoteMovies = client.watchedMovies()
            for (item in shelf(remoteMovies.filter { it.imdb != null && it.imdb !in localMovies }.take(IMPORT_CAP))) { library.markWatched(true, item.meta, listOf(null)); wIn++ }
            val remoteEpisodes = HashSet<String>()
            var budget = IMPORT_CAP * 2
            for ((show, episodes) in client.watchedShows()) {
                val imdb = show.imdb ?: continue
                val videos = ArrayList<Video>()
                for ((season, number) in episodes) {
                    val key = "$imdb|$season|$number"
                    remoteEpisodes.add(key)
                    if (key !in localEpisodes && budget > 0) { videos.add(Video("$imdb:$season:$number", "Episodio $number", season = season, episode = number)); budget-- }
                }
                if (videos.isNotEmpty()) {
                    val meta = MetaItem(imdb, "series", show.title, releaseInfo = show.year?.toString(), externalIds = ExternalIds(imdb, show.tmdb, show.tvdb))
                    library.markWatched(true, meta, videos)
                    wIn += videos.size
                }
            }
            val remoteMovieIds = remoteMovies.mapNotNull { it.imdb }.toSet()
            val pushMovies = localMovies.filter { it.startsWith("tt") && it !in remoteMovieIds }.take(PUSH_CAP)
            val pushEpisodes = history.asSequence().filter { it.type == "series" && it.metaId.startsWith("tt") && (it.season ?: 0) > 0 && it.episode != null }
                .filter { "${it.metaId}|${it.season}|${it.episode}" !in remoteEpisodes }.map { Triple(it.metaId, it.season!!, it.episode!!) }.distinct().take(PUSH_CAP).toList()
            if (pushMovies.isNotEmpty() || pushEpisodes.isNotEmpty()) { client.addToHistory(pushMovies, pushEpisodes); wOut = pushMovies.size + pushEpisodes.size }
        }
        return "Watchlist: $wlIn da Trakt, $wlOut verso Trakt. Visti: $wIn da Trakt, $wOut verso Trakt."
    }

    companion object {
        const val IMPORT_CAP = 150
        const val PUSH_CAP = 300
    }
}
