package app.aether.core.library

import app.aether.core.json.Flex
import app.aether.core.json.flexBool
import app.aether.core.json.flexDouble
import app.aether.core.json.flexInt
import app.aether.core.json.flexString
import app.aether.core.model.PosterShape
import app.aether.core.util.AddonDate
import java.time.Instant
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

sealed class BackupError(override val message: String) : Exception(message) {
    object NotABackup : BackupError("Il file non è un backup di Aether.")
    class UnsupportedVersion(version: Int) : BackupError("Backup creato da una versione più recente (formato $version).")
    object Unreadable : BackupError("Il file di backup è danneggiato.")
}

/** What a backup contains once read. Addon addresses are only present when the user chose to include them. */
data class BackupContents(
    val createdAt: Long,
    val library: LibraryState,
    val addonUrls: List<String>,
    val includesAddonUrls: Boolean,
    val platform: String?,
)

/**
 * Backups use the same self-describing JSON document as Aether for iPhone (`app.aether.backup`, dates in ISO 8601), so a library
 * saved on one device can be restored on the other. The settings of the two apps are different and are not exchanged.
 */
object BackupCodec {
    const val MARKER = "app.aether.backup"
    const val FORMAT = 1

    fun encode(library: LibraryState, addonUrls: List<String>, includeAddonUrls: Boolean, appVersion: String, now: Long = System.currentTimeMillis()): String {
        val root = buildJsonObject {
            put("marker", MARKER)
            put("formatVersion", FORMAT)
            put("platform", "android-tv")
            put("createdAt", iso(now))
            put("appVersion", appVersion)
            put("includesAddonURLs", includeAddonUrls)
            putJsonObject("library") {
                put("schemaVersion", 1)
                putJsonObject("entries") {
                    for ((id, e) in library.entries) putJsonObject(id) {
                        put("id", e.id); put("type", e.type); put("name", e.name)
                        e.poster?.let { put("poster", it) }
                        put("posterShape", e.posterShape.name.lowercase())
                        e.background?.let { put("background", it) }
                        e.logo?.let { put("logo", it) }
                        e.releaseInfo?.let { put("releaseInfo", it) }
                        e.imdbRating?.let { put("imdbRating", it) }
                        put("inWatchlist", e.inWatchlist); put("isFavorite", e.isFavorite)
                        put("addedAt", iso(e.addedAt)); put("modifiedAt", iso(e.modifiedAt)); put("isRemoved", e.isRemoved)
                    }
                }
                putJsonObject("progress") {
                    for ((id, p) in library.progress) putJsonObject(id) {
                        put("id", p.id); put("metaID", p.metaId); put("videoID", p.videoId); put("type", p.type); put("title", p.title)
                        p.episodeTitle?.let { put("episodeTitle", it) }
                        p.season?.let { put("season", it) }
                        p.episode?.let { put("episode", it) }
                        p.poster?.let { put("poster", it) }
                        put("posterShape", p.posterShape.name.lowercase())
                        p.background?.let { put("background", it) }
                        put("position", p.position); put("duration", p.duration); put("updatedAt", iso(p.updatedAt))
                        put("isCompleted", p.isCompleted); put("isDismissed", p.isDismissed)
                    }
                }
                putJsonArray("searchHistory") {
                    for (item in library.searchHistory) add(buildJsonObject { put("query", item.query); put("date", iso(item.date)) })
                }
            }
            putJsonArray("addons") {
                if (includeAddonUrls) for (url in addonUrls) add(buildJsonObject { put("url", url) })
            }
        }
        return Flex.json.encodeToString(JsonObject.serializer(), root)
    }

    fun decode(text: String): BackupContents {
        val root = Flex.parse(text) as? JsonObject ?: throw BackupError.Unreadable
        if (root.flexString("marker") != MARKER) throw BackupError.NotABackup
        val version = root.flexInt("formatVersion") ?: 1
        if (version > FORMAT) throw BackupError.UnsupportedVersion(version)
        try {
            val library = root["library"] as? JsonObject
            val entries = HashMap<String, LibraryEntry>()
            (library?.get("entries") as? JsonObject)?.forEach { (id, value) ->
                val e = value as? JsonObject ?: return@forEach
                entries[id] = LibraryEntry(
                    id = e.flexString("id") ?: id, type = e.flexString("type") ?: "other", name = e.flexString("name") ?: id,
                    poster = e.flexString("poster"), posterShape = PosterShape.parse(e.flexString("posterShape")),
                    background = e.flexString("background"), logo = e.flexString("logo"), releaseInfo = e.flexString("releaseInfo"),
                    imdbRating = e.flexString("imdbRating"), inWatchlist = e.flexBool("inWatchlist") ?: false,
                    isFavorite = e.flexBool("isFavorite") ?: false, addedAt = millis(e.flexString("addedAt")),
                    modifiedAt = millis(e.flexString("modifiedAt")), isRemoved = e.flexBool("isRemoved") ?: false,
                )
            }
            val progress = HashMap<String, PlaybackProgress>()
            (library?.get("progress") as? JsonObject)?.forEach { (_, value) ->
                val p = value as? JsonObject ?: return@forEach
                val metaId = p.flexString("metaID") ?: return@forEach
                val videoId = p.flexString("videoID") ?: return@forEach
                val record = PlaybackProgress(
                    metaId = metaId, videoId = videoId, type = p.flexString("type") ?: "other", title = p.flexString("title") ?: metaId,
                    episodeTitle = p.flexString("episodeTitle"), season = p.flexInt("season"), episode = p.flexInt("episode"),
                    poster = p.flexString("poster"), posterShape = PosterShape.parse(p.flexString("posterShape")),
                    background = p.flexString("background"), position = p.flexDouble("position") ?: 0.0, duration = p.flexDouble("duration") ?: 0.0,
                    updatedAt = millis(p.flexString("updatedAt")), isCompleted = p.flexBool("isCompleted") ?: false,
                    isDismissed = p.flexBool("isDismissed") ?: false,
                )
                progress[record.id] = record
            }
            val history = ((library?.get("searchHistory") as? JsonArray) ?: JsonArray(emptyList())).mapNotNull { element ->
                val item = element as? JsonObject ?: return@mapNotNull null
                val query = item.flexString("query")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                SearchHistoryItem(query, millis(item.flexString("date")))
            }
            val urls = ((root["addons"] as? JsonArray) ?: JsonArray(emptyList())).mapNotNull { element ->
                (element as? JsonObject)?.flexString("url")
            }
            return BackupContents(
                createdAt = millis(root.flexString("createdAt")), library = LibraryState(entries = entries, progress = progress, searchHistory = history),
                addonUrls = urls, includesAddonUrls = root.flexBool("includesAddonURLs") ?: false, platform = root.flexString("platform"),
            )
        } catch (error: Exception) {
            throw BackupError.Unreadable
        }
    }

    private fun iso(millis: Long): String = Instant.ofEpochMilli(millis).toString()
    private fun millis(text: String?): Long = AddonDate.parse(text)?.toEpochMilli() ?: 0L
}
