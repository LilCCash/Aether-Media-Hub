package app.aether.tv.ui.screens.discover

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
    val restoreIndex = state.items.indexOfFirst { it.id == memory.key }

    // Paging: when the remote gets near the end of what is loaded, the next page is asked for.
    LaunchedEffect(gridState, state.items.size) {
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last ->
            if (state.items.isNotEmpty() && last >= state.items.size - 14) vm.loadMore()
        }
    }
    if (restoreIndex >= 0) {
        LaunchedEffect(restoreIndex) {
            gridState.scrollToItem(restoreIndex)
            kotlinx.coroutines.delay(60)
            runCatching { restore.requestFocus() }
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
                ChipRow(state.types, selected = state.type, label = { RequestPlanner.friendlyTypeName(it) }, onSelect = vm::selectType, firstRequester = firstChip, tagPrefix = "discover.type")
                if (state.catalogs.size > 1) ChipRow(state.catalogs.map { it.id }, selected = state.catalog?.id, label = { id -> state.catalogs.first { it.id == id }.let { "${it.title} · ${it.addonName}" } }, onSelect = { id -> state.catalogs.firstOrNull { it.id == id }?.let(vm::selectCatalog) }, tagPrefix = "discover.catalog")
                if (state.genres.isNotEmpty()) {
                    val required = state.catalog?.catalog?.extraProperty("genre")?.isRequired == true
                    ChipRow(
                        (if (required) state.genres else listOf("") + state.genres),
                        selected = state.genre ?: "",
                        label = { if (it.isEmpty()) "Tutti i generi" else it },
                        onSelect = { vm.selectGenre(it.ifEmpty { null }) },
                        tagPrefix = "discover.genre",
                    )
                }
                Box(Modifier.fillMaxSize()) {
                    when {
                        state.loading -> LoadingState("Carico il catalogo…", Modifier.align(Alignment.Center))
                        state.error != null && state.items.isEmpty() -> ErrorState(state.error ?: "", { vm.load(AddonClient.LoadMode.RELOAD) }, Modifier.align(Alignment.Center))
                        state.items.isEmpty() -> EmptyState("Nessun titolo", "Questo catalogo non ha restituito titoli per i filtri scelti.", Modifier.align(Alignment.Center))
                        else -> LazyVerticalGrid(
                            state = gridState,
                            columns = GridCells.Adaptive((140 * settings.appearance.posterSize.scale).dp),
                            contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 16.dp, bottom = 48.dp),
                            horizontalArrangement = Arrangement.spacedBy(AetherDimens.RowSpacing),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier.fillMaxSize(),
                        ) {
                            items(state.items, key = { it.id }) { meta ->
                                PosterCard(
                                    meta,
                                    onClick = { onOpenDetail(meta) },
                                    width = (140 * settings.appearance.posterSize.scale).dp,
                                    focusRequester = if (meta.id == memory.key) restore else null,
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
