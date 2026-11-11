package app.aether.core.model

import app.aether.core.json.flexBool
import app.aether.core.json.flexInt
import app.aether.core.json.flexLong
import app.aether.core.json.flexString
import app.aether.core.json.lossyList
import app.aether.core.json.obj
import app.aether.core.json.stringList
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Where a stream's bytes come from (`StreamSource` in stremio-core). */
@Serializable
sealed class StreamSource {
    @Serializable data class Url(val url: String) : StreamSource()
    @Serializable data class YouTube(val id: String) : StreamSource()
    @Serializable data class Torrent(val infoHash: String, val fileIndex: Int? = null, val trackers: List<String> = emptyList()) : StreamSource()
    @Serializable data class External(val url: String) : StreamSource()
    @Serializable data class PlayerFrame(val url: String) : StreamSource()
    @Serializable data class Archive(val kind: String) : StreamSource()
    @Serializable data object Unknown : StreamSource()
}

@Serializable
data class StreamBehaviorHints(
    val notWebReady: Boolean = false,
    val bingeGroup: String? = null,
    val countryWhitelist: List<String> = emptyList(),
    val proxyRequestHeaders: Map<String, String> = emptyMap(),
    val proxyResponseHeaders: Map<String, String> = emptyMap(),
    val videoHash: String? = null,
    val videoSize: Long? = null,
    val filename: String? = null,
)

/** A subtitle track offered by an addon (`subtitles` resource or `stream.subtitles`). */
@Serializable
data class AddonSubtitle(
    val id: String,
    val url: String,
    val lang: String,
    val label: String? = null,
    val addonName: String? = null,
)

/** One playable (or not) option returned by a `stream` resource. */
@Serializable
data class AddonStream(
    val source: StreamSource,
    val name: String? = null,
    val details: String? = null,
    val thumbnail: String? = null,
    val subtitles: List<AddonSubtitle> = emptyList(),
    val behaviorHints: StreamBehaviorHints = StreamBehaviorHints(),
    /** Annotated by the aggregator, never decoded from JSON. */
    val addonId: String? = null,
    val addonName: String? = null,
) {
    /** Stable within one result list; includes the addon so identical URLs from different addons stay distinct. */
    val id: String
        get() = "${addonId.orEmpty()}|${sourceKey(source)}|${name.orEmpty()}|${details.orEmpty()}"

    val directUrl: String? get() = (source as? StreamSource.Url)?.url

    /** Text scanned by the analyzer: name + description + filename + the last path component of the link. */
    val searchableText: String
        get() {
            val parts = ArrayList<String>()
            name?.let { parts.add(it) }
            details?.let { parts.add(it) }
            behaviorHints.filename?.let { parts.add(it) }
            directUrl?.let { url -> parts.add(url.substringBefore('?').substringAfterLast('/')) }
            return parts.joinToString(" ")
        }

    companion object {
        fun sourceKey(source: StreamSource): String = when (source) {
            is StreamSource.Url -> "url:${source.url}"
            is StreamSource.YouTube -> "yt:${source.id}"
            is StreamSource.Torrent -> "bt:${source.infoHash.lowercase()}:${source.fileIndex ?: "-"}"
            is StreamSource.External -> "ext:${source.url}"
            is StreamSource.PlayerFrame -> "frame:${source.url}"
            is StreamSource.Archive -> "archive:${source.kind}"
            StreamSource.Unknown -> "unknown"
        }
    }
}

object StreamParser {
    fun parse(item: JsonObject): AddonStream {
        val url = item.flexString("url")
        val yt = item.flexString("ytId")
        val infoHash = item.flexString("infoHash")
        val external = item.flexString("externalUrl")
        val frame = item.flexString("playerFrameUrl")
        val source: StreamSource = when {
            !url.isNullOrEmpty() -> StreamSource.Url(url)
            !yt.isNullOrEmpty() -> StreamSource.YouTube(yt)
            !infoHash.isNullOrEmpty() -> StreamSource.Torrent(infoHash, item.flexInt("fileIdx"), item.stringList("sources") + item.stringList("announce"))
            !external.isNullOrEmpty() -> StreamSource.External(external)
            !frame.isNullOrEmpty() -> StreamSource.PlayerFrame(frame)
            item.containsKey("nzbUrl") -> StreamSource.Archive("nzb")
            item.containsKey("rarUrls") -> StreamSource.Archive("rar")
            item.containsKey("zipUrls") -> StreamSource.Archive("zip")
            item.containsKey("7zipUrls") -> StreamSource.Archive("7zip")
            item.containsKey("tgzUrls") -> StreamSource.Archive("tgz")
            item.containsKey("tarUrls") -> StreamSource.Archive("tar")
            else -> StreamSource.Unknown
        }
        return AddonStream(
            source = source,
            name = item.flexString("name"),
            details = item.flexString("description") ?: item.flexString("title"),
            thumbnail = item.flexString("thumbnail"),
            subtitles = item.lossyList("subtitles") { parseSubtitle(it) },
            behaviorHints = item.obj("behaviorHints")?.let { parseHints(it) } ?: StreamBehaviorHints(),
        )
    }

    fun parseHints(hints: JsonObject): StreamBehaviorHints {
        val proxy = hints.obj("proxyHeaders")
        return StreamBehaviorHints(
            notWebReady = hints.flexBool("notWebReady") ?: false,
            bingeGroup = hints.flexString("bingeGroup"),
            countryWhitelist = hints.stringList("countryWhitelist"),
            proxyRequestHeaders = headers(proxy?.obj("request")),
            proxyResponseHeaders = headers(proxy?.obj("response")),
            videoHash = hints.flexString("videoHash"),
            videoSize = hints.flexLong("videoSize"),
            filename = hints.flexString("filename"),
        )
    }

    private fun headers(source: JsonObject?): Map<String, String> {
        if (source == null) return emptyMap()
        val result = LinkedHashMap<String, String>()
        for ((name, value) in source) {
            val text = (value as? JsonPrimitive)?.content ?: continue
            result[name] = text
        }
        return result
    }

    fun parseSubtitle(item: JsonObject): AddonSubtitle? {
        val url = item.flexString("url")?.takeIf { it.isNotEmpty() } ?: return null
        return AddonSubtitle(
            id = item.flexString("id") ?: url,
            url = url,
            lang = item.flexString("lang") ?: "und",
            label = item.flexString("label"),
        )
    }
}
