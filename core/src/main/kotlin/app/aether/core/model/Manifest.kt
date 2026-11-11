package app.aether.core.model

import app.aether.core.json.flexBool
import app.aether.core.json.flexInt
import app.aether.core.json.flexString
import app.aether.core.json.has
import app.aether.core.json.lossyList
import app.aether.core.json.obj
import app.aether.core.json.stringList
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Well known Stremio content types. Addons may declare others, so types stay plain strings across the engine. */
object ContentType {
    const val MOVIE = "movie"
    const val SERIES = "series"
    const val CHANNEL = "channel"
    const val TV = "tv"
    const val ANIME = "anime"
    const val OTHER = "other"

    fun hasEpisodes(type: String) = type == SERIES || type == ANIME || type == CHANNEL
    fun isLive(type: String) = type == TV
}

@Serializable
data class ExtraValue(val name: String, val value: String)

/** `{resource}/{type}/{id}` plus optional extra values. */
@Serializable
data class ResourcePath(
    val resource: String,
    val type: String,
    val id: String,
    val extra: List<ExtraValue> = emptyList(),
) {
    fun extraValue(name: String): String? = extra.firstOrNull { it.name == name }?.value
}

object ResourceName {
    const val CATALOG = "catalog"
    const val META = "meta"
    const val STREAM = "stream"
    const val SUBTITLES = "subtitles"
    const val ADDON_CATALOG = "addon_catalog"
}

@Serializable
data class ManifestResource(
    val name: String,
    val types: List<String>? = null,
    val idPrefixes: List<String>? = null,
)

@Serializable
data class ExtraProperty(
    val name: String,
    val isRequired: Boolean = false,
    val options: List<String> = emptyList(),
    val optionsLimit: Int = 1,
)

@Serializable
data class ManifestCatalog(
    val type: String,
    val id: String,
    val name: String,
    val extra: List<ExtraProperty> = emptyList(),
) {
    /** Stable identity inside one addon. */
    val key: String get() = "$type/$id"

    fun extraProperty(name: String): ExtraProperty? = extra.firstOrNull { it.name == name }
    val supportsSearch: Boolean get() = extraProperty("search") != null
    val supportsSkip: Boolean get() = extraProperty("skip") != null
    val genreOptions: List<String> get() = extraProperty("genre")?.options.orEmpty()
    val requiredExtraNames: List<String> get() = extra.filter { it.isRequired }.map { it.name }

    /** True if the catalog can be listed without the user supplying anything. */
    val isPlainFeed: Boolean get() = requiredExtraNames.isEmpty()

    /** Every given extra must be declared and every required extra must be given (`is_extra_supported` in stremio-core). */
    fun isExtraSupported(given: List<ExtraValue>): Boolean {
        val allDeclared = given.all { value -> extra.any { it.name == value.name } }
        val requiredGiven = extra.filter { it.isRequired }.all { property -> given.any { it.name == property.name } }
        return allDeclared && requiredGiven
    }
}

@Serializable
data class ManifestBehaviorHints(
    val adult: Boolean = false,
    val p2p: Boolean = false,
    val configurable: Boolean = false,
    val configurationRequired: Boolean = false,
    val epgProvider: Boolean = false,
)

@Serializable
data class ManifestConfigItem(
    val key: String,
    val type: String = "text",
    val title: String? = null,
    val defaultValue: String? = null,
    val options: List<String> = emptyList(),
    val isRequired: Boolean = false,
)

