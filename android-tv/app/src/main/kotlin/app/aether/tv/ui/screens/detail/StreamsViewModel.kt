package app.aether.tv.ui.screens.detail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.aether.core.AetherEngine
import app.aether.core.debrid.DebridError
import app.aether.core.debrid.DebridFile
import app.aether.core.debrid.DebridProgress
import app.aether.core.debrid.DebridRequest
import app.aether.core.debrid.DebridResolver
import app.aether.core.model.AddonStream
import app.aether.core.model.StreamSource
import app.aether.core.net.AddonError
import app.aether.core.playback.PlaybackSupport
import app.aether.core.playback.RankedStream
import app.aether.core.playback.StreamResolver
import app.aether.core.playback.StreamSelector
import app.aether.tv.PlaybackRequest
import app.aether.tv.Session
import app.aether.tv.StreamRequest
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The choice of the source: asks the addons, ranks what they answer, turns the chosen one into a link and hands it to the player. */
class StreamsViewModel(private val engine: AetherEngine, val request: StreamRequest, private val systemLanguage: String?) : ViewModel() {
    data class FileChoice(val candidates: List<DebridFile>)

    data class UiState(
        val loading: Boolean = true,
        val ranked: List<RankedStream> = emptyList(),
        val errors: Map<String, String> = emptyMap(),
        val pendingAddons: List<String> = emptyList(),
        val addonFilter: String? = null,
        val cached: Set<String> = emptySet(),
        val torBoxConfigured: Boolean = false,
        val resolvingId: String? = null,
        val progress: DebridProgress? = null,
        val rowFailure: Pair<String, String>? = null,
        val askDownload: RankedStream? = null,
        val fileChoice: FileChoice? = null,
        val blocked: String? = null,
        val autoSelecting: Boolean = false,
    ) {
        val addonNames: List<String> get() = ranked.mapNotNull { it.stream.addonName }.distinct()
        val visible: List<RankedStream> get() = ranked.filter { addonFilter == null || it.stream.addonName == addonFilter }
    }

    private val _state = MutableStateFlow(UiState(torBoxConfigured = engine.torBox.isConfigured))
    val state: StateFlow<UiState> get() = _state
    private val _play = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    /** Emits when the player may be opened (`Session.playback` is set). */
    val play: SharedFlow<Unit> get() = _play

    private var collected = ArrayList<AddonStream>()
    private var streamsJob: Job? = null
    private var resolveJob: Job? = null
    private var cacheJob: Job? = null
    private var fileChoiceReply: CompletableDeferred<DebridFile?>? = null
    private var played = false

    init { start() }

    private suspend fun preferences() = engine.streamPreferences(systemLanguage)

    fun start() {
        streamsJob?.cancel()
        collected = ArrayList()
        _state.update { it.copy(loading = true, ranked = emptyList(), errors = emptyMap(), blocked = null) }
        streamsJob = viewModelScope.launch {
            val meta = request.meta
            val videoId = request.video?.id ?: meta.id
            val embedded = request.video?.streams.orEmpty()
            val addonCount = engine.registry.handles().count { app.aether.core.addons.RequestPlanner.addons(app.aether.core.model.ResourcePath("stream", meta.type, videoId), listOf(it)).isNotEmpty() }
            if (embedded.isNotEmpty()) {
                // Streams carried by the episode itself: Stremio does not ask the other addons.
                collected.addAll(embedded)
                rerank(emptyList(), emptyMap(), done = true)
                return@launch
            }
            var received = 0
            val errors = LinkedHashMap<String, String>()
            val answered = HashSet<String>()
            val names = engine.registry.handles().filter { app.aether.core.addons.RequestPlanner.addons(app.aether.core.model.ResourcePath("stream", meta.type, videoId), listOf(it)).isNotEmpty() }.associate { it.id to it.addon.displayName }
            _state.update { it.copy(pendingAddons = names.values.toList()) }
            if (addonCount == 0) {
                rerank(emptyList(), errors, done = true)
                return@launch
            }
            engine.addons.streams(meta.type, videoId).collect { batch ->
                received++
                answered.add(batch.addonId)
                batch.error?.let { errors[batch.addonName] = it.message }
                val known = collected.map { it.id }.toHashSet()
                collected.addAll(batch.streams.filter { known.add(it.id) })
                rerank(names.filterKeys { it !in answered }.values.toList(), errors, done = received >= addonCount)
            }
            rerank(emptyList(), errors, done = true)
        }
    }

    private suspend fun rerank(pending: List<String>, errors: Map<String, String>, done: Boolean) {
        val preferences = preferences()
        val ranked = StreamSelector.rank(collected.toList(), preferences)
        _state.update { it.copy(ranked = ranked, pendingAddons = pending, errors = errors, loading = !done, torBoxConfigured = engine.torBox.isConfigured) }
        checkCache(ranked)
        if (done) maybeAutoSelect(ranked, preferences.ordering)
    }

    private fun checkCache(ranked: List<RankedStream>) {
        if (!engine.torBox.isConfigured) return
        val hashes = ranked.mapNotNull { (it.stream.source as? StreamSource.Torrent)?.infoHash?.lowercase() }.distinct().filter { it !in _state.value.cached }
        if (hashes.isEmpty()) return
        cacheJob?.cancel()
        cacheJob = viewModelScope.launch {
            delay(300)
            try {
                val found = HashSet<String>()
                for (chunk in hashes.chunked(100)) found.addAll(engine.torBox.checkCached(chunk))
                _state.update { it.copy(cached = it.cached + found) }
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                // The badges are a convenience: without them every torrent is still tried the normal way.
            }
        }
    }

