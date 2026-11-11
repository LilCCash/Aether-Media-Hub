package app.aether.tv.ui.screens.recommend

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import app.aether.core.AetherEngine
import app.aether.core.addons.CatalogRef
import app.aether.core.addons.RequestPlanner
import app.aether.core.model.ExtraValue
import app.aether.core.model.MetaItem
import app.aether.core.search.Recommender
import app.aether.tv.aether
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.PosterCard
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent
import kotlin.coroutines.cancellation.CancellationException
import kotlin.random.Random
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** "Consigliami": pick a type and a genre, tick the titles you like among a random set, get five suggestions. */
class RecommendViewModel(private val engine: AetherEngine) : ViewModel() {
    enum class Step { CHOOSE, LOADING, PICK, THINKING, RESULT }

    data class UiState(
        val step: Step = Step.CHOOSE,
        val loadingAddons: Boolean = true,
        val types: List<String> = emptyList(),
        val type: String? = null,
        val genres: List<String> = emptyList(),
        val genre: String? = null,
        val candidates: List<MetaItem> = emptyList(),
        val picked: Set<String> = emptySet(),
        val results: List<MetaItem> = emptyList(),
        val error: String? = null,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> get() = _state
    private var shown: Set<String> = emptySet()

    init { viewModelScope.launch { _state.update { it.copy(loadingAddons = true) }; applyType(null) } }

    private suspend fun handles() = engine.registry.handles().filter { it.addon.isEnabled }

    private suspend fun applyType(requested: String?) {
        val handles = handles()
        val types = RequestPlanner.availableTypes(handles).filter { it == "movie" || it == "series" }
        val type = requested?.takeIf { it in types } ?: types.firstOrNull()
        val genres = type?.let { RequestPlanner.genreOptions(handles, it) }.orEmpty()
        _state.update { it.copy(loadingAddons = false, types = types, type = type, genres = genres, genre = it.genre?.takeIf { g -> g in genres } ?: genres.firstOrNull()) }
    }

    fun setType(type: String) { viewModelScope.launch { applyType(type) } }
    fun setGenre(genre: String) = _state.update { it.copy(genre = genre) }
    fun toggle(meta: MetaItem) = _state.update { it.copy(picked = if (meta.id in it.picked) it.picked - meta.id else it.picked + meta.id) }
    fun restart() = _state.update { it.copy(step = Step.CHOOSE, picked = emptySet(), results = emptyList(), candidates = emptyList(), error = null) }

    private suspend fun page(ref: CatalogRef, genre: String, skip: Int): List<MetaItem> = try {
        val extras = buildList { add(ExtraValue("genre", genre)); if (skip > 0) add(ExtraValue("skip", skip.toString())) }
        engine.addons.catalog(ref, extras).items
    } catch (error: Throwable) {
        if (error is CancellationException) throw error
        emptyList()
    }

    private suspend fun genreCatalog(type: String, genre: String): CatalogRef? =
        RequestPlanner.feedCatalogs(handles(), type).firstOrNull { genre in it.catalog.genreOptions }

    /** Twenty random titles of the genre: two random pages of the catalog, mixed. */
    fun showCandidates(reshuffle: Boolean = false) {
        val s = _state.value
        val type = s.type ?: return
        val genre = s.genre ?: return
        _state.update { it.copy(step = Step.LOADING, error = null, picked = if (reshuffle) it.picked else emptySet()) }
        viewModelScope.launch {
            val ref = genreCatalog(type, genre)
            if (ref == null) { _state.update { it.copy(step = Step.CHOOSE, error = "Nessun catalogo installato offre questo genere.") }; return@launch }
            val first = page(ref, genre, 0)
            val size = first.size.coerceAtLeast(1)
            val extra = if (first.isEmpty()) emptyList() else coroutineScope {
                listOf(1 + Random.nextInt(4), 1 + Random.nextInt(4)).distinct().map { async { page(ref, genre, it * size) } }.flatMap { it.await() }
            }
            val pool = (first + extra).filter { !it.poster.isNullOrBlank() }.distinctBy { it.id }.filter { it.id !in shown || !reshuffle }.shuffled()
            val chosen = pool.take(20)
            if (chosen.isEmpty()) { _state.update { it.copy(step = Step.CHOOSE, error = "Il catalogo non ha risposto: controlla gli addon e la connessione.") }; return@launch }
            shown = shown + chosen.map { it.id }
            _state.update { it.copy(step = Step.PICK, candidates = chosen) }
        }
    }

    fun recommend() {
        val s = _state.value
        val type = s.type ?: return
        val selected = s.candidates.filter { it.id in s.picked }
        if (selected.isEmpty()) return
        _state.update { it.copy(step = Step.THINKING) }
        viewModelScope.launch {
            val genres = selected.flatMap { it.genres }.groupingBy { it }.eachCount().entries.sortedByDescending { it.value }.map { it.key }.take(3)
            val pools: List<Deferred<List<MetaItem>>> = coroutineScope {
                genres.flatMap { g ->
                    val ref = genreCatalog(type, g) ?: return@flatMap emptyList<Deferred<List<MetaItem>>>()
                    listOf(0, 1).map { n -> async { page(ref, g, n * 50) } }
                }
            }
            val pool = (pools.flatMap { it.await() } + s.candidates).distinctBy { it.id }
            // TMDB's "similar titles" of what was picked, when the viewer has a key: used only to raise matching candidates.
            val boosted = if (engine.metadata.hasTmdb) coroutineScope {
                selected.take(5).map { m -> async { engine.metadata.rich(m)?.similar.orEmpty().map { "${it.title.trim().lowercase()}|${it.year ?: ""}" } } }.flatMap { it.await() }.toSet()
            } else emptySet()
            val results = Recommender.recommend(selected, pool, boosted, 5)
            _state.update { it.copy(step = Step.RESULT, results = results) }
        }
    }
}

private val genreNames = mapOf(
    "Action" to "Azione", "Adventure" to "Avventura", "Animation" to "Animazione", "Comedy" to "Commedia", "Crime" to "Crimine", "Documentary" to "Documentario",
    "Drama" to "Dramma", "Family" to "Famiglia", "Fantasy" to "Fantasy", "History" to "Storia", "Horror" to "Horror", "Music" to "Musica", "Mystery" to "Mistero",
    "Romance" to "Romantico", "Sci-Fi" to "Fantascienza", "Science Fiction" to "Fantascienza", "Thriller" to "Thriller", "War" to "Guerra", "Western" to "Western",
    "Biography" to "Biografico", "Sport" to "Sport", "Reality-TV" to "Reality", "Talk-Show" to "Talk show", "News" to "Notizie", "Game-Show" to "Quiz",
)

private fun genreLabel(g: String) = genreNames[g] ?: g

@Composable
fun RecommendScreen(onOpenDetail: (MetaItem) -> Unit, onOpenAddons: () -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val vm: RecommendViewModel = viewModel { RecommendViewModel(engine) }
    val state by vm.state.collectAsStateWithLifecycle()
    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Filled.AutoAwesome, null, tint = LocalAccent.current, modifier = Modifier.size(34.dp))
            Text("Consigliami", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground)
        }
        when (state.step) {
            RecommendViewModel.Step.CHOOSE -> Choose(state, vm, onOpenAddons)
            RecommendViewModel.Step.LOADING -> LoadingState("Cerco titoli di ${state.genre?.let(::genreLabel).orEmpty()}…", Modifier.fillMaxSize())
            RecommendViewModel.Step.PICK -> Pick(state, vm)
            RecommendViewModel.Step.THINKING -> LoadingState("Cerco qualcosa che faccia al caso tuo…", Modifier.fillMaxSize())
            RecommendViewModel.Step.RESULT -> Result(state, vm, onOpenDetail)
        }
    }
}

