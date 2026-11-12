package app.aether.tv.ui.screens.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
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

private enum class Tab(val title: String) { CONTINUE("Continua"), WATCHLIST("Watchlist"), FAVORITES("Preferiti"), COLLECTIONS("Collezioni"), UNIVERSES("Universi"), ABANDONED("Abbandonati"), HISTORY("Cronologia"), DOWNLOADS("Download") }

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen(onOpenDetail: (MetaItem) -> Unit, onOpenDiscover: () -> Unit, onOpenTrakt: () -> Unit = {}, onPlay: () -> Unit = {}, modifier: Modifier = Modifier, onOpenUniverse: (String) -> Unit = {}) {
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
    val downloads by engine.downloads.items.collectAsStateWithLifecycle()
    val abandoned = remember(revision) { library.abandoned() }
    val collections = remember(revision) { library.collections() }
    val watchedIds = remember(revision) { library.history(2000).filter { it.isCompleted }.map { it.metaId }.toSet() + library.diary().map { it.metaId } }
    var openCollection by rememberSaveable { mutableStateOf<String?>(null) }
    var naming by remember { mutableStateOf<String?>(null) }

    if (memory.key.isEmpty()) RequestFocusOnce(firstTab, tabIndex)

    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical)) {
        Text("Libreria", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        LazyRow(contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(Tab.entries.size) { i ->
                val count = when (Tab.entries[i]) { Tab.CONTINUE -> continueItems.size; Tab.WATCHLIST -> watchlist.size; Tab.FAVORITES -> favorites.size; Tab.HISTORY -> history.size; Tab.DOWNLOADS -> downloads.size; Tab.ABANDONED -> abandoned.size; Tab.COLLECTIONS -> collections.size; Tab.UNIVERSES -> app.aether.core.universe.UniverseCatalog.all.size }
                TvChip("${Tab.entries[i].title} ($count)", i == tabIndex, { tabIndex = i; openCollection = null }, focusRequester = if (i == tabIndex) firstTab else null, testTag = "library.tab.$i")
            }
            item(key = "trakt") { TvChip("Trakt", false, onOpenTrakt, testTag = "library.trakt") }
        }
        val items: List<Pair<MetaItem, PlaybackProgress?>> = when (tab) {
            Tab.CONTINUE -> continueItems.map { it.asMeta to it }
            Tab.WATCHLIST -> watchlist.map { it.asMeta to null }
            Tab.FAVORITES -> favorites.map { it.asMeta to null }
            Tab.HISTORY -> history.map { it.asMeta to it }
            Tab.ABANDONED -> abandoned.map { it.asMeta to it }
            Tab.COLLECTIONS -> collections.firstOrNull { it.id == openCollection }?.items.orEmpty().map { MetaItem(it.id, it.type, it.name, it.poster) to null }
            Tab.DOWNLOADS, Tab.UNIVERSES -> emptyList()
        }.distinctBy { it.first.id + (it.second?.videoId ?: "") }
        if (tab == Tab.DOWNLOADS) {
            DownloadList(downloads, onPlay)
        } else if (tab == Tab.UNIVERSES) {
            UniverseGrid(watchedIds, onOpenUniverse)
        } else if (tab == Tab.COLLECTIONS && openCollection == null) {
            CollectionGrid(collections, onOpen = { openCollection = it }, onNew = { naming = "" })
        } else if (items.isEmpty()) {
            EmptyState(
                when (tab) { Tab.CONTINUE -> "Niente da riprendere"; Tab.WATCHLIST -> "La watchlist è vuota"; Tab.FAVORITES -> "Nessun preferito"; Tab.HISTORY -> "La cronologia è vuota"; Tab.ABANDONED -> "Nessun titolo abbandonato"; Tab.COLLECTIONS -> "La collezione è vuota"; else -> "" },
                when (tab) {
                    Tab.CONTINUE -> "Quello che inizi a guardare e non finisci compare qui, con il punto in cui ti sei fermato."
                    Tab.WATCHLIST -> "Dalla pagina di un titolo premi «+» per ricordarti di guardarlo."
                    Tab.FAVORITES -> "Dalla pagina di un titolo premi il cuore per tenerlo qui."
                    Tab.HISTORY -> "Quello che guardi compare qui (se la cronologia è attiva nelle impostazioni di privacy)."
                    Tab.ABANDONED -> "Quello che inizi e lasci per più di un mese compare qui."
                    Tab.COLLECTIONS -> "Dalla pagina di un titolo premi «Aggiungi a una collezione»."
                    else -> ""
                },
                Modifier.fillMaxWidth().padding(top = 32.dp),
                icon = when (tab) { Tab.CONTINUE -> Icons.Filled.PlayCircle; Tab.WATCHLIST -> Icons.Filled.Bookmark; Tab.FAVORITES -> Icons.Filled.Favorite; else -> Icons.Filled.History },
            ) { TvButton("Scopri qualcosa", onOpenDiscover, primary = true) }
        } else {
            androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides app.aether.tv.ui.theme.GridScroll) { LazyVerticalGrid(
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
            } }
        }
        if (tab == Tab.COLLECTIONS && openCollection != null) Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val c = collections.firstOrNull { it.id == openCollection }
            TvChip("← Tutte le collezioni", false, { openCollection = null }, testTag = "library.collections.back")
            if (c != null) {
                TvChip("Rinomina", false, { naming = c.name })
                TvChip("Elimina la collezione", false, { library.deleteCollection(c.id); openCollection = null })
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
                    Tab.WATCHLIST -> TvButton("Rimuovi dalla watchlist", { library.setWatchlist(false, meta); engine.trakt.watchlistChanged(meta, false); actions = null }, modifier = Modifier.fillMaxWidth())
                    Tab.FAVORITES -> TvButton("Rimuovi dai preferiti", { library.setFavorite(false, meta); actions = null }, modifier = Modifier.fillMaxWidth())
                    Tab.CONTINUE -> {
                        TvButton("Togli da «Continua a guardare»", { library.dismissFromContinueWatching(meta.id); actions = null }, modifier = Modifier.fillMaxWidth())
                    }
                    Tab.HISTORY -> progress?.let { p -> TvButton("Rimuovi dalla cronologia", { library.removeHistory(p.id); actions = null }, modifier = Modifier.fillMaxWidth()) }
                    Tab.ABANDONED -> TvButton("Non mi interessa più", { library.dismissFromContinueWatching(meta.id); actions = null }, modifier = Modifier.fillMaxWidth())
                    Tab.COLLECTIONS -> openCollection?.let { cid -> TvButton("Togli dalla collezione", { library.toggleInCollection(cid, meta); actions = null }, modifier = Modifier.fillMaxWidth()) }
                    else -> {}
                }
            }
            RequestFocusOnce(first)
        }
    }
    naming?.let { initial ->
        var text by remember { mutableStateOf(initial) }
        val field = remember { FocusRequester() }
        AetherDialog(if (initial.isEmpty()) "Nuova collezione" else "Rinomina la collezione", { naming = null }, width = 560.dp) {
            app.aether.tv.ui.components.TvTextField(text, { text = it.take(40) }, "Nome (per esempio «Horror anni 80»)", Modifier.fillMaxWidth(), focusRequester = field, onImeAction = {
                if (initial.isEmpty()) library.createCollection(text)?.let { openCollection = null } else openCollection?.let { library.renameCollection(it, text) }
                naming = null
            })
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Salva", {
                    if (initial.isEmpty()) library.createCollection(text) else openCollection?.let { library.renameCollection(it, text) }
                    naming = null
                }, primary = true, enabled = text.isNotBlank())
                TvButton("Annulla", { naming = null })
            }
            RequestFocusOnce(field)
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


