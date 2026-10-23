package app.aether.tv.ui.screens.discover

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.aether.core.AetherEngine
import app.aether.core.addons.AddonClient
import app.aether.core.addons.CatalogRef
import app.aether.core.addons.RequestPlanner
import app.aether.core.model.ExtraValue
import app.aether.core.model.MetaItem
import app.aether.core.net.AddonError
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The "Scopri" screen: every catalog of the installed addons, by type, with the genre filters the catalog declares and endless paging. */
class DiscoverViewModel(private val engine: AetherEngine) : ViewModel() {
    data class UiState(
        val loadingAddons: Boolean = true,
        val hasAddons: Boolean = false,
        val types: List<String> = emptyList(),
        val type: String? = null,
        val catalogs: List<CatalogRef> = emptyList(),
        val catalog: CatalogRef? = null,
        val genres: List<String> = emptyList(),
        val genre: String? = null,
        val items: List<MetaItem> = emptyList(),
        val loading: Boolean = false,
        val loadingMore: Boolean = false,
        val endReached: Boolean = false,
        val error: String? = null,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> get() = _state
    private var job: Job? = null

    init {
        viewModelScope.launch { engine.registry.revision.collect { reloadAddons() } }
    }

    private suspend fun reloadAddons() {
        val settings = engine.settings.value.value
        val handles = engine.registry.handles().filter { !(settings.content.hideAdultCatalogs && it.addon.manifest.behaviorHints.adult) }
        val types = RequestPlanner.availableTypes(handles)
        val current = _state.value
        val type = current.type?.takeIf { it in types } ?: settings.content.discoverTypes.firstOrNull { it in types } ?: types.firstOrNull()
        _state.update { it.copy(loadingAddons = false, hasAddons = handles.isNotEmpty(), types = types, type = type) }
        applyType(type, handles = handles)
    }

    fun selectType(type: String) {
        if (type == _state.value.type) return
        viewModelScope.launch { applyType(type, engine.registry.handles()) }
    }

    private fun applyType(type: String?, handles: List<app.aether.core.addons.AddonHandle>) {
        val settings = engine.settings.value.value
        val usable = handles.filter { !(settings.content.hideAdultCatalogs && it.addon.manifest.behaviorHints.adult) }
        val catalogs = if (type == null) emptyList() else RequestPlanner.feedCatalogs(usable, type)
        val keep = _state.value.catalog?.takeIf { old -> catalogs.any { it.id == old.id } }
        val catalog = keep?.let { old -> catalogs.first { it.id == old.id } } ?: catalogs.firstOrNull()
        _state.update { it.copy(type = type, catalogs = catalogs, catalog = catalog, genres = genresOf(catalog), genre = if (keep != null) it.genre else defaultGenre(catalog)) }
        load()
    }

    fun selectCatalog(ref: CatalogRef) {
        if (ref.id == _state.value.catalog?.id) return
        _state.update { it.copy(catalog = ref, genres = genresOf(ref), genre = defaultGenre(ref)) }
        load()
    }

    fun selectGenre(genre: String?) {
        if (genre == _state.value.genre) return
        _state.update { it.copy(genre = genre) }
        load()
    }

    private fun genresOf(ref: CatalogRef?): List<String> = ref?.catalog?.genreOptions.orEmpty()

    /** A catalog that requires a genre starts on its first one; the others start unfiltered. */
    private fun defaultGenre(ref: CatalogRef?): String? {
        val property = ref?.catalog?.extraProperty("genre") ?: return null
        return if (property.isRequired) property.options.firstOrNull() else null
    }

    private fun extras(skip: Int): List<ExtraValue> {
        val s = _state.value
        val list = ArrayList<ExtraValue>()
        s.genre?.let { list.add(ExtraValue("genre", it)) }
        if (skip > 0) list.add(ExtraValue("skip", skip.toString()))
        return list
    }

    fun load(mode: AddonClient.LoadMode = AddonClient.LoadMode.NORMAL) {
        job?.cancel()
        val ref = _state.value.catalog
        if (ref == null) {
            _state.update { it.copy(items = emptyList(), loading = false, loadingMore = false, error = null, endReached = true) }
            return
        }
        _state.update { it.copy(items = emptyList(), loading = true, loadingMore = false, error = null, endReached = false) }
        job = viewModelScope.launch {
            try {
                val result = engine.addons.catalog(ref, extras(0), mode)
                val items = result.items.distinctBy { it.id }
                _state.update { it.copy(items = items, loading = false, endReached = items.isEmpty() || !ref.catalog.supportsSkip) }
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                _state.update { it.copy(loading = false, error = AddonError.from(error).message) }
            }
        }
    }

    /** The next page: `skip` is the number of titles already shown, as Stremio addons expect. */
    fun loadMore() {
        val s = _state.value
        val ref = s.catalog ?: return
        if (s.loading || s.loadingMore || s.endReached || s.items.isEmpty() || !ref.catalog.supportsSkip) return
        _state.update { it.copy(loadingMore = true) }
        val previous = job
        job = viewModelScope.launch {
            previous?.join()
            try {
                val result = engine.addons.catalog(ref, extras(s.items.size))
                val known = _state.value.items.map { it.id }.toHashSet()
                val fresh = result.items.filter { known.add(it.id) }
                _state.update { it.copy(items = it.items + fresh, loadingMore = false, endReached = fresh.isEmpty()) }
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                // A failed page is not an error screen: the titles already shown stay, and the next scroll tries again.
                _state.update { it.copy(loadingMore = false) }
            }
        }
    }
}