/** A Stremio addon manifest (`/manifest.json`). */
@Serializable
data class AddonManifest(
    val id: String,
    val version: String,
    val name: String,
    val description: String? = null,
    val logo: String? = null,
    val background: String? = null,
    val contactEmail: String? = null,
    val types: List<String> = emptyList(),
    val resources: List<ManifestResource> = emptyList(),
    val idPrefixes: List<String>? = null,
    val catalogs: List<ManifestCatalog> = emptyList(),
    val addonCatalogs: List<ManifestCatalog> = emptyList(),
    val behaviorHints: ManifestBehaviorHints = ManifestBehaviorHints(),
    val config: List<ManifestConfigItem> = emptyList(),
) {
    fun resource(name: String): ManifestResource? = resources.firstOrNull { it.name == name }

    fun declares(resourceName: String): Boolean = when (resourceName) {
        ResourceName.CATALOG -> catalogs.isNotEmpty()
        ResourceName.ADDON_CATALOG -> addonCatalogs.isNotEmpty()
        else -> resource(resourceName) != null
    }

    /**
     * Port of `Manifest::is_resource_supported` (stremio-core) with the lenient fallbacks of the iOS core: a resource declared as a
     * plain name inherits the manifest `types` and `idPrefixes`.
     */
    fun supports(path: ResourcePath): Boolean {
        when (path.resource) {
            ResourceName.CATALOG -> return catalogs.any { it.type == path.type && it.id == path.id && it.isExtraSupported(path.extra) }
            ResourceName.ADDON_CATALOG ->
                return addonCatalogs.any { it.type == path.type && it.id == path.id && it.isExtraSupported(path.extra) }
        }
        val resource = resource(path.resource) ?: return false
        val effectiveTypes: List<String>
        val effectivePrefixes: List<String>?
        val ownTypes = resource.types
        if (!ownTypes.isNullOrEmpty()) {
            effectiveTypes = ownTypes
            effectivePrefixes = resource.idPrefixes
        } else if (resource.types == null && resource.idPrefixes == null) {
            effectiveTypes = types
            effectivePrefixes = idPrefixes
        } else {
            effectiveTypes = types
            effectivePrefixes = resource.idPrefixes
        }
        if (path.type !in effectiveTypes) return false
        if (effectivePrefixes.isNullOrEmpty()) return true
        return effectivePrefixes.any { path.id.startsWith(it) }
    }

    /** Short list of what this addon provides, for the addons screen. */
    val capabilitySummary: List<String>
        get() {
            val parts = ArrayList<String>()
            if (catalogs.isNotEmpty()) parts.add(ResourceName.CATALOG)
            for (resource in resources) if (resource.name != ResourceName.CATALOG && resource.name !in parts) parts.add(resource.name)
            if (addonCatalogs.isNotEmpty() && ResourceName.ADDON_CATALOG !in parts) parts.add(ResourceName.ADDON_CATALOG)
            return parts
        }
}

/** Reasons a manifest is refused. Messages are shown to the user (Italian). */
sealed class ManifestValidationError(val message: String) {
    class MissingField(val field: String) : ManifestValidationError("Manifest non valido: campo obbligatorio «$field» mancante.")
    object NoResources : ManifestValidationError("Manifest non valido: l'addon non dichiara nessuna risorsa.")
    class InvalidCatalog(detail: String) : ManifestValidationError("Manifest non valido: catalogo non corretto ($detail).")
    class TooManyCatalogs(count: Int) : ManifestValidationError("Manifest rifiutato: $count cataloghi superano il limite consentito.")
}

object ManifestParser {
    const val MAX_CATALOGS = 500