/** Libreria ▸ Download: what is saved on the TV, with its progress; OK plays it, long press for pause, resume and delete. */
@Composable
private fun DownloadList(downloads: List<app.aether.core.downloads.DownloadItem>, onPlay: () -> Unit) {
    val context = LocalContext.current
    val engine = context.aether
    var selected by remember { mutableStateOf<app.aether.core.downloads.DownloadItem?>(null) }
    if (downloads.isEmpty()) {
        EmptyState("Nessun download", "Nella scelta della sorgente tieni premuto OK e scegli «Scarica sulla TV»: il video resta qui anche senza rete.", Modifier.fillMaxWidth().padding(top = 32.dp), icon = Icons.Filled.History)
        return
    }
    fun play(item: app.aether.core.downloads.DownloadItem) {
        val file = engine.downloads.fileOf(item)
        val uri = android.net.Uri.fromFile(file).toString()
        app.aether.tv.Session.playback = app.aether.tv.PlaybackRequest(
            item.asMeta(), item.asVideo(), app.aether.core.model.AddonStream(app.aether.core.model.StreamSource.Url(uri), name = "Download"), uri, emptyMap(), emptyList(),
            item.videoId?.let { engine.library.resumePosition(item.metaId, it) } ?: engine.library.resumePosition(item.metaId, item.metaId),
        )
        onPlay()
    }
    val used = remember(downloads) { engine.downloads.usedBytes }
    androidx.compose.foundation.lazy.LazyColumn(
        contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 12.dp, bottom = 48.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item { Text("Spazio usato: ${"%.1f".format(used / 1_073_741_824.0)} GB · tieni premuto OK per mettere in pausa, riprendere o eliminare.", style = MaterialTheme.typography.labelLarge, color = AetherColors.OnSurfaceFaint) }
        items(downloads.size, key = { downloads[it].id }) { index ->
            val item = downloads[index]
            app.aether.tv.ui.components.FocusSurface(
                onClick = { if (item.state == app.aether.core.downloads.DownloadState.DONE) play(item) else selected = item },
                onLongClick = { selected = item },
                modifier = Modifier.fillMaxWidth().height(96.dp), focusScale = 1.02f, testTag = "download.row",
            ) {
                Row(Modifier.fillMaxSize().padding(horizontal = 14.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    app.aether.tv.ui.components.RemoteImage(item.poster, item.title, Modifier.height(76.dp).width(52.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(item.label, style = MaterialTheme.typography.titleMedium, color = AetherColors.OnBackground, maxLines = 1)
                        val size = item.totalBytes?.let { " · ${"%.2f".format(it / 1_073_741_824.0)} GB" }.orEmpty()
                        Text(item.state.title + (item.fraction?.takeIf { item.state != app.aether.core.downloads.DownloadState.DONE }?.let { " · ${(it * 100).toInt()}%" }.orEmpty()) + size,
                            style = MaterialTheme.typography.bodyMedium, color = if (item.state == app.aether.core.downloads.DownloadState.FAILED) AetherColors.Danger else AetherColors.OnSurfaceMuted)
                        item.error?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1) }
                        if (item.state != app.aether.core.downloads.DownloadState.DONE) item.fraction?.let { app.aether.tv.ui.components.ProgressLine(it, Modifier.width(360.dp)) }
                    }
                }
            }
        }
    }
    selected?.let { item ->
        val first = remember { FocusRequester() }
        AetherDialog(item.label, { selected = null }, width = 520.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                when (item.state) {
                    app.aether.core.downloads.DownloadState.DONE -> TvButton("Guarda", { selected = null; play(item) }, primary = true, focusRequester = first, modifier = Modifier.fillMaxWidth())
                    app.aether.core.downloads.DownloadState.RUNNING, app.aether.core.downloads.DownloadState.QUEUED ->
                        TvButton("Metti in pausa", { app.aether.tv.downloads.DownloadWorker.pause(context, item.id); selected = null }, primary = true, focusRequester = first, modifier = Modifier.fillMaxWidth())
                    else -> TvButton(if (engine.downloads.source(item.id) != null) "Riprendi" else "Non si può riprendere", {
                        if (engine.downloads.source(item.id) != null) app.aether.tv.downloads.DownloadWorker.start(context, item.id); selected = null
                    }, primary = true, focusRequester = first, modifier = Modifier.fillMaxWidth())
                }
                TvButton("Elimina", { app.aether.tv.downloads.DownloadWorker.remove(context, item.id); selected = null }, modifier = Modifier.fillMaxWidth(), testTag = "download.delete")
            }
            RequestFocusOnce(first)
        }
    }
}


