package app.aether.tv.ui.screens.search

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import app.aether.core.AetherEngine
import app.aether.core.addons.RequestPlanner
import app.aether.core.library.SearchHistoryItem
import app.aether.core.model.MetaItem
import app.aether.core.search.MetaDeduper
import app.aether.core.search.SearchRow
import app.aether.core.search.SearchService
import app.aether.core.search.SearchSort
import app.aether.tv.aether
import app.aether.tv.ui.components.ContentRow
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.PosterCard
import app.aether.tv.ui.components.FilterPill
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.components.TvTextField
import app.aether.tv.ui.components.rememberFocusMemory
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class SearchViewModel(private val engine: AetherEngine) : ViewModel() {
    data class UiState(
        val query: String = "",
        val searched: String = "",
        val searching: Boolean = false,
        val rows: List<SearchRow> = emptyList(),
        val local: List<MetaItem> = emptyList(),
        val total: Int = 0,
        val completed: Int = 0,
        val searchableCatalogs: Int = -1,
        val type: String? = null,
        val history: List<SearchHistoryItem> = emptyList(),
        val decade: Int? = null,
        val genre: String? = null,
    ) {
        /** Applies the year and genre filters to a list of results. */
        fun keep(items: List<MetaItem>): List<MetaItem> = items.filter { m ->
            (decade == null || (m.year?.let { y -> if (decade == 0) y < 1990 else if (decade == 2020) y >= 2020 else y >= decade && y < decade + 10 } ?: false)) &&
                (genre == null || m.genres.any { it.equals(genre, ignoreCase = true) })
        }
    }

    private val _state = MutableStateFlow(UiState(history = engine.library.searchHistory()))
    val state: StateFlow<UiState> get() = _state
    private var job: Job? = null

    init {
        viewModelScope.launch { _state.update { it.copy(searchableCatalogs = engine.search.searchableCatalogs().size) } }
    }

    /** Editing the field is local-only; addon requests start only after an explicit Search/Enter action. */
    fun onQuery(text: String) {
        _state.update { it.copy(query = text) }
    }

    fun submit() {
        job?.cancel()
        val query = SearchService.normalisedQuery(_state.value.query)
        if (query.isEmpty()) {
            _state.update { it.copy(searched = "", rows = emptyList(), local = emptyList(), searching = false, completed = 0, total = 0) }
            return
        }
        job = viewModelScope.launch { run(query, remember = true) }
    }

    fun pick(item: SearchHistoryItem) {
        _state.update { it.copy(query = item.query) }
        submit()
    }

    fun setDecade(decade: Int?) = _state.update { it.copy(decade = decade) }
    fun setGenre(genre: String?) = _state.update { it.copy(genre = genre) }

    fun setType(type: String?) {
        _state.update { it.copy(type = type) }
        if (_state.value.searched.isNotEmpty()) submit()
    }

    fun removeHistory(item: SearchHistoryItem) {
        engine.library.removeSearch(item.query)
        _state.update { it.copy(history = engine.library.searchHistory()) }
    }

    fun clearHistory() {
        engine.library.clearSearchHistory()
        _state.update { it.copy(history = emptyList()) }
    }

    private suspend fun run(text: String, remember: Boolean) {
        val query = SearchService.normalisedQuery(text)
        if (query.isEmpty()) return
        val settings = engine.settings.value.value
        if (remember && settings.content.saveSearchHistory && settings.privacy.recordHistory) engine.library.addSearch(query)
        val local = if (settings.content.searchLocal) engine.library.searchLocal(query) else emptyList()
        _state.update { it.copy(searched = query, searching = true, rows = emptyList(), local = local, completed = 0, total = 0, history = engine.library.searchHistory()) }
        try {
            engine.search.search(query, _state.value.type).collect { update ->
                _state.update { s -> s.copy(rows = (s.rows + update.row), completed = update.completed, total = update.total) }
            }
        } finally {
            _state.update { it.copy(searching = false) }
        }
    }
}

