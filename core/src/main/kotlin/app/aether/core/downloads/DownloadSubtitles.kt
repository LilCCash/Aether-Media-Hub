package app.aether.core.downloads

import app.aether.core.AetherEngine
import app.aether.core.model.AddonStream
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.core.net.HttpRequest
import app.aether.core.playback.Languages
import app.aether.core.playback.SubtitleParser
import kotlinx.coroutines.CancellationException

/**
 * Saves the subtitles of a download next to the video: for each language the viewer wants (preferred, second, and the TV's), the first
 * subtitle that reads well among those of the source, the addons and OpenSubtitles.org. They are converted to SubRip UTF-8.
 */
object DownloadSubtitles {
    suspend fun save(engine: AetherEngine, downloadId: String, meta: MetaItem, video: Video?, stream: AddonStream?, systemLanguage: String?): Int {
        val playback = engine.settings.value.value.playback
        val wanted = listOf(playback.preferredSubtitleLanguage, playback.secondarySubtitleLanguage, systemLanguage.orEmpty())
            .map { if (it == "system") systemLanguage.orEmpty() else it }.filter { it.isNotBlank() && it != "off" }.map { Languages.normalise(it) }.distinct()
        if (wanted.isEmpty()) return 0
        val imdb = meta.imdbId ?: meta.externalIds.imdb ?: meta.id.substringBefore(':').takeIf { it.startsWith("tt") }
        val imdbVideoId = imdb?.let { if (video?.season != null && video.episode != null) "$it:${video.season}:${video.episode}" else it }
        val all = try { engine.subtitlesFor(meta.type, video?.id ?: meta.id, imdbVideoId, stream, systemLanguage) } catch (e: Throwable) { if (e is CancellationException) throw e; emptyList() }
        var saved = 0
        for (lang in wanted) {
            for (sub in all.filter { Languages.matches(it.lang, lang) }.take(4)) {
                val cues = try {
                    val response = engine.http.send(HttpRequest(sub.url, timeoutSeconds = 20, maxBytes = 4 * 1024 * 1024))
                    if (response.isSuccess) SubtitleParser.parse(SubtitleParser.decode(response.body)) else emptyList()
                } catch (e: Throwable) { if (e is CancellationException) throw e; emptyList() }
                if (cues.size < 10) continue
                engine.downloads.saveSubtitle(downloadId, lang, "${Languages.displayName(lang)} · ${sub.addonName ?: "addon"}", SubtitleParser.toSrt(cues))
                saved++
                break
            }
        }
        engine.log.info("download", "sottotitoli salvati con il video: $saved")
        return saved
    }
}
