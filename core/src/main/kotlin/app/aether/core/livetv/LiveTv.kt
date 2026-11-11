package app.aether.core.livetv

import java.text.Normalizer
import java.util.UUID
import kotlinx.serialization.Serializable

/** One channel of an M3U playlist. */
@Serializable
data class M3uChannel(
    val id: String,
    val name: String,
    val logo: String? = null,
    val group: String? = null,
    val url: String,
    /** `#EXTVLCOPT:http-user-agent` / `http-referrer`, when the playlist asks for them. */
    val userAgent: String? = null,
    val referrer: String? = null,
    val tvgId: String? = null,
) {
    /** The headers a player has to send for this channel. */
    val requestHeaders: Map<String, String>
        get() = buildMap {
            userAgent?.takeIf { it.isNotEmpty() }?.let { put("User-Agent", it) }
            referrer?.takeIf { it.isNotEmpty() }?.let { put("Referer", it) }
        }
}

data class M3uParseResult(val channels: List<M3uChannel>, val skipped: Int, val guides: List<String> = emptyList())

/** Reads M3U / M3U8 playlists (same rules as the iOS app): http(s) entries only, de-duplicated by name and address. */
object M3uParser {
    const val MAX_CHANNELS = 20_000

    fun parse(text: String, maxChannels: Int = MAX_CHANNELS): M3uParseResult {
        val channels = ArrayList<M3uChannel>()
        var skipped = 0
        val seen = HashSet<String>()
        var pending: Pair<Map<String, String>, String>? = null
        var agent: String? = null
        var referrer: String? = null
        var extGroup: String? = null
        val guides = ArrayList<String>()
        for (raw in text.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            when {
                line.startsWith("#EXTM3U") -> {
                    val attrs = attributes(line.removePrefix("#EXTM3U"))
                    for (key in listOf("url-tvg", "x-tvg-url")) {
                        for (address in attrs[key].orEmpty().split(',')) {
                            val value = address.trim()
                            val scheme = value.substringBefore("://", "").lowercase()
                            if ((scheme == "http" || scheme == "https") && value !in guides) guides.add(value)
                        }
                    }
                }
                line.startsWith("#EXTINF") -> {
                    val (attrs, name) = splitExtInf(line.removePrefix("#EXTINF:").removePrefix("#EXTINF"))
                    pending = attributes(attrs) to name
                    agent = null; referrer = null; extGroup = null
                }
                line.startsWith("#EXTVLCOPT:") -> {
                    val option = line.removePrefix("#EXTVLCOPT:")
                    val equals = option.indexOf('=')
                    if (equals > 0) {
                        val key = option.substring(0, equals).lowercase()
                        val value = option.substring(equals + 1).trim()
                        if (key == "http-user-agent") agent = value else if (key == "http-referrer" || key == "http-referer") referrer = value
                    }
                }
                line.startsWith("#EXTGRP:") -> extGroup = line.removePrefix("#EXTGRP:").trim()
                line.startsWith("#") -> continue
                pending != null -> {
                    val (attrs, rawName) = pending
                    pending = null
                    val scheme = line.substringBefore("://", "").lowercase()
                    val host = line.substringAfter("://", "").substringBefore('/')
                    if ((scheme != "http" && scheme != "https") || host.isEmpty() || line.any { it.isWhitespace() }) { skipped++; continue }
                    val name = rawName.trim().ifEmpty { attrs["tvg-name"] ?: "Canale" }
                    val key = name.lowercase() + "|" + line
                    if (!seen.add(key)) continue
                    channels.add(M3uChannel(stableId(key), name, nonEmpty(attrs["tvg-logo"]), nonEmpty(attrs["group-title"]) ?: nonEmpty(extGroup), line,
                        nonEmpty(agent), nonEmpty(referrer), nonEmpty(attrs["tvg-id"])))
                    if (channels.size >= maxChannels) break
                }
            }
        }
        return M3uParseResult(channels, skipped, guides)
    }

    private fun nonEmpty(text: String?) = text?.trim()?.takeIf { it.isNotEmpty() }

    /** The first comma outside quotes separates the attributes from the channel name. */
    fun splitExtInf(body: String): Pair<String, String> {
        var quote: Char? = null
        for ((index, c) in body.withIndex()) {
            if (quote != null) { if (c == quote) quote = null }
            else if (c == '"' || c == '\'') quote = c
            else if (c == ',') return body.substring(0, index) to body.substring(index + 1)
        }
        return body to ""
    }

