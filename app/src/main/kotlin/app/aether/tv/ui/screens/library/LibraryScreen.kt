package app.aether.tv.ui.screens.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.Text
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.aether.core.library.PlaybackProgress
import app.aether.core.model.MetaItem
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.PosterCard
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.components.rememberFocusMemory
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens

private enum class Tab(val title: String) { CONTINUE("Continua"), WATCHLIST("Watchlist"), FAVORITES("Preferiti"), HISTORY("Cronologia") }

@Composable
fun LibraryScreen(onOpenDetail: (MetaItem) -> Unit, onOpenDiscover: () -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val library = engine.library
    val revision by library.revision.collectAsStateWithLifecycle()
    var tabIndex by rememberSaveable { mutableStateOf(0) }
    val tab = Tab.entries[tabIndex]
    var actions by remember { mutableStateOf<Pair<MetaItem, PlaybackProgress?>?>(null) }
    var confirmClear by remember { mutableStateOf(false) }
    val memory = rememberFocusMemory()
    val firstTab = remember { FocusRequester() }
    val restore = remember { FocusRequester() }

    // Everything is re-read when the library changes.
    val continueItems = remember(revision) { library.continueWatching(60) }
    val watchlist = remember(revision) { library.watchlist() }
    val favorites = remember(revision) { library.favorites() }
    val history = remember(revision) { library.history(300) }

    if (memory.key.isEmpty()) RequestFocusOnce(firstTab, tabIndex)

    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical)) {
        Text("Libreria", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        LazyRow(contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(Tab.entries.size) { i ->
                val count = when (Tab.entries[i]) { Tab.CONTINUE -> continueItems.size; Tab.WATCHLIST -> watchlist.size; Tab.FAVORITES -> favorites.size; Tab.HISTORY -> history.size }
                TvChip("${Tab.entries[i].title} ($count)", i == tabIndex, { tabIndex = i }, focusRequester = if (i == tabIndex) firstTab else null, testTag = "library.tab.$i")
            }
        }
        val items: List<Pair<MetaItem, PlaybackProgress?>> = when (tab) {
            Tab.CONTINUE -> continueItems.map { it.asMeta to it }
            Tab.WATCHLIST -> watchlist.map { it.asMeta to null }
            Tab.FAVORITES -> favorites.map { it.asMeta to null }
            Tab.HISTORY -> history.map { it.asMeta to it }
        }.distinctBy { it.first.id + (it.second?.videoId ?: "") }
        if (items.isEmpty()) {
            EmptyState(
                when (tab) { Tab.CONTINUE -> "Niente da riprendere"; Tab.WATCHLIST -> "La watchlist è vuota"; Tab.FAVORITES -> "Nessun preferito"; Tab.HISTORY -> "La cronologia è vuota" },
                when (tab) {
                    Tab.CONTINUE -> "Quello che inizi a guardare e non finisci compare qui, con il punto in cui ti sei fermato."
                    Tab.WATCHLIST -> "Dalla pagina di un titolo premi «+» per ricordarti di guardarlo."
                    Tab.FAVORITES -> "Dalla pagina di un titolo premi il cuore per tenerlo qui."
                    Tab.HISTORY -> "Quello che guardi compare qui (se la cronologia è attiva nelle impostazioni di privacy)."
                },
                Modifier.fillMaxWidth().padding(top = 32.dp),
                icon = when (tab) { Tab.CONTINUE -> Icons.Filled.PlayCircle; Tab.WATCHLIST -> Icons.Filled.Bookmark; Tab.FAVORITES -> Icons.Filled.Favorite; Tab.HISTORY -> Icons.Filled.History },
            ) { TvButton("Scopri qualcosa", onOpenDiscover, primary = true) }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(150.dp),
                contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 12.dp, bottom = 48.dp),
                horizontalArrangement = Arrangement.spacedBy(AetherDimens.RowSpacing),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(items, key = { it.first.id + "|" + (it.second?.videoId ?: "") + tab.name }) { (meta, progress) ->
                    PosterCard(
                        meta.copy(name = progress?.episodeLabel?.let { "${meta.name} · $it" } ?: meta.name),
                        onClick = { onOpenDetail(meta) },
                        onLongClick = { actions = meta to progress },
                        progress = progress?.takeIf { !it.isCompleted }?.fraction,
                        watched = progress?.isCompleted == true,
                        focusRequester = if (meta.id == memory.key) restore else null,
                        onFocused = { memory.remember(meta.id) },
                    )
                }
            }
        }
        if (tab == Tab.HISTORY && history.isNotEmpty()) Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 4.dp)) { TvChip("Cancella la cronologia", false, { confirmClear = true }, testTag = "library.clearHistory") }
        if (tab == Tab.HISTORY || tab == Tab.CONTINUE) Text("Tieni premuto OK su un titolo per le azioni.", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
    }

    actions?.let { (meta, progress) ->
        val first = remember { FocusRequester() }
        AetherDialog(meta.name, { actions = null }, width = 520.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Apri", { actions = null; onOpenDetail(meta) }, primary = true, focusRequester = first, modifier = Modifier.fillMaxWidth())
                when (tab) {
                    Tab.WATCHLIST -> TvButton("Rimuovi dalla watchlist", { library.setWatchlist(false, meta); actions = null }, modifier = Modifier.fillMaxWidth())
                    Tab.FAVORITES -> TvButton("Rimuovi dai preferiti", { library.setFavorite(false, meta); actions = null }, modifier = Modifier.fillMaxWidth())
                    Tab.CONTINUE -> {
                        TvButton("Togli da «Continua a guardare»", { library.dismissFromContinueWatching(meta.id); actions = null }, modifier = Modifier.fillMaxWidth())
                    }
                    Tab.HISTORY -> progress?.let { p -> TvButton("Rimuovi dalla cronologia", { library.removeHistory(p.id); actions = null }, modifier = Modifier.fillMaxWidth()) }
                }
            }
            RequestFocusOnce(first)
        }
    }
    if (confirmClear) {
        val no = remember { FocusRequester() }
        AetherDialog("Cancellare la cronologia?", { confirmClear = false }, width = 520.dp) {
            Text("Spariranno anche i punti in cui ti sei fermato nei video. Watchlist e preferiti restano.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Cancella", { library.clearHistory(); confirmClear = false }, primary = true)
                TvButton("Annulla", { confirmClear = false }, focusRequester = no)
            }
            RequestFocusOnce(no)
        }
    }
}
