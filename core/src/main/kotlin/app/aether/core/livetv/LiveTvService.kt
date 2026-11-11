package app.aether.core.livetv

import app.aether.core.net.AddonError
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import app.aether.core.settings.SettingsStore
import app.aether.core.util.JsonFileStore
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/**
 * Live TV: the viewer's M3U playlists (downloaded, cached on disk) and the XMLTV guide under their channels (the viewer's address,
 * else the one a playlist announces, else the public Italian guide), refreshed every 12 hours. Same behaviour as the iOS app.
 */
class LiveTvService(private val http: HttpClient, private val settings: SettingsStore, private val dir: File) {
    data class State(
        val channels: Map<String, List<M3uChannel>> = emptyMap(),
        val announcedGuides: List<String> = emptyList(),
        val guide: TvGuide = TvGuide(),
        val guideSource: String? = null,
        val loadingGuide: Boolean = false,
        val guideMessage: String? = null,
        val playlistErrors: Map<String, String> = emptyMap(),
    ) {
        val allChannels: List<M3uChannel> get() = channels.values.flatten()
    }

    @Serializable
    private data class StoredGuide(val guide: TvGuide, val source: String)

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> get() = _state
    private val lock = Mutex()
    private var matcher: TvGuideMatcher? = null
    private val matches = HashMap<String, String?>()
    private val guideFile = JsonFileStore(File(dir, "guide.json"), StoredGuide.serializer())
    private var loaded = false

    private fun channelFile(playlistId: String) = JsonFileStore(File(dir, "playlist-$playlistId.json"), ListSerializer(M3uChannel.serializer()))
    private fun guidesFile() = JsonFileStore(File(dir, "announced.json"), ListSerializer(kotlinx.serialization.serializer<String>()))

    /** Reads what is on disk (once). */
    suspend fun load() = lock.withLock {
        if (loaded) return@withLock
        loaded = true
        withContext(Dispatchers.IO) {
            val playlists = settings.value.value.liveTv.playlists
            val channels = playlists.associate { it.id to (channelFile(it.id).load() ?: emptyList()) }
            val stored = guideFile.load()
            _state.value = _state.value.copy(channels = channels, announcedGuides = guidesFile().load().orEmpty(),
                guide = stored?.guide ?: TvGuide(fetchedAt = 0), guideSource = stored?.source)
            stored?.let { applyGuide(it.guide) }
        }
    }

    /** Adds a playlist from an address; the first download says whether it is a playlist at all. */
    suspend fun addPlaylist(name: String, url: String): String? {
        val address = url.trim()
        val scheme = address.substringBefore("://", "").lowercase()
        if (scheme != "http" && scheme != "https") return "L'indirizzo deve iniziare con http:// o https://."
        val result = try { download(address) } catch (e: CancellationException) { throw e } catch (e: Throwable) { return message(e) }
        if (result.channels.isEmpty()) return "Non ho trovato canali in questa playlist (serve un file M3U)."
        val playlist = LivePlaylist(name = name.trim().ifEmpty { address.substringAfter("://").substringBefore('/') }, url = address)
        store(playlist.id, result)
        settings.update { it.copy(liveTv = it.liveTv.copy(playlists = it.liveTv.playlists + playlist, showTab = true)) }
        return null
    }

    /** Adds a playlist from the text of a file (from the phone page). */
    suspend fun importPlaylist(name: String, text: String): String? {
        val result = M3uParser.parse(text)
        if (result.channels.isEmpty()) return "Non ho trovato canali in questo file (serve un file M3U)."
        val playlist = LivePlaylist(name = name.trim().ifEmpty { "Playlist" }, url = null)
        store(playlist.id, result)
        settings.update { it.copy(liveTv = it.liveTv.copy(playlists = it.liveTv.playlists + playlist, showTab = true)) }
        return null
    }

    suspend fun removePlaylist(id: String) {
        settings.update { it.copy(liveTv = it.liveTv.copy(playlists = it.liveTv.playlists.filter { p -> p.id != id })) }
        withContext(Dispatchers.IO) { File(dir, "playlist-$id.json").delete() }
        _state.value = _state.value.copy(channels = _state.value.channels - id, playlistErrors = _state.value.playlistErrors - id)
    }

