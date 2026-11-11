package app.aether.core.addons

import app.aether.core.debrid.DebridService
import app.aether.core.debrid.StreamDebridContext
import app.aether.core.model.AddonStream
import java.net.URLDecoder
import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Which debrid service an addon is meant for, chosen on the addon's page. [BOTH] (the default) keeps it in use whatever is active. */
@Serializable
enum class AddonDebridScope(val title: String) { BOTH("Entrambi"), TORBOX("TorBox"), REAL_DEBRID("Real-Debrid") }

/**
 * How the sources of an addon are asked for, given the active debrid service (same rules as the iOS app):
 * - TorBox active: every addon exactly as installed; only the ones marked «Real-Debrid» are left out.
 * - Real-Debrid active: the ones marked «TorBox» are left out; the ones marked «Real-Debrid» are used as installed; the ones marked
 *   «Entrambi» that Aether knows how to configure (Torrentio, Comet) are asked with Real-Debrid and the viewer's token in place of
 *   their own debrid, set to give only the sources already ready on Real-Debrid. The saved addon never changes.
 */
object AddonDebridRouting {
    enum class Kind { TORRENTIO, COMET }

    sealed class Decision {
        data class Use(val url: String, val switched: Kind?) : Decision()
        object Skip : Decision()
        /** A Torrentio or Comet whose address could not be read: not asked, so the other service's sources do not slip in. */
        data class Unreadable(val kind: Kind) : Decision()
    }

    fun kind(host: String): Kind? {
        val h = host.lowercase()
        return when {
            "torrentio" in h -> Kind.TORRENTIO
            "comet" in h -> Kind.COMET
            else -> null
        }
    }

    fun decide(handle: AddonHandle, context: StreamDebridContext?): Decision {
        context ?: return Decision.Use(handle.transportUrl, null)
        val scope = handle.addon.debridScope
        return when (context.service) {
            DebridService.TORBOX -> if (scope == AddonDebridScope.REAL_DEBRID) Decision.Skip else Decision.Use(handle.transportUrl, null)
            DebridService.REAL_DEBRID -> when (scope) {
                AddonDebridScope.TORBOX -> Decision.Skip
                AddonDebridScope.REAL_DEBRID -> Decision.Use(handle.transportUrl, null)
                AddonDebridScope.BOTH -> {
                    val key = context.realDebridKey?.trim().orEmpty()
                    val known = kind(hostOf(handle.transportUrl))
                    if (key.isEmpty() || known == null) Decision.Use(handle.transportUrl, null)
                    else rewrite(handle.transportUrl, known, key)?.let { Decision.Use(it, known) } ?: Decision.Unreadable(known)
                }
            }
        }
    }

    fun rewrite(url: String, kind: Kind, realDebridKey: String): String? = when (kind) {
        Kind.TORRENTIO -> rewriteTorrentio(url, realDebridKey)
        Kind.COMET -> rewriteComet(url, realDebridKey)
    }

    /** A source of a switched addon that is not ready on Real-Debrid, left out as a second guard behind the addon's own option. */
    fun isReadyOnRealDebrid(stream: AddonStream, kind: Kind): Boolean {
        val name = stream.name.orEmpty()
        return when (kind) {
            Kind.TORRENTIO -> "download]" !in name && "RD error" !in name
            Kind.COMET -> name.codePoints().noneMatch { it == 0x2B07 || it == 0x1F9F2 } && "[RD U]" !in name
        }
    }

    private data class Parts(val prefix: String, val segments: MutableList<String>, val suffix: String)

    /** `https://host` + path segments + `?query#fragment`. */
    private fun split(url: String): Parts? {
        val schemeEnd = url.indexOf("://").takeIf { it > 0 } ?: return null
        val pathStart = url.indexOf('/', schemeEnd + 3).takeIf { it > 0 } ?: return null
        val tailStart = url.indexOfAny(charArrayOf('?', '#'), pathStart).let { if (it < 0) url.length else it }
        val segments = url.substring(pathStart, tailStart).split('/').filter { it.isNotEmpty() }.toMutableList()
        return Parts(url.substring(0, pathStart), segments, url.substring(tailStart))
    }

    private fun join(parts: Parts) = parts.prefix + "/" + parts.segments.joinToString("/") + parts.suffix

    private fun hostOf(url: String) = url.substringAfter("://", "").substringBefore('/').substringBefore('?').substringBefore(':')

