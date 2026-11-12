package app.aether.tv.ui.screens.trakt

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.aether.core.model.MetaItem
import app.aether.core.trakt.TraktCatalogKind
import app.aether.core.trakt.TraktService
import app.aether.core.trakt.TraktShelfItem
import app.aether.tv.aether
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.PosterCard
import app.aether.tv.ui.components.QrCode
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.RowPlaceholder
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent
import kotlinx.coroutines.launch

/**
 * The Trakt page: linking with a code (shown with a QR code for the phone), the sync options and the Trakt catalogs (personal ones
 * after linking, public ones always). Same content as the iOS Trakt page.
 */
@Composable
fun TraktScreen(onOpenDetail: (MetaItem) -> Unit) {
    val engine = LocalContext.current.aether
    val trakt = engine.trakt
    val state by trakt.state.collectAsState()
    val settings by engine.settings.value.collectAsState()
    val options = settings.trakt
    val scope = rememberCoroutineScope()
    val first = remember { FocusRequester() }
    val connected = state.link is TraktService.Link.Connected

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = AetherDimens.ScreenVertical, bottom = 48.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item(key = "header") {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Trakt", style = MaterialTheme.typography.displaySmall, color = AetherColors.OnBackground)
                when (val link = state.link) {
                    is TraktService.Link.Connected -> Text(
                        "Collegato" + (state.user?.let { " come ${it.username}" + if (it.vip) " (VIP)" else "" } ?: "") + (state.lastReport?.let { ". Ultima sincronizzazione: $it" } ?: "."),
                        style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted,
                    )
                    is TraktService.Link.Waiting -> Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
                        QrCode("${link.url}/${link.code}", size = 180.dp)
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("Sul telefono inquadra il codice QR, oppure apri ${link.url.removePrefix("https://")} e scrivi:", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
                            Text(link.code, style = MaterialTheme.typography.displayMedium, color = LocalAccent.current)
                            Text("Aspetto la conferma da Trakt…", style = MaterialTheme.typography.labelLarge, color = AetherColors.OnSurfaceFaint)
                        }
                    }
                    TraktService.Link.Disconnected -> Text(
                        if (trakt.client.isAvailable) "Collega il tuo account per sincronizzare watchlist e titoli visti, dire a Trakt cosa guardi e vedere i tuoi cataloghi personali."
                        else "Trakt non è disponibile in questa versione dell'app.",
                        style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted,
                    )
                }
                state.message?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.Warning) }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    when (state.link) {
                        is TraktService.Link.Connected -> {
                            TvButton(if (state.syncing) "Sincronizzo…" else "Sincronizza ora", { scope.launch { trakt.syncNow() } }, primary = true, enabled = !state.syncing, focusRequester = first, testTag = "trakt.sync")
                            TvButton("Scollega", { trakt.disconnect() }, testTag = "trakt.disconnect")
                        }
                        is TraktService.Link.Waiting -> TvButton("Annulla", { trakt.cancelConnect() }, focusRequester = first)
                        TraktService.Link.Disconnected -> TvButton("Collega Trakt", { trakt.connect() }, primary = true, enabled = trakt.client.isAvailable, focusRequester = first, testTag = "trakt.connect")
                    }
                }
                RequestFocusOnce(first, state.link::class)
            }
        }
        if (connected) item(key = "options") {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
                fun chip(title: String, on: Boolean, change: (Boolean) -> app.aether.core.trakt.TraktSettings) =
                    item(key = title) { TvChip("$title: ${if (on) "sì" else "no"}", on, { engine.settings.update { it.copy(trakt = change(!on)) } }) }
                chip("Attivo", options.enabled) { options.copy(enabled = it) }
                chip("Scrobble", options.scrobble) { options.copy(scrobble = it) }
                chip("Watchlist in comune", options.syncWatchlist) { options.copy(syncWatchlist = it) }
                chip("Visti in comune", options.syncWatched) { options.copy(syncWatched = it) }
                chip("Sincronizza all'avvio", options.syncOnLaunch) { options.copy(syncOnLaunch = it) }
                chip("Liste personali", options.showLists) { options.copy(showLists = it) }
            }
        }
        val kinds = TraktCatalogKind.entries.filter { (connected || !it.needsLogin) && options.isCatalogVisible(it) }
        if (trakt.client.isAvailable) {
            items(kinds, key = { it.name }) { kind -> TraktRow(kind.title, kind.name, onOpenDetail) { trakt.items(kind) } }
        } else {
            item { EmptyState("Trakt non disponibile", "Questa versione dell'app non ha un Client ID di Trakt.") }
        }
        if (connected && options.showLists) item(key = "lists") {
            var lists by remember { mutableStateOf<List<app.aether.core.trakt.TraktListInfo>>(emptyList()) }
            LaunchedEffect(Unit) { lists = runCatching { trakt.lists() }.getOrDefault(emptyList()) }
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                for (list in lists) TraktRow(list.name, "list-${list.id}", onOpenDetail) { trakt.listItems(list) }
            }
        }
    }
}

@Composable
private fun TraktRow(title: String, key: String, onOpenDetail: (MetaItem) -> Unit, load: suspend () -> List<TraktShelfItem>) {
    var items by remember(key) { mutableStateOf<List<TraktShelfItem>?>(null) }
    var error by remember(key) { mutableStateOf<String?>(null) }
    LaunchedEffect(key) {
        try { items = load() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Throwable) { error = e.message; items = emptyList() }
    }
    val loaded = items
    when {
        loaded == null -> RowPlaceholder(title)
        loaded.isEmpty() -> if (error != null) Text("$title: ${error}", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceFaint)
        else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground)
            LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
                items(loaded.distinctBy { it.meta.id }, key = { it.meta.id }) { item ->
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        PosterCard(item.meta, { onOpenDetail(item.meta) })
                        item.note?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1, modifier = Modifier.padding(start = 2.dp)) }
                    }
                }
            }
            Spacer(Modifier.height(2.dp))
        }
    }
}
