package app.aether.core.addons

import app.aether.core.json.Flex
import app.aether.core.json.flexInt
import app.aether.core.json.flexString
import app.aether.core.json.lossyList
import app.aether.core.model.AddonManifest
import app.aether.core.model.AddonStream
import app.aether.core.model.AddonSubtitle
import app.aether.core.model.ManifestParseResult
import app.aether.core.model.ManifestParser
import app.aether.core.model.MetaItem
import app.aether.core.model.MetaParser
import app.aether.core.model.ResourceName
import app.aether.core.model.StreamParser
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonElement

/** Cache hints an addon may put in any response, in seconds. */
data class CacheHints(val maxAge: Int? = null, val staleRevalidate: Int? = null, val staleError: Int? = null)

/** Entry of an `addon_catalog` response. */
data class AddonCatalogEntry(val transportName: String, val transportUrl: String, val manifest: AddonManifest)

sealed class AddonPayload {
    data class Metas(val items: List<MetaItem>) : AddonPayload()
    data class Meta(val item: MetaItem) : AddonPayload()
    data class Streams(val items: List<AddonStream>) : AddonPayload()
    data class Subtitles(val items: List<AddonSubtitle>) : AddonPayload()
    data class Addons(val items: List<AddonCatalogEntry>) : AddonPayload()
}

data class AddonResponse(val payload: AddonPayload, val cache: CacheHints = CacheHints(), val isStale: Boolean = false)

sealed class ResponseDecodingError(val detail: String) : Exception(detail) {
    object NotJson : ResponseDecodingError("non è JSON")
    object NotAnObject : ResponseDecodingError("non è un oggetto JSON")
    class MissingKey(key: String) : ResponseDecodingError("manca «$key»")
}

object ResponseDecoder {
    /** Decodes an addon response for the requested resource. `{}` for a catalog is malformed; `null`/empty arrays are valid empty results. */
    fun decode(text: String, resource: String): AddonResponse {
        val element: JsonElement = Flex.parse(text) ?: throw ResponseDecodingError.NotJson
        val root = element as? JsonObject ?: throw ResponseDecodingError.NotAnObject
        val hints = CacheHints(root.flexInt("cacheMaxAge"), root.flexInt("staleRevalidate"), root.flexInt("staleError"))
        return when (resource) {
            ResourceName.CATALOG -> {
                val key = when {
                    root.containsKey("metas") -> "metas"
                    root.containsKey("metasDetailed") -> "metasDetailed"
                    else -> throw ResponseDecodingError.MissingKey("metas")
                }
                AddonResponse(AddonPayload.Metas(root.lossyList(key) { MetaParser.parse(it) }), hints)
            }
            ResourceName.META -> {
                val meta = (root["meta"] as? JsonObject)?.let { MetaParser.parse(it) } ?: throw ResponseDecodingError.MissingKey("meta")
                AddonResponse(AddonPayload.Meta(meta), hints)
            }
            ResourceName.STREAM -> {
                if (!root.containsKey("streams")) throw ResponseDecodingError.MissingKey("streams")
                AddonResponse(AddonPayload.Streams(root.lossyList("streams") { StreamParser.parse(it) }), hints)
            }
            ResourceName.SUBTITLES -> {
                if (!root.containsKey("subtitles")) throw ResponseDecodingError.MissingKey("subtitles")
                AddonResponse(AddonPayload.Subtitles(root.lossyList("subtitles") { StreamParser.parseSubtitle(it) }), hints)
            }
            ResourceName.ADDON_CATALOG -> {
                if (!root.containsKey("addons")) throw ResponseDecodingError.MissingKey("addons")
                val entries = root.lossyList("addons") { entry ->
                    val url = entry.flexString("transportUrl") ?: return@lossyList null
                    val manifest = (ManifestParser.parse(entry["manifest"]) as? ManifestParseResult.Success)?.manifest ?: return@lossyList null
                    AddonCatalogEntry(entry.flexString("transportName") ?: "http", url, manifest)
                }
                AddonResponse(AddonPayload.Addons(entries), hints)
            }
            else -> throw ResponseDecodingError.MissingKey(resource)
        }
    }

    fun decodeManifest(text: String): AddonManifest {
        val element = Flex.parse(text) ?: throw ResponseDecodingError.NotJson
        return when (val result = ManifestParser.parse(element)) {
            is ManifestParseResult.Success -> result.manifest
            is ManifestParseResult.Failure -> throw app.aether.core.net.AddonError.InvalidManifest(result.message)
        }
    }
}