@Composable
private fun Choose(state: RecommendViewModel.UiState, vm: RecommendViewModel, onOpenAddons: () -> Unit) {
    val first = androidx.compose.runtime.remember { FocusRequester() }
    when {
        state.loadingAddons -> LoadingState("Un attimo…", Modifier.fillMaxSize())
        state.types.isEmpty() -> EmptyState("Servono dei cataloghi", "Per consigliarti qualcosa servono addon con cataloghi di film o serie, come Cinemeta.", Modifier.fillMaxSize().padding(top = 16.dp)) {
            TvButton("Vai agli addon", onOpenAddons, primary = true)
        }
        else -> Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("Che cosa hai voglia di guardare?", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                for (type in state.types) TvChip(if (type == "movie") "Film" else "Serie TV", state.type == type, { vm.setType(type) }, focusRequester = if (type == state.types.first()) first else null, testTag = "recommend.type.$type")
            }
            Text("Di che genere?", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(top = 6.dp))
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                for (genre in state.genres) TvChip(genreLabel(genre), state.genre == genre, { vm.setGenre(genre) }, testTag = "recommend.genre.$genre")
            }
            state.error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.Warning) }
            TvButton("Mostrami dei titoli", { vm.showCandidates() }, icon = Icons.Filled.AutoAwesome, primary = true, enabled = state.genre != null, testTag = "recommend.show", modifier = Modifier.padding(top = 8.dp))
        }
    }
    RequestFocusOnce(first, state.types.size)
}

