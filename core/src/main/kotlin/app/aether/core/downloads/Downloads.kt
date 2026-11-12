package app.aether.core.downloads

import app.aether.core.model.MetaItem
import app.aether.core.model.PosterShape
import app.aether.core.model.Video
import app.aether.core.util.JsonFileStore
import app.aether.core.util.SecretStore
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

@Serializable
enum class DownloadState(val title: String) {
    QUEUED("In coda"), RUNNING("In download"), PAUSED("In pausa"), DONE("Scaricato"), FAILED("Non riuscito")
}

/** A subtitle file saved next to a downloaded video (always SubRip, UTF-8). */
@Serializable
data class SavedSubtitle(val lang: String, val label: String, val fileName: String)

/** One downloaded (or downloading) video. The address it comes from is a secret (it may carry a token): it is never stored here. */
@Serializable
data class DownloadItem(
    val id: String = UUID.randomUUID().toString(),
    val metaId: String,
    val type: String,
    val title: String,
    val poster: String? = null,
    val background: String? = null,
    val posterShape: PosterShape = PosterShape.POSTER,
    val videoId: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeTitle: String? = null,
    /** File name inside the downloads folder. */
    val fileName: String,
    val bytes: Long = 0,
    val totalBytes: Long? = null,
    val state: DownloadState = DownloadState.QUEUED,
    val error: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val finishedAt: Long? = null,
    /** Subtitles saved next to the video, so they work without the network too. */
    val subtitles: List<SavedSubtitle> = emptyList(),
) {
    val fraction: Double? get() = totalBytes?.takeIf { it > 0 }?.let { (bytes.toDouble() / it).coerceIn(0.0, 1.0) }
    val label: String get() = if (season != null && episode != null) "$title · S${season}E$episode" else title

    fun asMeta() = MetaItem(metaId, type, title, poster = poster, posterShape = posterShape, background = background)
    fun asVideo(): Video? = videoId?.let { Video(it, episodeTitle.orEmpty(), season = season, episode = episode) }
}

/**
 * The list of downloads, saved as JSON next to the files. The source address of an unfinished download lives in the [SecretStore]
 * (encrypted) and is deleted as soon as the download ends or is removed.
 */
class DownloadStore(private val folder: File, private val secrets: SecretStore) {
    private val file = JsonFileStore(File(folder, "downloads.json"), ListSerializer(DownloadItem.serializer()))
    private val _items = MutableStateFlow(file.load().orEmpty().map { if (it.state == DownloadState.RUNNING) it.copy(state = DownloadState.PAUSED) else it })
    val items: StateFlow<List<DownloadItem>> get() = _items

    fun fileOf(item: DownloadItem) = File(folder, item.fileName)

    @Synchronized
    fun add(meta: MetaItem, video: Video?, sourceUrl: String, headers: Map<String, String>, extension: String): DownloadItem {
        val existing = _items.value.firstOrNull { it.metaId == meta.id && it.videoId == video?.id && it.state != DownloadState.FAILED }
        if (existing != null) return existing
        val ext = extension.lowercase().filter { it.isLetterOrDigit() }.take(5).ifEmpty { "mp4" }
        val item = DownloadItem(
            metaId = meta.id, type = meta.type, title = meta.name, poster = meta.poster, background = meta.background, posterShape = meta.posterShape,
            videoId = video?.id, season = video?.season, episode = video?.episode, episodeTitle = video?.title?.takeIf { it.isNotBlank() },
            fileName = "", 
        ).let { it.copy(fileName = "${it.id}.$ext") }
        secrets.put(SOURCE_PREFIX + item.id, encodeSource(sourceUrl, headers))
        save(_items.value + item)
        return item
    }

    /** The address and headers of an unfinished download, or null when they are gone (then it cannot be resumed). */
    fun source(id: String): Pair<String, Map<String, String>>? = secrets.get(SOURCE_PREFIX + id)?.let(::decodeSource)

    @Synchronized
    fun update(id: String, change: (DownloadItem) -> DownloadItem) {
        save(_items.value.map { if (it.id == id) change(it) else it })
    }

    fun finished(id: String, bytes: Long) {
        update(id) { it.copy(state = DownloadState.DONE, bytes = bytes, totalBytes = bytes, error = null, finishedAt = System.currentTimeMillis()) }
        secrets.remove(SOURCE_PREFIX + id)
    }

    @Synchronized
    fun remove(id: String) {
        val item = _items.value.firstOrNull { it.id == id } ?: return
        fileOf(item).delete()
        File(folder, item.fileName + ".part").delete()
        item.subtitles.forEach { File(folder, it.fileName).delete() }
        secrets.remove(SOURCE_PREFIX + id)
        save(_items.value.filter { it.id != id })
    }

    fun item(id: String) = _items.value.firstOrNull { it.id == id }

    fun subtitleFile(sub: SavedSubtitle) = File(folder, sub.fileName)

    /** Saves a subtitle next to the video (replacing one of the same language). */
    @Synchronized
    fun saveSubtitle(id: String, lang: String, label: String, srt: String) {
        val item = item(id) ?: return
        val safeLang = lang.lowercase().filter { it.isLetterOrDigit() || it == '-' }.take(8).ifEmpty { "und" }
        val name = "${item.id}.$safeLang.srt"
        folder.mkdirs()
        File(folder, name).writeText(srt, Charsets.UTF_8)
        update(id) { it.copy(subtitles = it.subtitles.filter { s -> s.lang != safeLang } + SavedSubtitle(safeLang, label, name)) }
    }

    /** Every download of a series, to download a whole season and skip what is already there. */
    fun forMeta(metaId: String): List<DownloadItem> = _items.value.filter { it.metaId == metaId }

    /** The downloaded file of a title/episode, if there is a complete one. */
    fun completed(metaId: String, videoId: String?): DownloadItem? =
        _items.value.firstOrNull { it.metaId == metaId && it.videoId == videoId && it.state == DownloadState.DONE && fileOf(it).exists() }

    val usedBytes: Long get() = _items.value.sumOf { fileOf(it).takeIf { f -> f.exists() }?.length() ?: 0L }

    private fun save(list: List<DownloadItem>) {
        _items.value = list
        folder.mkdirs()
        file.save(list)
    }

    companion object {
        const val SOURCE_PREFIX = "download.source."

        fun encodeSource(url: String, headers: Map<String, String>): String =
            kotlinx.serialization.json.Json.encodeToString(Source.serializer(), Source(url, headers))

        fun decodeSource(text: String): Pair<String, Map<String, String>>? =
            runCatching { kotlinx.serialization.json.Json.decodeFromString(Source.serializer(), text) }.getOrNull()?.let { it.url to it.headers }

        /** The file extension of a source address (or of the name the addon gave), for the saved file. */
        fun extension(url: String, filename: String?): String {
            val fromName = filename?.substringAfterLast('.', "")?.takeIf { it.length in 2..4 }
            val path = url.substringBefore('?').substringBefore('#').substringAfterLast('/')
            val fromUrl = path.substringAfterLast('.', "").takeIf { it.length in 2..4 }
            return (fromName ?: fromUrl ?: "mp4").lowercase()
        }
    }

    @Serializable
    private data class Source(val url: String, val headers: Map<String, String> = emptyMap())
}