    /** Downloads every playlist with an address again. */
    suspend fun refreshPlaylists() {
        val errors = HashMap<String, String>()
        for (playlist in settings.value.value.liveTv.playlists) {
            val url = playlist.url ?: continue
            try { store(playlist.id, download(url)) } catch (e: CancellationException) { throw e } catch (e: Throwable) { errors[playlist.id] = message(e) }
        }
        _state.value = _state.value.copy(playlistErrors = errors)
    }

    private suspend fun download(url: String): M3uParseResult {
        val response = http.send(HttpRequest(url, headers = mapOf("User-Agent" to "Aether"), timeoutSeconds = 40, maxBytes = 40 * 1024 * 1024))
        if (!response.isSuccess) throw AddonError.InvalidUrl("il server ha risposto ${response.status}")
        return withContext(Dispatchers.Default) { M3uParser.parse(response.text) }
    }

    private suspend fun store(id: String, result: M3uParseResult) = withContext(Dispatchers.IO) {
        channelFile(id).save(result.channels)
        val announced = (_state.value.announcedGuides + result.guides).distinct()
        guidesFile().save(announced)
        _state.value = _state.value.copy(channels = _state.value.channels + (id to result.channels), announcedGuides = announced)
    }

    // MARK: Guide

    fun channelId(channel: M3uChannel): String? = synchronized(matches) {
        if (channel.id in matches) return matches[channel.id]
        val found = matcher?.channelId(channel.tvgId, channel.name)
        matches[channel.id] = found
        found
    }

    fun now(channel: M3uChannel, at: Long = System.currentTimeMillis()) = channelId(channel)?.let { _state.value.guide.now(it, at) }

    fun upcoming(channel: M3uChannel, count: Int) = channelId(channel)?.let { _state.value.guide.upcoming(it, count = count) }.orEmpty()

    fun between(channel: M3uChannel, start: Long, end: Long) = channelId(channel)?.let { _state.value.guide.between(it, start, end) }.orEmpty()

    /** Downloads the guide when there is none, when the address changed, or when it is older than 12 hours (or [force]). */
    suspend fun refreshGuide(force: Boolean = false) {
        val current = _state.value
        val address = settings.value.value.liveTv.guideAddress(current.announcedGuides) ?: run { _state.value = current.copy(guideMessage = null); return }
        val fresh = System.currentTimeMillis() - current.guide.fetchedAt < REFRESH_AFTER_MS
        if (!force && current.guideSource == address && !current.guide.isEmpty && fresh) return
        if (current.loadingGuide) return
        val scheme = address.substringBefore("://", "").lowercase()
        if (scheme != "http" && scheme != "https") { _state.value = current.copy(guideMessage = "L'indirizzo della guida non è valido."); return }
        _state.value = current.copy(loadingGuide = true, guideMessage = null)
        try {
            val response = http.send(HttpRequest(address, headers = mapOf("User-Agent" to "Aether"), timeoutSeconds = 60, maxBytes = MAX_GUIDE_BYTES))
            if (!response.isSuccess) { _state.value = _state.value.copy(guideMessage = "Il server della guida ha risposto con un errore (${response.status})."); return }
            val parsed = withContext(Dispatchers.Default) { XmltvParser.parse(response.body) }
            if (parsed.isEmpty) { _state.value = _state.value.copy(guideMessage = "Non ho trovato programmi in questa guida (serve un file XMLTV, anche .gz)."); return }
            withContext(Dispatchers.IO) { guideFile.save(StoredGuide(parsed, address)) }
            applyGuide(parsed)
            _state.value = _state.value.copy(guide = parsed, guideSource = address)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            _state.value = _state.value.copy(guideMessage = "Download della guida non riuscito: ${message(e)}")
        } finally {
            _state.value = _state.value.copy(loadingGuide = false)
        }
    }

    suspend fun clearGuide() {
        withContext(Dispatchers.IO) { File(dir, "guide.json").delete() }
        synchronized(matches) { matcher = null; matches.clear() }
        _state.value = _state.value.copy(guide = TvGuide(fetchedAt = 0), guideSource = null)
    }

    private fun applyGuide(guide: TvGuide) = synchronized(matches) {
        matcher = TvGuideMatcher(guide)
        matches.clear()
    }

    private fun message(error: Throwable) = (error as? AddonError ?: AddonError.from(error)).message

    companion object {
        const val REFRESH_AFTER_MS = 12 * 3_600_000L
        const val MAX_GUIDE_BYTES = 80 * 1024 * 1024
    }
}
