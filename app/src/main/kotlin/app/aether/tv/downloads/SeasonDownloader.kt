package app.aether.tv.downloads

import android.content.Context
import app.aether.core.AetherEngine
import app.aether.core.debrid.DebridRequest
import app.aether.core.debrid.DebridResolver
import app.aether.core.downloads.DownloadStore
import app.aether.core.downloads.DownloadSubtitles
import app.aether.core.model.AddonStream
import app.aether.core.model.MetaItem
import app.aether.core.model.StreamSource
import app.aether.core.model.Video
import app.aether.core.playback.StreamResolver
import app.aether.core.playback.StreamSelector
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * «Scarica la stagione»: for each episode not downloaded yet, the best source is chosen as the automatic choice would (keeping the
 * same release group from one episode to the next), turned into a link (torrents through the debrid service, only when cached) and
 * queued, with its subtitles. One season at a time; what cannot be downloaded is counted and said at the end.
 */
object SeasonDownloader {
    data class Status(val title: String, val done: Int, val total: Int, val skipped: Int, val running: Boolean, val message: String)

    private val _status = MutableStateFlow<Status?>(null)
    val status: StateFlow<Status?> get() = _status
    private var job: Job? = null

    fun cancel() { job?.cancel(); _status.value = _status.value?.copy(running = false, message = "Download della stagione interrotto.") }

    fun start(context: Context, engine: AetherEngine, meta: MetaItem, season: Int, episodes: List<Video>) {
        if (job?.isActive == true) return
        val appContext = context.applicationContext
        val already = engine.downloads.forMeta(meta.id).filter { it.state != app.aether.core.downloads.DownloadState.FAILED }.mapNotNull { it.videoId }.toSet()
        val todo = episodes.filter { !it.isFuture && it.id !in already }
        val title = "${meta.name} · stagione $season"
        if (todo.isEmpty()) { _status.value = Status(title, 0, 0, 0, false, "Tutti gli episodi di questa stagione sono già scaricati o in coda."); return }
        val language = java.util.Locale.getDefault().language
        job = engine.scope.launch {
            var done = 0
            var skipped = 0
            var binge: String? = null
            _status.value = Status(title, 0, todo.size, 0, true, "Cerco le sorgenti…")
            for (video in todo) {
                try {
                    _status.value = Status(title, done, todo.size, skipped, true, "Episodio ${video.episodeLabel ?: video.title}: cerco la sorgente…")
                    val collected = ArrayList<AddonStream>()
                    engine.addons.streams(meta.type, video.id, debrid = engine.debrid.streamContext()).collect { batch -> collected.addAll(batch.streams) }
                    val prefs = engine.streamPreferences(language)
                    val ranked = StreamSelector.rank(collected, prefs)
                    // A link that can be downloaded right now: direct ones, or torrents the debrid service already has.
                    val candidates = ranked.filter { it.info.support.isPlayable }.let { list -> binge?.let { b -> list.sortedByDescending { it.stream.behaviorHints.bingeGroup == b } } ?: list }
                    var queued = false
                    for (item in candidates.take(5)) {
                        val url = when (val source = item.stream.source) {
                            is StreamSource.Url -> StreamResolver.playbackUrl(item.stream, null)
                            is StreamSource.Torrent -> if (!engine.debrid.isConfigured) null else runCatching {
                                engine.debrid.resolve(
                                    DebridRequest(source.infoHash, source.trackers, source.fileIndex, item.stream.behaviorHints.filename, video.id),
                                    DebridResolver.Mode.CachedOnly, onProgress = {}, chooseFile = { files -> files.filter { !it.zipped }.maxByOrNull { it.size ?: 0 } },
                                )
                            }.getOrNull()
                            else -> null
                        } ?: continue
                        if (!(url.startsWith("https://") || url.startsWith("http://")) || url.startsWith("http://127.0.0.1")) continue
                        val download = engine.downloads.add(meta, video, url, item.stream.behaviorHints.proxyRequestHeaders, DownloadStore.extension(url, item.stream.behaviorHints.filename))
                        DownloadWorker.start(appContext, download.id)
                        binge = binge ?: item.stream.behaviorHints.bingeGroup
                        launch { DownloadSubtitles.save(engine, download.id, meta, video, item.stream, language) }
                        queued = true
                        break
                    }
                    if (queued) done++ else skipped++
                } catch (e: Throwable) {
                    if (e is CancellationException) throw e
                    skipped++
                    engine.log.error("download", "stagione: episodio ${video.id} non accodato", e)
                }
            }
            _status.value = Status(title, done, todo.size, skipped, false,
                if (skipped == 0) "In coda tutti i $done episodi: li trovi in Libreria ▸ Download."
                else "In coda $done episodi su ${todo.size}: per $skipped non c'era una sorgente scaricabile subito (torrent non in cache o nessuna sorgente).")
        }
    }
}