    val torrentioDebridKeys = setOf("realdebrid", "premiumize", "alldebrid", "debridlink", "easydebrid", "offcloud", "torbox", "putio", "highway")

    fun rewriteTorrentio(url: String, key: String): String? {
        val parts = split(url) ?: return null
        val segments = parts.segments
        if (segments.lastOrNull() != "manifest.json") return null
        val hasConfig = segments.size >= 2
        val encodedConfig = if (hasConfig) segments[segments.size - 2] else ""
        val config = runCatching { URLDecoder.decode(encodedConfig.replace("+", "%2B"), "UTF-8") }.getOrDefault(encodedConfig)
        val pairs = config.split('|').filter { it.isNotEmpty() }.mapNotNull { part ->
            val pieces = part.split('=', limit = 2)
            if (pieces.size == 2 && pieces[0].isNotEmpty()) pieces[0] to pieces[1] else null
        }.filter { it.first.lowercase() !in torrentioDebridKeys }.toMutableList()
        val index = pairs.indexOfFirst { it.first == "debridoptions" }
        if (index >= 0) {
            val options = pairs[index].second.split(',').filter { it.isNotEmpty() }.toMutableList()
            if ("nodownloadlinks" !in options) options.add("nodownloadlinks")
            pairs[index] = "debridoptions" to options.joinToString(",")
        } else {
            pairs.add("debridoptions" to "nodownloadlinks")
        }
        pairs.add("realdebrid" to key)
        val rebuilt = pairs.joinToString("|") { "${it.first}=${it.second}" }
        val encoded = encodePathSegment(rebuilt)
        if (hasConfig) segments[segments.size - 2] = encoded else segments.add(segments.size - 1, encoded)
        return join(parts)
    }

    /** Percent-encodes what a path segment cannot carry, keeping Torrentio's `=` `,` and encoding `|`. */
    private fun encodePathSegment(text: String): String = buildString {
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt() and 0xFF
            val ch = c.toChar()
            if (ch.isLetterOrDigit() && c < 0x80 || ch in "-._~!$&'()*+,;=:@") append(ch) else append('%').append("%02X".format(c))
        }
    }

    fun rewriteComet(url: String, key: String): String? {
        val parts = split(url) ?: return null
        val segments = parts.segments
        if (segments.size < 2 || segments.last() != "manifest.json") return null
        val config = decodeCometConfig(segments[segments.size - 2]) ?: return null
        val updated = buildJsonObject {
            config.forEach { (k, v) -> if (k !in COMET_DEBRID_FIELDS) put(k, v) }
            put("debridServices", buildJsonArray { add(buildJsonObject { put("service", "realdebrid"); put("apiKey", key) }) })
            put("debridService", "realdebrid")
            put("debridApiKey", key)
            put("cachedOnly", true)
            put("enableTorrent", false)
        }
        segments[segments.size - 2] = encodeCometConfig(updated) ?: return null
        return join(parts)
    }

    private val COMET_DEBRID_FIELDS = setOf("debridServices", "debridService", "debridApiKey", "cachedOnly", "enableTorrent")

    fun decodeCometConfig(segment: String): JsonObject? {
        var text = runCatching { URLDecoder.decode(segment, "UTF-8") }.getOrDefault(segment).replace('-', '+').replace('_', '/')
        while (text.length % 4 != 0) text += "="
        return runCatching { Json.parseToJsonElement(String(Base64.getDecoder().decode(text), Charsets.UTF_8)) as? JsonObject }.getOrNull()
    }

    /** Base64 of the JSON with sorted keys; `?`, `>`, `~` written as JSON escapes so the result has no `/` or `+`. */
    fun encodeCometConfig(config: JsonObject): String? {
        val json = sorted(config).toString()
            .replace("?", "\\u003f").replace(">", "\\u003e").replace("~", "\\u007e").replace("\u007F", "\\u007f")
        val result = Base64.getEncoder().encodeToString(json.toByteArray(Charsets.UTF_8))
        return if ('/' in result || '+' in result) null else result
    }

    private fun sorted(element: kotlinx.serialization.json.JsonElement): kotlinx.serialization.json.JsonElement = when (element) {
        is JsonObject -> JsonObject(element.toSortedMap().mapValues { sorted(it.value) })
        is JsonArray -> JsonArray(element.map { sorted(it) })
        is JsonPrimitive -> element
        else -> element
    }
}
