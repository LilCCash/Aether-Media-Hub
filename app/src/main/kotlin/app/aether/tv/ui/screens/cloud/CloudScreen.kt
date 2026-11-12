package app.aether.tv.ui.screens.cloud

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.aether.core.debrid.DebridCloudItem
import app.aether.core.debrid.DebridFile
import app.aether.core.debrid.DebridRequest
import app.aether.core.debrid.DebridResolver
import app.aether.core.model.AddonStream
import app.aether.core.model.MetaItem
import app.aether.core.model.StreamSource
import app.aether.core.net.AddonError
import app.aether.tv.PlaybackRequest
import app.aether.tv.Session
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.ProgressLine
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch

/**
 * Libreria ▸ Cloud: what is already in the viewer's TorBox or Real-Debrid account, as on the iPhone. OK on a ready torrent plays it
 * (a pack asks which file; a video inside a ZIP or RAR is read from inside); the ones still downloading show how far they are.
 */
@Composable
fun CloudScreen(onPlay: () -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<DebridCloudItem>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var opening by remember { mutableStateOf<String?>(null) }
    var choice by remember { mutableStateOf<Pair<List<DebridFile>, CompletableDeferred<DebridFile?>>?>(null) }
    suspend fun reload() {
        error = null
        items = try { engine.debrid.cloud() } catch (e: Throwable) { if (e is CancellationException) throw e; error = AddonError.from(e).message; emptyList() }
    }
    LaunchedEffect(Unit) { if (engine.debrid.isConfigured) reload() else items = emptyList() }
    val first = remember { FocusRequester() }

    fun open(item: DebridCloudItem) {
        if (opening != null) return
        scope.launch {
            opening = "Preparo «${item.name}»…"
            try {
                val url = engine.debrid.resolve(
                    DebridRequest(item.hash, emptyList(), null, null, null), DebridResolver.Mode.CachedOnly,
                    onProgress = { p -> opening = p.message },
                    chooseFile = { files -> val reply = CompletableDeferred<DebridFile?>(); choice = files to reply; reply.await() },
                )
                val meta = MetaItem("cloud:${item.hash}", "movie", item.name.substringBeforeLast('.').replace('.', ' ').trim().ifEmpty { item.name })
                Session.playback = PlaybackRequest(meta, null, AddonStream(StreamSource.Url(url), name = item.service), url, emptyMap(), emptyList(), null)
                opening = null
                onPlay()
            } catch (e: Throwable) {
                if (e is CancellationException) throw e
                opening = null
                error = (e as? app.aether.core.debrid.DebridError)?.message ?: AddonError.from(e).message
            }
        }
    }

    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Filled.Cloud, null, tint = LocalAccent.current)
            Text("Cloud · ${engine.debrid.service.title}", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground)
        }
        (opening ?: error)?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = if (opening != null) LocalAccent.current else AetherColors.Warning, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), maxLines = 2) }
        val list = items
        when {
            !engine.debrid.isConfigured -> EmptyState("Nessun servizio collegato", "Aggiungi la chiave di TorBox o di Real-Debrid in Impostazioni ▸ Servizi per vedere qui i tuoi file.", Modifier.fillMaxSize())
            list == null -> LoadingState("Leggo il tuo account…", Modifier.fillMaxSize())
            list.isEmpty() -> EmptyState("Il cloud è vuoto", "I torrent che aggiungi a ${engine.debrid.service.title} (anche dall'app) compaiono qui.", Modifier.fillMaxSize()) {
                TvButton("Aggiorna", { scope.launch { items = null; reload() } }, primary = true)
            }
            else -> {
                LazyColumn(contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 8.dp, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(list.distinctBy { it.hash }, key = { it.hash }) { item ->
                        FocusSurface({ if (item.ready) open(item) }, Modifier.fillMaxWidth().height(84.dp), focusScale = 1.02f, focusRequester = if (item == list.first()) first else null, testTag = "cloud.${item.hash.take(8)}") {
                            Row(Modifier.fillMaxSize().padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text(item.name, style = MaterialTheme.typography.titleMedium, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(listOfNotNull(item.bytes?.let { "%.2f GB".format(it / 1_073_741_824.0) }, if (item.ready) "pronto da guardare" else "in download · ${(item.progress * 100).toInt()}%").joinToString(" · "),
                                        style = MaterialTheme.typography.labelMedium, color = if (item.ready) AetherColors.Success else AetherColors.OnSurfaceMuted)
                                }
                                if (!item.ready) ProgressLine(item.progress, Modifier.width(200.dp))
                            }
                        }
                    }
                }
                RequestFocusOnce(first, list.size)
            }
        }
    }

    choice?.let { (files, reply) ->
        val firstFile = remember { FocusRequester() }
        AetherDialog("Quale file?", { reply.complete(null); choice = null }, width = 760.dp) {
            LazyColumn(Modifier.height(420.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(files.distinctBy { it.id }, key = { it.id }) { f ->
                    FocusSurface({ reply.complete(f); choice = null }, Modifier.fillMaxWidth().height(56.dp), focusScale = 1.02f, focusRequester = if (f == files.first()) firstFile else null) {
                        Row(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(f.shortName, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            f.size?.let { Text("%.2f GB".format(it / 1_073_741_824.0), style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted) }
                        }
                    }
                }
            }
            RequestFocusOnce(firstFile)
        }
    }
}