/** Libreria ▸ Collezioni: every list as a card with a mosaic of its posters; the first card makes a new one. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun CollectionGrid(collections: List<app.aether.core.library.LibraryCollection>, onOpen: (String) -> Unit, onNew: () -> Unit) {
    androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides app.aether.tv.ui.theme.GridScroll) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(260.dp),
            contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 12.dp, bottom = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(20.dp), verticalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "new") {
                app.aether.tv.ui.components.FocusSurface(onNew, Modifier.fillMaxWidth().height(170.dp), glow = true, testTag = "library.collections.new") {
                    Column(Modifier.align(androidx.compose.ui.Alignment.Center), horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("+", style = MaterialTheme.typography.displaySmall, color = app.aether.tv.ui.theme.LocalAccent.current)
                        Text("Nuova collezione", style = MaterialTheme.typography.titleMedium, color = AetherColors.OnBackground)
                    }
                }
            }
            items(collections, key = { it.id }) { c ->
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    app.aether.tv.ui.components.FocusSurface({ onOpen(c.id) }, Modifier.fillMaxWidth().height(170.dp), glow = true, testTag = "library.collection.${c.name}") {
                        Row(Modifier.fillMaxSize()) {
                            val posters = c.items.take(4)
                            if (posters.isEmpty()) Box(Modifier.fillMaxSize().background(AetherColors.SurfaceRaised))
                            posters.forEach { app.aether.tv.ui.components.RemoteImage(it.poster, it.name, Modifier.weight(1f).fillMaxHeight()) }
                        }
                        Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(androidx.compose.ui.graphics.Color.Transparent, androidx.compose.ui.graphics.Color(0xCC000000)))))
                        Column(Modifier.align(androidx.compose.ui.Alignment.BottomStart).padding(14.dp)) {
                            Text(c.name, style = MaterialTheme.typography.titleLarge, color = androidx.compose.ui.graphics.Color.White, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                            Text(if (c.items.size == 1) "1 titolo" else "${c.items.size} titoli", style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted)
                        }
                    }
                }
            }
        }
    }
}

/** Libreria ▸ Universi: the sagas of cinema, each with its picture and how far the viewer is. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun UniverseGrid(watched: Set<String>, onOpen: (String) -> Unit) {
    val all = app.aether.core.universe.UniverseCatalog.all
    androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides app.aether.tv.ui.theme.GridScroll) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(300.dp),
            contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 12.dp, bottom = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(20.dp), verticalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.fillMaxSize(),
        ) {
            items(all, key = { it.id }) { u ->
                val progress = app.aether.core.universe.UniverseProgress.compute(u, app.aether.core.universe.UniverseOrder.RELEASE, watched)
                app.aether.tv.ui.components.FocusSurface({ onOpen(u.id) }, Modifier.fillMaxWidth().height(170.dp), glow = true, testTag = "library.universe.${u.id}",
                    onFocused = { app.aether.tv.ui.Ambient.show(u.heroBackground) }) {
                    app.aether.tv.ui.components.RemoteImage(u.heroBackground, u.name, Modifier.fillMaxSize())
                    Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(listOf(androidx.compose.ui.graphics.Color(0x33000000), androidx.compose.ui.graphics.Color(0xE6000000)))))
                    Column(Modifier.align(androidx.compose.ui.Alignment.BottomStart).padding(14.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(u.name, style = MaterialTheme.typography.titleLarge, color = androidx.compose.ui.graphics.Color.White, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                        Text("${u.entries.size} titoli" + (u.years?.let { " · ${it.first}–${it.last}" } ?: "") + if (progress.watched > 0) " · visti ${progress.watched}" else "", style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted, maxLines = 1)
                        if (progress.watched > 0) app.aether.tv.ui.components.ProgressLine(progress.fraction, Modifier.fillMaxWidth())
                    }
                }
            }
        }
    }
}
