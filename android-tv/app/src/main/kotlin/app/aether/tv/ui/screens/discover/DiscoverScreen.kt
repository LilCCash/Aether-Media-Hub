package app.aether.tv.ui.screens.discover

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Extension
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.aether.core.addons.AddonClient
import app.aether.core.addons.RequestPlanner
import app.aether.core.model.MetaItem
import app.aether.tv.aether
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.FilterPill
import app.aether.tv.ui.components.ErrorState
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.PosterCard
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.components.rememberFocusMemory
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens

@Composable
fun DiscoverScreen(onOpenDetail: (MetaItem) -> Unit, onOpenAddons: () -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val vm: DiscoverViewModel = viewModel { DiscoverViewModel(engine) }
    val state by vm.state.collectAsStateWithLifecycle()
    val settings by engine.settings.value.collectAsStateWithLifecycle()
    val gridState = rememberLazyGridState()
    val memory = rememberFocusMemory()
    val firstChip = remember { FocusRequester() }
    val restore = remember { FocusRequester() }
    var decade by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf("") }
    val shown = remember(state.items, decade) { if (decade.isEmpty()) state.items else state.items.filter { decadeMatches(it.year, decade) } }
    // Restore only the item that was focused when Discover was entered. The live memory changes
    // on every D-pad move, so reading memory.key directly here causes scrollToItem() to fight navigation.
    val restoreTarget = remember { memory.key }\n    var hasRestoredFocus by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }\n    val restoreIndex = shown.indexOfFirst { it.id == restoreTarget }

    // Paging: when the remote gets near the end of what is loaded, the next page is asked for.
    LaunchedEffect(gridState, state.items.size, shown.size) {
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last ->
            if (state.items.isNotEmpty() && (last >= shown.size - 14)) vm.loadMore()
        }
    }
    if (restoreIndex >= 0 && !hasRestoredFocus) {
        LaunchedEffect(restoreTarget, restoreIndex) {
            gridState.scrollToItem(restoreIndex)
            kotlinx.coroutines.delay(60)
            runCatching { restore.requestFocus() }
            hasRestoredFocus = true
        }
    }

    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical)) {
        Text("Scopri", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        when {
            state.loadingAddons -> Unit
            !state.hasAddons -> EmptyState("Nessun addon installato", "Aggiungi un addon di cataloghi per sfogliare film e serie.", Modifier.fillMaxSize().padding(top = 40.dp)) {
                TvButton("Vai agli addon", onOpenAddons, icon = Icons.Filled.Extension, primary = true)
            }
            state.types.isEmpty() -> EmptyState("Nessun catalogo disponibile", "Gli addon installati non offrono cataloghi sfogliabili (o li hai nascosti dalla pagina Addon).", Modifier.fillMaxSize().padding(top = 40.dp)) {
                TvButton("Vai agli addon", onOpenAddons, icon = Icons.Filled.Extension, primary = true)
            }
            else -> {
                if (memory.key.isEmpty()) RequestFocusOnce(firstChip, state.type)
                Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    FilterPill("Tipo", state.types.map { it to RequestPlanner.friendlyTypeName(it) }, state.type.orEmpty(), vm::selectType, focusRequester = firstChip, testTag = "discover.type")
                    if (state.catalogs.size > 1) FilterPill("Catalogo", state.catalogs.map { it.id to "${it.title} · ${it.addonName}" }, state.catalog?.id.orEmpty(), { id -> state.catalogs.firstOrNull { it.id == id }?.let(vm::selectCatalog) }, testTag = "discover.catalog")
                    if (state.genres.isNotEmpty()) {
                        val required = state.catalog?.catalog?.extraProperty("genre")?.isRequired == true
                        FilterPill("Genere", (if (required) emptyList() else listOf("" to "Tutti")) + state.genres.map { it to it }, state.genre.orEmpty(), { vm.selectGenre(it.ifEmpty { null }) }, testTag = "discover.genre")
                    }
                    FilterPill("Anno", decadeOptions, decade, { decade = it }, testTag = "discover.year")
                }
                Box(Modifier.fillMaxSize()) {
                    when {
                        state.loading -> LoadingState("Carico il catalogo…", Modifier.align(Alignment.Center))
                        state.error != null && state.items.isEmpty() -> ErrorState(state.error ?: "", { vm.load(AddonClient.LoadMode.RELOAD) }, Modifier.align(Alignment.Center))
                        shown.isEmpty() -> EmptyState("Nessun titolo", "Questo catalogo non ha restituito titoli per i filtri scelti.", Modifier.align(Alignment.Center))
                        else -> LazyVerticalGrid(
                            state = gridState,
                            columns = GridCells.Adaptive((140 * settings.appearance.posterSize.scale).dp),
                            contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 20.dp, bottom = 72.dp),
                            horizontalArrangement = Arrangement.spacedBy(AetherDimens.RowSpacing),
                            verticalArrangement = Arrangement.spacedBy(14.dp),
                            modifier = Modifier.fillMaxSize(),
                        ) {
                            items(shown, key = { it.id }) { meta ->
                                PosterCard(
                                    meta,
                                    onClick = { onOpenDetail(meta) },
                                    width = (140 * settings.appearance.posterSize.scale).dp,
                                    focusRequester = if (meta.id == restoreTarget) restore else null,
                                    onFocused = { memory.remember(meta.id) },
                                )
                            }
                            if (state.loadingMore) item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) { LoadingState("Altri titoli…") }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ChipRow(
    options: List<String>,
    selected: String?,
    label: (String) -> String,
    onSelect: (String) -> Unit,
    firstRequester: FocusRequester? = null,
    tagPrefix: String,
) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        items(options.size, key = { options[it] }) { index ->
            val option = options[index]
            TvChip(
                label(option), selected = option == selected, onClick = { onSelect(option) },
                focusRequester = if (index == 0) firstRequester else null,
                testTag = "$tagPrefix.$index",
            )
        }
    }
}

private val decadeOptions = listOf("" to "Tutti", "2020" to "2020+", "2010" to "2010–2019", "2000" to "2000–2009", "1990" to "1990–1999", "1980" to "1980–1989", "0" to "Prima del 1980")

private fun decadeMatches(year: Int?, decade: String): Boolean {
    if (year == null) return false
    val d = decade.toIntOrNull() ?: return true
    return when (d) { 0 -> year < 1980; 2020 -> year >= 2020; else -> year in d..(d + 9) }
}
