package app.aether.tv.ui.screens.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.aether.core.AetherEngine
import app.aether.core.addons.AddonClient
import app.aether.core.addons.CatalogRef
import app.aether.core.addons.RequestPlanner
import app.aether.core.library.PlaybackProgress
import app.aether.core.model.ContentType
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.core.net.AddonError
import app.aether.core.playback.NextEpisodeResolver
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class HomeViewModel(private val engine: AetherEngine) : ViewModel() {
    enum class RowStatus { LOADING, LOADED, FAILED }

    data class CatalogRow(val ref: CatalogRef, val status: RowStatus, val items: List<MetaItem> = emptyList(), val error: String? = null)
    data class NextUp(val meta: MetaItem, val video: Video)

    data class UiState(
        val loadingAddons: Boolean = true,
        val addonCount: Int = 0,
        val rows: List<CatalogRow> = emptyList(),
        val hero: List<MetaItem> = emptyList(),
        val continueWatching: List<PlaybackProgress> = emptyList(),
        val nextUp: List<NextUp> = emptyList(),
        val hiddenSections: List<String> = emptyList(),
        val showContinue: Boolean = true,
        val showNextUp: Boolean = true,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> get() = _state
    private var loadJob: Job? = null
    private var nextUpJob: Job? = null

    init {
        viewModelScope.launch { engine.registry.revision.collect { reload() } }
        viewModelScope.launch { engine.library.revision.collect { refreshLibrary() } }
        viewModelScope.launch { engine.settings.value.collect { settings ->
            _state.update { it.copy(hiddenSections = settings.appearance.hiddenHomeSections, showContinue = settings.appearance.showContinueWatching, showNextUp = settings.appearance.showNextUp) }
        } }
    }

    fun reload(mode: AddonClient.LoadMode = AddonClient.LoadMode.NORMAL) {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val settings = engine.settings.value.value
            val handles = engine.registry.handles().filter { !(settings.content.hideAdultCatalogs && it.addon.manifest.behaviorHints.adult) }
            val refs = RequestPlanner.feedCatalogs(handles)
            _state.update { it.copy(loadingAddons = false, addonCount = handles.size, rows = refs.map { ref -> CatalogRow(ref, RowStatus.LOADING) }, hero = emptyList()) }
            refreshLibrary()
            coroutineScope {
                for (ref in refs) {
                    launch {
                        val row = try {
                            val result = engine.addons.catalog(ref, mode = mode)
                            CatalogRow(ref, RowStatus.LOADED, result.items.distinctBy { it.id })
                        } catch (error: Throwable) {
                            if (error is CancellationException) throw error
                            CatalogRow(ref, RowStatus.FAILED, error = AddonError.from(error).message)
                        }
                        _state.update { current ->
                            val rows = current.rows.map { if (it.ref.id == ref.id) row else it }
                            current.copy(rows = rows, hero = pickHero(rows))
                        }
                    }
                }
            }
        }
    }

    fun retry(ref: CatalogRef) {
        viewModelScope.launch {
            _state.update { s -> s.copy(rows = s.rows.map { if (it.ref.id == ref.id) CatalogRow(ref, RowStatus.LOADING) else it }) }
            val row = try {
                CatalogRow(ref, RowStatus.LOADED, engine.addons.catalog(ref, mode = AddonClient.LoadMode.RELOAD).items.distinctBy { it.id })
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                CatalogRow(ref, RowStatus.FAILED, error = AddonError.from(error).message)
            }
            _state.update { s ->
                val rows = s.rows.map { if (it.ref.id == ref.id) row else it }
                s.copy(rows = rows, hero = pickHero(rows))
            }
        }
    }

    /** Up to six titles with a wide picture, taken from the first catalogs of films and series. */
    private fun pickHero(rows: List<CatalogRow>): List<MetaItem> {
        val seen = HashSet<String>()
        val picked = ArrayList<MetaItem>()
        for (row in rows) {
            if (row.status != RowStatus.LOADED) continue
            if (row.ref.type != ContentType.MOVIE && row.ref.type != ContentType.SERIES) continue
            for (item in row.items) {
                if (item.background.isNullOrBlank() || !seen.add(item.id)) continue
                picked.add(item)
                if (picked.size >= 6) return picked
                if (picked.count { it.type == row.ref.type } >= 3) break
            }
        }
        return picked
    }

    private fun refreshLibrary() {
        _state.update { it.copy(continueWatching = engine.library.continueWatching()) }
        nextUpJob?.cancel()
        nextUpJob = viewModelScope.launch {
            val seeds = engine.library.nextUpSeeds(8)
            val resolved = coroutineScope {
                seeds.map { seed ->
                    async {
                        try {
                            val meta = engine.addons.meta(seed.type, seed.metaId, seed.asMeta).meta
                            val watched = engine.library.watchedVideoIds(seed.metaId)
                            NextEpisodeResolver.nextUnwatched(seed.videoId, meta, watched)?.let { NextUp(meta, it) }
                        } catch (error: Throwable) {
                            if (error is CancellationException) throw error
                            null
                        }
                    }
                }.mapNotNull { it.await() }
            }
            _state.update { it.copy(nextUp = resolved) }
        }
    }
}