    private suspend fun maybeAutoSelect(ranked: List<RankedStream>, ordering: app.aether.core.playback.StreamOrdering) {
        if (played || !(engine.settings.value.value.playback.autoSelectStream || request.autoSelect)) return
        val binge = bingeGroups[request.meta.id]
        val best = StreamSelector.autoSelect(ranked, binge, ordering) ?: return
        _state.update { it.copy(autoSelecting = true) }
        select(best)
    }

    fun setFilter(addon: String?) = _state.update { it.copy(addonFilter = addon) }
    fun dismissBlocked() = _state.update { it.copy(blocked = null) }

    fun isCached(item: RankedStream): Boolean? {
        val torrent = item.stream.source as? StreamSource.Torrent ?: return null
        if (!engine.torBox.isConfigured) return null
        return if (torrent.infoHash.lowercase() in _state.value.cached) true else null
    }

    fun select(item: RankedStream) {
        if (_state.value.resolvingId != null) return
        when (val support = item.info.support) {
            is PlaybackSupport.Unsupported -> { _state.update { it.copy(blocked = support.reason.message) }; return }
            else -> {}
        }
        when (val source = item.stream.source) {
            is StreamSource.Torrent -> resolveTorrent(item, source, allowDownload = false)
            is StreamSource.Url -> {
                val url = StreamResolver.playbackUrl(item.stream, null) ?: run { _state.update { it.copy(blocked = "Indirizzo della sorgente non valido.") }; return }
                handOver(item, url)
            }
            else -> _state.update { it.copy(blocked = "Questa sorgente non si può riprodurre.") }
        }
    }

    private fun resolveTorrent(item: RankedStream, source: StreamSource.Torrent, allowDownload: Boolean) {
        if (!engine.torBox.isConfigured) {
            val server = engine.settings.value.value.network.streamingServerUrl.trim().ifEmpty { null }
            val url = StreamResolver.playbackUrl(item.stream, server)
            if (url != null) handOver(item, url) else _state.update { it.copy(blocked = DebridError.NotConfigured.message) }
            return
        }
        resolveJob?.cancel()
        _state.update { it.copy(resolvingId = item.id, progress = DebridProgress("Controllo TorBox…", null, null), rowFailure = null) }
        resolveJob = viewModelScope.launch {
            try {
                val link = engine.debrid.resolve(
                    DebridRequest(source.infoHash, source.trackers, source.fileIndex, item.stream.behaviorHints.filename, request.video?.id ?: request.meta.id),
                    if (allowDownload) DebridResolver.Mode.AllowDownload else DebridResolver.Mode.CachedOnly,
                    onProgress = { progress -> _state.update { it.copy(progress = progress) } },
                    chooseFile = { candidates ->
                        val reply = CompletableDeferred<DebridFile?>()
                        fileChoiceReply = reply
                        _state.update { it.copy(fileChoice = FileChoice(candidates)) }
                        reply.await()
                    },
                )
                _state.update { it.copy(resolvingId = null, progress = null) }
                handOver(item, link)
            } catch (error: Throwable) {
                if (error is CancellationException) { _state.update { it.copy(resolvingId = null, progress = null) }; throw error }
                val debrid = error as? DebridError
                _state.update { it.copy(resolvingId = null, progress = null) }
                if (debrid is DebridError.NotCached) _state.update { it.copy(askDownload = item) }
                else _state.update { it.copy(rowFailure = item.id to (debrid?.message ?: AddonError.from(error).message)) }
            }
        }
    }

    fun confirmDownload(item: RankedStream) {
        _state.update { it.copy(askDownload = null) }
        (item.stream.source as? StreamSource.Torrent)?.let { resolveTorrent(item, it, allowDownload = true) }
    }

    fun cancelDownloadPrompt() = _state.update { it.copy(askDownload = null) }

    fun chooseFile(file: DebridFile?) {
        _state.update { it.copy(fileChoice = null) }
        fileChoiceReply?.complete(file)
        fileChoiceReply = null
    }

    fun cancelResolution() {
        resolveJob?.cancel()
        fileChoiceReply?.complete(null)
        _state.update { it.copy(resolvingId = null, progress = null, fileChoice = null) }
    }

    private fun handOver(item: RankedStream, url: String) {
        if (played) return
        played = true
        item.stream.behaviorHints.bingeGroup?.let { bingeGroups[request.meta.id] = it }
        val alternatives = _state.value.ranked.filter { it.id != item.id && it.info.support.isPlayable }
        Session.playback = PlaybackRequest(
            meta = request.meta, video = request.video, stream = item.stream, url = url,
            headers = item.stream.behaviorHints.proxyRequestHeaders, alternatives = alternatives, startPositionSeconds = request.resumeAt,
        )
        _play.tryEmit(Unit)
    }

    /** Lets the screen use the source again after coming back from the player. */
    fun rearm() { played = false; _state.update { it.copy(autoSelecting = false) } }

    companion object {
        /** The release group of the last source played for each title, so the next episode keeps the same quality and addon. */
        private val bingeGroups = HashMap<String, String>()
    }
}