@Composable
fun SearchScreen(onOpenDetail: (MetaItem) -> Unit, onOpenAddons: () -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val vm: SearchViewModel = viewModel { SearchViewModel(engine) }
    val state by vm.state.collectAsStateWithLifecycle()
    val settings by engine.settings.value.collectAsStateWithLifecycle()
    val memory = rememberFocusMemory()
    val field = remember { FocusRequester() }
    val types = remember(state.searchableCatalogs) { listOf<String?>(null, "movie", "series") }

    LaunchedEffect(Unit) { if (memory.key.isEmpty()) runCatching { field.requestFocus() } }

    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Cerca", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        TvTextField(
            value = state.query,
            onValueChange = vm::onQuery,
            label = "Titolo, attore, argomento",
            placeholder = "Premi OK per scrivere con la tastiera o la voce",
            imeAction = ImeAction.Search,
            onImeAction = vm::submit,
            focusRequester = field,
            modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal).width(720.dp),
            testTag = "search.field",
        )
        Row0 {
            FilterPill("Tipo", types.map { (it ?: "") to (if (it == null) "Tutto" else RequestPlanner.friendlyTypeName(it)) }, state.type.orEmpty(), { vm.setType(it.ifEmpty { null }) }, testTag = "search.type")
            if (state.searched.isNotEmpty()) {
                val genres = remember(state.rows) { state.rows.flatMap { it.items }.flatMap { it.genres }.groupingBy { it }.eachCount().entries.sortedByDescending { it.value }.take(30).map { it.key } }
                FilterPill("Anno", listOf("" to "Tutti", "2020" to "2020+", "2010" to "2010–2019", "2000" to "2000–2009", "1990" to "1990–1999", "0" to "Prima del 1990"), state.decade?.toString().orEmpty(), { vm.setDecade(it.toIntOrNull()) }, testTag = "search.year")
                if (genres.isNotEmpty()) FilterPill("Genere", listOf("" to "Tutti") + genres.map { it to it }, state.genre.orEmpty(), { vm.setGenre(it.ifEmpty { null }) }, testTag = "search.genre")
            }
        }
        when {
            state.searchableCatalogs == 0 -> EmptyState(
                "Nessun addon può cercare",
                "La ricerca usa i cataloghi degli addon: nessuno di quelli installati la supporta. Aggiungi un addon di cataloghi come Cinemeta.",
                Modifier.fillMaxWidth().padding(top = 16.dp),
            ) { app.aether.tv.ui.components.TvButton("Vai agli addon", onOpenAddons, primary = true) }
            state.searched.isEmpty() -> HistoryBlock(state, vm)
            else -> Results(state, onOpenDetail, memory, settings.content.searchSort, vm, settings.appearance.posterSize.scale)
        }
    }
}

@Composable
private fun Row0(content: @Composable () -> Unit) {
    androidx.compose.foundation.layout.Row(Modifier.horizontalScroll(androidx.compose.foundation.rememberScrollState()).padding(horizontal = AetherDimens.ScreenHorizontal), horizontalArrangement = Arrangement.spacedBy(10.dp)) { content() }
}

@Composable
private fun HistoryBlock(state: SearchViewModel.UiState, vm: SearchViewModel) {
    if (state.history.isEmpty()) {
        EmptyState("Cosa vuoi guardare?", "Scrivi un titolo e premi Invio per avviare la ricerca nei cataloghi dei tuoi addon.", Modifier.fillMaxWidth().padding(top = 24.dp), icon = Icons.Filled.Search)
        return
    }
    Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Ricerche recenti", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
            items(state.history.size, key = { state.history[it].id }) { i -> TvChip(state.history[i].query, false, { vm.pick(state.history[i]) }) }
        }
        TvChip("Cancella la cronologia", false, onClick = vm::clearHistory)
    }
}

@Composable
private fun Results(state: SearchViewModel.UiState, onOpenDetail: (MetaItem) -> Unit, memory: app.aether.tv.ui.components.FocusMemory, sort: SearchSort, vm: SearchViewModel, scale: Float) {
    val rowsWithItems = state.rows.map { it.copy(items = state.keep(it.items)) }.filter { it.items.isNotEmpty() }
    val failed = state.rows.filter { it.error != null }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (state.searching) item(key = "progress") {
            Text("Cerco in ${state.total.takeIf { it > 0 } ?: "…"} cataloghi (${state.completed} risposte)…", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        }
        if (state.keep(state.local).isNotEmpty()) item(key = "local") {
            ContentRow("Nella tua libreria", state.keep(state.local), { it.id }, rowId = "local", memory = memory) { meta, requester, onFocused ->
                PosterCard(meta, { onOpenDetail(meta) }, focusRequester = requester, onFocused = onFocused)
            }
        }
        // One merged row of everything, without duplicates, then the rows of each catalog.
        val merged = MetaDeduper.interleave(rowsWithItems.map { sort.apply(it.items) })
        if (merged.isNotEmpty() && rowsWithItems.size > 1) item(key = "all") {
            ContentRow("Tutti i risultati", merged, { it.id }, rowId = "all", memory = memory) { meta, requester, onFocused ->
                PosterCard(meta, { onOpenDetail(meta) }, width = (150 * scale).dp, focusRequester = requester, onFocused = onFocused)
            }
        }
        for (row in rowsWithItems) item(key = row.id) {
            ContentRow("${row.ref.title} · ${row.ref.addonName}", sort.apply(row.items), { it.id }, rowId = row.id, memory = memory) { meta, requester, onFocused ->
                PosterCard(meta, { onOpenDetail(meta) }, width = (150 * scale).dp, focusRequester = requester, onFocused = onFocused)
            }
        }
        if (!state.searching && rowsWithItems.isEmpty() && state.local.isEmpty()) item(key = "empty") {
            EmptyState("Nessun risultato", "Nessun catalogo ha trovato «${state.searched}». Controlla il titolo o prova con meno parole.", Modifier.fillMaxWidth().padding(top = 16.dp))
        }
        if (failed.isNotEmpty() && !state.searching) item(key = "errors") {
            Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Alcuni cataloghi non hanno risposto", style = MaterialTheme.typography.titleMedium, color = AetherColors.Warning)
                for (row in failed.take(4)) Text("${row.ref.addonName}: ${row.error?.message}", style = MaterialTheme.typography.bodySmall, color = AetherColors.OnSurfaceMuted, maxLines = 1)
            }
        }
        if (state.searching && rowsWithItems.isEmpty()) item(key = "loading") { LoadingState("Cerco…") }
    }
}