    /** Decodes a manifest leniently; returns the manifest or the reason it was refused. */
    fun parse(element: JsonElement?): ManifestParseResult {
        val root = element as? JsonObject ?: return ManifestParseResult.Failure("Il manifest non è un oggetto JSON valido.")
        val id = root.flexString("id")?.takeIf { it.isNotBlank() } ?: return fail(ManifestValidationError.MissingField("id"))
        val name = root.flexString("name")?.takeIf { it.isNotBlank() } ?: return fail(ManifestValidationError.MissingField("name"))
        val version = root.flexString("version")?.takeIf { it.isNotBlank() } ?: return fail(ManifestValidationError.MissingField("version"))
        val resources = parseResources(root["resources"])
        val catalogs = root.lossyList("catalogs") { parseCatalog(it) }
        val addonCatalogs = root.lossyList("addonCatalogs") { parseCatalog(it) }
        val manifest = AddonManifest(
            id = id,
            version = version,
            name = name,
            description = root.flexString("description"),
            logo = root.flexString("logo"),
            background = root.flexString("background"),
            contactEmail = root.flexString("contactEmail"),
            types = root.stringList("types"),
            resources = resources,
            idPrefixes = if (root.has("idPrefixes")) root.stringList("idPrefixes") else null,
            catalogs = catalogs,
            addonCatalogs = addonCatalogs,
            behaviorHints = root.obj("behaviorHints")?.let {
                ManifestBehaviorHints(
                    adult = it.flexBool("adult") ?: false,
                    p2p = it.flexBool("p2p") ?: false,
                    configurable = it.flexBool("configurable") ?: false,
                    configurationRequired = it.flexBool("configurationRequired") ?: false,
                    epgProvider = it.flexBool("epgProvider") ?: false,
                )
            } ?: ManifestBehaviorHints(),
            config = root.lossyList("config") { item ->
                val key = item.flexString("key") ?: return@lossyList null
                ManifestConfigItem(
                    key = key,
                    type = item.flexString("type") ?: "text",
                    title = item.flexString("title"),
                    defaultValue = item.flexString("default"),
                    options = item.stringList("options"),
                    isRequired = item.flexBool("required") ?: false,
                )
            },
        )
        validate(manifest)?.let { return fail(it) }
        return ManifestParseResult.Success(manifest)
    }

    private fun fail(error: ManifestValidationError) = ManifestParseResult.Failure(error.message)

    private fun parseResources(element: JsonElement?): List<ManifestResource> {
        val array = element as? JsonArray ?: return emptyList()
        val result = ArrayList<ManifestResource>()
        for (item in array) {
            when (item) {
                is JsonPrimitive -> if (item.content.isNotEmpty()) result.add(ManifestResource(item.content))
                is JsonObject -> {
                    val name = item.flexString("name") ?: continue
                    result.add(
                        ManifestResource(
                            name = name,
                            types = if (item.has("types")) item.stringList("types") else null,
                            idPrefixes = if (item.has("idPrefixes")) item.stringList("idPrefixes") else null,
                        ),
                    )
                }
                else -> {}
            }
        }
        return result
    }

    private fun parseCatalog(item: JsonObject): ManifestCatalog? {
        val type = item.flexString("type") ?: return null
        val id = item.flexString("id") ?: return null
        val name = item.flexString("name")?.takeIf { it.isNotBlank() } ?: id
        var extras = item.lossyList("extra") { extra ->
            val extraName = extra.flexString("name") ?: return@lossyList null
            ExtraProperty(
                name = extraName,
                isRequired = extra.flexBool("isRequired") ?: false,
                options = extra.stringList("options"),
                optionsLimit = (extra.flexInt("optionsLimit") ?: 1).let { if (it < 0) 1 else it },
            )
        }
        if (extras.isEmpty()) {
            // Legacy "short" format: extraSupported: ["search","skip"], extraRequired: ["search"].
            val supported = item.stringList("extraSupported")
            val required = item.stringList("extraRequired").toSet()
            val names = ArrayList(supported)
            for (name in required) if (name !in names) names.add(name)
            extras = names.map { ExtraProperty(it, isRequired = it in required) }
        }
        return ManifestCatalog(type, id, name, extras)
    }

    fun validate(manifest: AddonManifest): ManifestValidationError? {
        if (manifest.resources.isEmpty() && manifest.catalogs.isEmpty()) return ManifestValidationError.NoResources
        if (manifest.catalogs.size > MAX_CATALOGS) return ManifestValidationError.TooManyCatalogs(manifest.catalogs.size)
        for (catalog in manifest.catalogs) {
            if (catalog.type.isEmpty() || catalog.id.isEmpty()) return ManifestValidationError.InvalidCatalog("type/id vuoti")
        }
        return null
    }
}

sealed class ManifestParseResult {
    data class Success(val manifest: AddonManifest) : ManifestParseResult()
    data class Failure(val message: String) : ManifestParseResult()
}
