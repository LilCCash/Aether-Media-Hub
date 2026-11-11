package app.aether.core.addons

import app.aether.core.model.ContentType
import app.aether.core.model.ExtraValue
import app.aether.core.model.ManifestCatalog
import app.aether.core.model.ResourceName
import app.aether.core.model.ResourcePath

/** A catalog offered by one installed addon. */
data class CatalogRef(val addonId: String, val addonName: String, val catalog: ManifestCatalog) {
    val id: String get() = "$addonId/${catalog.key}"
    val type: String get() = catalog.type
    val title: String get() = catalog.name
}

/** Decides *which* addons and catalogs may be asked for what, from manifests alone (no network). */
object RequestPlanner {
    private val typeOrder = listOf(ContentType.MOVIE, ContentType.SERIES, ContentType.ANIME, ContentType.TV, ContentType.CHANNEL, ContentType.OTHER)

    fun typeRank(type: String): Int = typeOrder.indexOf(type).let { if (it < 0) typeOrder.size else it }

    /** Catalogs listable as a plain feed (no mandatory extra such as `search`), in addon order. */
    fun feedCatalogs(handles: List<AddonHandle>, type: String? = null, includeHidden: Boolean = false): List<CatalogRef> {
        val result = ArrayList<CatalogRef>()
        for (handle in handles) {
            val addon = handle.addon
            for (catalog in addon.manifest.catalogs) {
                if (type != null && catalog.type != type) continue
                if (!catalog.isExtraSupported(emptyList())) continue
                if (!includeHidden && !addon.isCatalogVisible(catalog)) continue
                result.add(CatalogRef(addon.id, addon.displayName, catalog))
            }
        }
        return result
    }

    /** Catalogs that declare the `search` extra and can answer it (any other required extra would make them unusable). */
    fun searchCatalogs(handles: List<AddonHandle>, type: String? = null): List<CatalogRef> {
        val probe = listOf(ExtraValue("search", "x"))
        val result = ArrayList<CatalogRef>()
        for (handle in handles) for (catalog in handle.addon.manifest.catalogs) {
            if (type != null && catalog.type != type) continue
            if (catalog.isExtraSupported(probe)) result.add(CatalogRef(handle.addon.id, handle.addon.displayName, catalog))
        }
        return result
    }

    /** Addons whose manifest allows the given resource request, in user order. */
    fun addons(path: ResourcePath, handles: List<AddonHandle>): List<AddonHandle> = handles.filter { it.addon.manifest.supports(path) }

    /** Content types for which at least one *feed* catalog exists. */
    fun availableTypes(handles: List<AddonHandle>): List<String> =
        feedCatalogs(handles).map { it.type }.distinct().sortedWith(compareBy({ typeRank(it) }, { it }))

    fun genreOptions(handles: List<AddonHandle>, type: String): List<String> =
        feedCatalogs(handles, type).flatMap { it.catalog.genreOptions }.distinct()

    /** True when at least one enabled addon can supply streams for the item (the UI hides Play otherwise). */
    fun canProvideStreams(type: String, id: String, handles: List<AddonHandle>): Boolean =
        addons(ResourcePath(ResourceName.STREAM, type, id), handles).isNotEmpty()

    fun friendlyTypeName(type: String): String = when (type) {
        ContentType.MOVIE -> "Film"
        ContentType.SERIES -> "Serie TV"
        ContentType.ANIME -> "Anime"
        ContentType.CHANNEL -> "Canali"
        ContentType.TV -> "TV in diretta"
        ContentType.OTHER -> "Altro"
        else -> type.replaceFirstChar { it.uppercase() }
    }
}
