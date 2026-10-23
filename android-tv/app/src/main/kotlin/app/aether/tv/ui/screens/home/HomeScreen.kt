package app.aether.tv.ui.screens.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Extension
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.aether.core.addons.AddonClient
import app.aether.core.addons.KnownAddons
import app.aether.core.library.PlaybackProgress
import app.aether.core.model.ContentType
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.tv.aether
import app.aether.tv.ui.components.ContentRow
import app.aether.tv.ui.components.ContinueCard
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.HeroBanner
import app.aether.tv.ui.components.PosterCard
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.RowPlaceholder
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.components.rememberFocusMemory
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens

@Composable
fun HomeScreen(
    onOpenDetail: (MetaItem) -> Unit,
    onPlay: (MetaItem, Video?, Double?) -> Unit,
    onOpenAddons: (String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val engine = LocalContext.current.aether
    val vm: HomeViewModel = viewModel { HomeViewModel(engine) }
    val state by vm.state.collectAsStateWithLifecycle()
    val settings by engine.settings.value.collectAsStateWithLifecycle()
    val memory = rememberFocusMemory()
    val heroRequester = remember { FocusRequester() }
    val listState = rememberLazyListState()
    val noRows = state.rows.isEmpty()

    Box(modifier.fillMaxSize()) {
        when {
            state.loadingAddons -> Box(Modifier.fillMaxSize())
            state.addonCount == 0 -> Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.Center) {
                EmptyState(
                    "Nessun addon installato",
                    "Aether non include contenuti: i cataloghi e le sorgenti arrivano dagli addon che scegli tu. Per cominciare puoi aggiungere Cinemeta, il catalogo di base di Stremio.",
                ) {
                    val first = remember { FocusRequester() }
                    TvButton("Aggiungi Cinemeta", { onOpenAddons(KnownAddons.CINEMETA_MANIFEST_URL) }, primary = true, focusRequester = first, testTag = "home.addCinemeta")
                    TvButton("Aggiungi un altro addon", { onOpenAddons(null) }, icon = Icons.Filled.Extension, testTag = "home.addAddon")
                    RequestFocusOnce(first)
                }
            }
            noRows -> Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.Center) {
                EmptyState(
                    "Nessun catalogo da mostrare",
                    "Gli addon installati non offrono cataloghi (o li hai nascosti). Aggiungi Cinemeta o un altro addon di cataloghi, oppure mostra i cataloghi dalla pagina Addon.",
                ) {
                    val first = remember { FocusRequester() }
                    TvButton("Vai agli addon", { onOpenAddons(null) }, icon = Icons.Filled.Extension, primary = true, focusRequester = first)
                    RequestFocusOnce(first)
                }
            }
            else -> {
                if (state.hero.isNotEmpty() && memory.key.isEmpty()) RequestFocusOnce(heroRequester, state.hero.firstOrNull()?.id)
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = 56.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    if (state.hero.isNotEmpty()) item(key = "hero") {
                        HeroBanner(
                            items = state.hero,
                            autoScroll = settings.appearance.heroAutoScroll,
                            onPlay = { meta ->
                                if (meta.type == ContentType.MOVIE || !ContentType.hasEpisodes(meta.type)) onPlay(meta, null, null) else onOpenDetail(meta)
                            },
                            onDetails = onOpenDetail,
                            playRequester = heroRequester,
                        )
                    } else item(key = "top-space") { Box(Modifier.height(AetherDimens.ScreenVertical)) }

                    if (state.showContinue && "continue" !in state.hiddenSections && state.continueWatching.isNotEmpty()) item(key = "continue") {
                        ContentRow(
                            title = "Continua a guardare",
                            items = state.continueWatching,
                            key = { it.id },
                            rowId = "continue",
                            memory = memory,
                        ) { progress: PlaybackProgress, requester, onFocused ->
                            ContinueCard(
                                progress,
                                onClick = { onOpenDetail(progress.asMeta) },
                                focusRequester = requester,
                                onFocused = onFocused,
                            )
                        }
                    }
                    if (state.showNextUp && "nextup" !in state.hiddenSections && state.nextUp.isNotEmpty()) item(key = "nextup") {
                        ContentRow(
                            title = "Prossimo episodio",
                            items = state.nextUp,
                            key = { it.meta.id + it.video.id },
                            rowId = "nextup",
                            memory = memory,
                        ) { next, requester, onFocused ->
                            PosterCard(
                                next.meta.copy(name = "${next.meta.name} · ${next.video.episodeLabel.orEmpty()}"),
                                onClick = { onPlay(next.meta, next.video, null) },
                                focusRequester = requester,
                                onFocused = onFocused,
                                width = 150.dp,
                            )
                        }
                    }
                    for (row in state.rows) {
                        if (row.ref.id in state.hiddenSections) continue
                        item(key = row.ref.id) {
                            when (row.status) {
                                HomeViewModel.RowStatus.LOADING -> RowPlaceholder(rowTitle(row))
                                HomeViewModel.RowStatus.FAILED -> Column(Modifier.fillMaxWidth().padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(rowTitle(row), style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground)
                                    Text(row.error ?: "Non è stato possibile caricare questo catalogo.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
                                    TvChip("Riprova", selected = false, onClick = { vm.retry(row.ref) })
                                }
                                HomeViewModel.RowStatus.LOADED -> if (row.items.isNotEmpty()) {
                                    ContentRow(
                                        title = rowTitle(row),
                                        items = row.items,
                                        key = { it.id },
                                        rowId = row.ref.id,
                                        memory = memory,
                                    ) { meta, requester, onFocused ->
                                        PosterCard(
                                            meta,
                                            onClick = { onOpenDetail(meta) },
                                            width = (150 * settings.appearance.posterSize.scale).dp,
                                            focusRequester = requester,
                                            onFocused = onFocused,
                                        )
                                    }
                                }
                            }
                        }
                    }
                    item(key = "refresh") {
                        Row0 { TvButton("Aggiorna i cataloghi", { vm.reload(AddonClient.LoadMode.RELOAD) }, icon = Icons.Filled.Refresh, testTag = "home.refresh") }
                    }
                }
            }
        }
    }
}

@Composable
private fun Row0(content: @Composable () -> Unit) {
    Box(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 12.dp)) { content() }
}

private fun rowTitle(row: HomeViewModel.CatalogRow): String {
    val type = app.aether.core.addons.RequestPlanner.friendlyTypeName(row.ref.type)
    return "${row.ref.title} · $type"
}