@Composable
private fun Pick(state: RecommendViewModel.UiState, vm: RecommendViewModel) {
    val first = androidx.compose.runtime.remember { FocusRequester() }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Scegli quelli che ti piacciono (OK per selezionare)", style = MaterialTheme.typography.titleMedium, color = AetherColors.OnSurfaceMuted, modifier = Modifier.weight(1f))
            TvButton("Altri titoli", { vm.showCandidates(reshuffle = true) }, icon = Icons.Filled.Refresh, testTag = "recommend.shuffle")
            TvButton(if (state.picked.isEmpty()) "Consigliami" else "Consigliami (${state.picked.size})", { vm.recommend() }, icon = Icons.Filled.AutoAwesome, primary = true, enabled = state.picked.isNotEmpty(), testTag = "recommend.confirm")
        }
        LazyVerticalGrid(
            GridCells.Adaptive(150.dp), Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 8.dp, bottom = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            items(state.candidates.size, key = { state.candidates[it].id }) { i ->
                val meta = state.candidates[i]
                val selected = meta.id in state.picked
                Box {
                    PosterCard(meta, { vm.toggle(meta) }, width = 150.dp, focusRequester = if (i == 0) first else null, testTag = "recommend.pick.$i")
                    if (selected) Box(Modifier.align(Alignment.TopEnd).padding(8.dp).size(30.dp).clip(CircleShape).background(LocalAccent.current), contentAlignment = Alignment.Center) {
                        Icon(Icons.Filled.Check, "Selezionato", tint = androidx.compose.ui.graphics.Color.White, modifier = Modifier.size(20.dp))
                    }
                }
            }
        }
    }
    RequestFocusOnce(first, state.candidates.size)
}

@Composable
private fun Result(state: RecommendViewModel.UiState, vm: RecommendViewModel, onOpenDetail: (MetaItem) -> Unit) {
    val first = androidx.compose.runtime.remember { FocusRequester() }
    if (state.results.isEmpty()) {
        EmptyState("Nessun consiglio", "Non ho trovato altri titoli adatti: prova con un altro genere o scegli più titoli.", Modifier.fillMaxSize().padding(top = 16.dp)) {
            TvButton("Ricomincia", vm::restart, primary = true, focusRequester = first)
        }
    } else Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Per te, in base ai ${state.picked.size} titoli che hai scelto:", style = MaterialTheme.typography.titleMedium, color = AetherColors.OnSurfaceMuted, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        LazyRow(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(AetherDimens.RowSpacing)) {
            items(state.results.size) { i ->
                val meta = state.results[i]
                Column(Modifier.width(180.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    PosterCard(meta, { onOpenDetail(meta) }, width = 180.dp, focusRequester = if (i == 0) first else null, testTag = "recommend.result.$i")
                    Text(meta.genres.take(3).joinToString(" · ") { genreLabel(it) }, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 1)
                }
            }
        }
        Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TvButton("Ricomincia", vm::restart, icon = Icons.Filled.Refresh, testTag = "recommend.restart")
        }
    }
    RequestFocusOnce(first, state.results.size)
}