    fun attributes(text: String): Map<String, String> {
        val result = HashMap<String, String>()
        val key = StringBuilder()
        val value = StringBuilder()
        var quote: Char? = null
        var isValue = false
        for (c in text) {
            when {
                quote != null -> if (c == quote) { quote = null; result[key.toString().lowercase()] = value.toString(); key.clear(); value.clear(); isValue = false } else value.append(c)
                c == '=' && key.isNotEmpty() && !isValue -> isValue = true
                isValue && (c == '"' || c == '\'') -> quote = c
                c == ' ' || c == '\t' -> if (!isValue) key.clear()
                !isValue -> key.append(c)
            }
        }
        return result
    }

    /** FNV-1a 64: the same channel keeps the same id from one launch to the next (same ids as on iOS). */
    fun stableId(text: String): String {
        var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toLong() and 0xFF)
            hash *= 0x100000001b3L
        }
        return java.lang.Long.toUnsignedString(hash, 16)
    }
}

@Serializable
data class LivePlaylist(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    /** null for a list imported from a file (its channels live in the cache only). */
    val url: String? = null,
    val addedAt: Long = System.currentTimeMillis(),
)

/** A channel kept in «Preferiti» of Live TV: what is needed to show it and to play it again. */
@Serializable
data class LiveFavorite(
    val id: String,
    val name: String,
    val logo: String? = null,
    val url: String? = null,
    val userAgent: String? = null,
    val referrer: String? = null,
    val metaType: String? = null,
    val metaId: String? = null,
)

@Serializable
enum class LiveGuideStyle(val title: String) { ROWS("Sotto i canali"), GRID("Griglia per orario") }

@Serializable
data class LiveTvSettings(
    /** The «Live TV» entry in the side menu. */
    val showTab: Boolean = false,
    val playlists: List<LivePlaylist> = emptyList(),
    /** Catalogs (`<addon id>/<catalog key>`) marked as live TV although not of the «tv» type, and live catalogs switched off. */
    val includedCatalogs: List<String> = emptyList(),
    val excludedCatalogs: List<String> = emptyList(),
    val favorites: List<LiveFavorite> = emptyList(),
    val guideEnabled: Boolean = true,
    /** The viewer's own XMLTV address (.xml or .xml.gz); empty for the playlist's own guide, else the public Italian one. */
    val guideUrl: String = "",
    val guideStyle: LiveGuideStyle = LiveGuideStyle.ROWS,
) {
    /** The guide to download: the viewer's address, else the one a playlist announces (`url-tvg`), else the public Italian one. */
    fun guideAddress(announced: List<String>): String? {
        if (!guideEnabled) return null
        guideUrl.trim().takeIf { it.isNotEmpty() }?.let { return it }
        return announced.firstOrNull { it.isNotEmpty() } ?: TvGuide.DEFAULT_ITALIAN_URL
    }

    fun includes(catalogKey: String, isTvType: Boolean): Boolean = catalogKey !in excludedCatalogs && (isTvType || catalogKey in includedCatalogs)

    fun settingIncluded(included: Boolean, catalogKey: String, isTvType: Boolean): LiveTvSettings {
        val inc = includedCatalogs.filter { it != catalogKey }.toMutableList()
        val exc = excludedCatalogs.filter { it != catalogKey }.toMutableList()
        if (included && !isTvType) inc.add(catalogKey)
        if (!included && isTvType) exc.add(catalogKey)
        return copy(includedCatalogs = inc, excludedCatalogs = exc)
    }

    fun isFavorite(id: String) = favorites.any { it.id == id }

    fun togglingFavorite(favorite: LiveFavorite): LiveTvSettings =
        if (isFavorite(favorite.id)) copy(favorites = favorites.filter { it.id != favorite.id }) else copy(favorites = listOf(favorite) + favorites)
}

object LiveChannelList {
    private fun fold(text: String) = Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()

    /** Channels whose name or group contains every word of [query] (accents and case ignored), in the chosen group. */
    fun filter(channels: List<M3uChannel>, query: String, group: String?): List<M3uChannel> {
        val words = fold(query).split(' ').filter { it.isNotEmpty() }
        return channels.filter { channel ->
            if (group != null && channel.group != group) return@filter false
            if (words.isEmpty()) return@filter true
            val haystack = fold(channel.name + " " + channel.group.orEmpty())
            words.all { it in haystack }
        }
    }

    /** The groups in the order of first appearance, with how many channels each has. */
    fun groups(channels: List<M3uChannel>): List<Pair<String, Int>> {
        val counts = LinkedHashMap<String, Int>()
        for (channel in channels) counts.merge(channel.group ?: "Senza gruppo", 1, Int::plus)
        return counts.map { it.key to it.value }
    }
}
