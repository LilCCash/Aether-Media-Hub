package app.aether.tv.ui.screens.detail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.aether.core.model.StreamSource
import app.aether.core.playback.Languages
import app.aether.core.playback.PlaybackSupport
import app.aether.core.playback.RankedStream
import app.aether.tv.Session
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.Badge
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.ProgressLine
import app.aether.tv.ui.components.RemoteImage
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent

@Composable
fun StreamsScreen(onPlayerReady: () -> Unit, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val request = Session.streamRequest
    if (request == null) {
        EmptyState("Nessuna richiesta", "Torna indietro e scegli di nuovo cosa guardare.", modifier.fillMaxSize()) { TvButton("Indietro", onBack, primary = true) }
        return
    }
    val context = LocalContext.current
    val engine = context.aether
    val language = remember { java.util.Locale.getDefault().language }
    val vm: StreamsViewModel = viewModel(key = "streams/${request.meta.id}/${request.video?.id}") { StreamsViewModel(engine, request, language) }
    val state by vm.state.collectAsStateWithLifecycle()
    val firstRow = remember { FocusRequester() }

    LaunchedEffect(Unit) { vm.play.collect { onPlayerReady() } }
    LifecycleResumeEffect(Unit) { vm.rearm(); onPauseOrDispose { } }
    if (state.visible.isNotEmpty()) RequestFocusOnce(firstRow, state.visible.first().id.takeIf { state.resolvingId == null })

    Row(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical)) {
        // Left: what is being played.
        Column(Modifier.width(280.dp).fillMaxHeight().padding(start = AetherDimens.ScreenHorizontal, end = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            RemoteImage(request.meta.poster ?: request.meta.background, request.meta.name, Modifier.width(180.dp).height(266.dp).clip(RoundedCornerShape(12.dp)))
            Text(request.meta.name, style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground, maxLines = 3, overflow = TextOverflow.Ellipsis)
            request.video?.let { video ->
                Text(listOfNotNull(video.episodeLabel, video.title.takeIf { it.isNotBlank() }).joinToString(" · "), style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, maxLines = 3)
            }
            request.resumeAt?.let { Text("Riprende da ${app.aether.tv.ui.components.formatDuration(it)}", style = MaterialTheme.typography.labelMedium, color = LocalAccent.current) }
        }
        // Right: the sources.
        Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Scegli la sorgente", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground)
            if (state.addonNames.size > 1) LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 6.dp, horizontal = 2.dp)) {
                item { TvChip("Tutti", state.addonFilter == null, { vm.setFilter(null) }, testTag = "streams.filter.all") }
                items(state.addonNames.size, key = { state.addonNames[it] }) { i -> TvChip(state.addonNames[i], state.addonFilter == state.addonNames[i], { vm.setFilter(state.addonNames[i]) }) }
            }
            if (state.loading) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                androidx.compose.material3.CircularProgressIndicator(Modifier.width(22.dp).height(22.dp), color = LocalAccent.current, strokeWidth = 3.dp)
                Text(
                    if (state.visible.isEmpty()) "Cerco le sorgenti…" else "Altre sorgenti in arrivo…" + state.pendingAddons.takeIf { it.isNotEmpty() }?.let { "  (in attesa di ${it.joinToString(", ")})" }.orEmpty(),
                    style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, maxLines = 1,
                )
            }
            val playable = state.visible.filter { it.info.support.isPlayable }
            val unplayable = state.visible.filter { !it.info.support.isPlayable }
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 6.dp, bottom = 48.dp, end = AetherDimens.ScreenHorizontal, start = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(playable.size, key = { playable[it].id }) { index ->
                    val item = playable[index]
                    StreamRow(
                        item, best = index == 0, cached = vm.isCached(item), torBox = state.torBoxConfigured,
                        requester = if (index == 0) firstRow else null, onClick = { vm.select(item) },
                    )
                    if (state.resolvingId == item.id) {
                        ResolveProgress(state.progress?.message ?: "…", state.progress?.fraction, state.progress?.detail, onCancel = vm::cancelResolution)
                    }
                    state.rowFailure?.takeIf { it.first == item.id }?.let { failure ->
                        Text(failure.second, style = MaterialTheme.typography.bodyMedium, color = AetherColors.Danger, modifier = Modifier.padding(horizontal = 8.dp))
                    }
                }
                if (!state.loading && state.ranked.isEmpty()) item(key = "empty") {
                    EmptyState(
                        "Nessuna sorgente trovata",
                        if (state.errors.isEmpty()) "Gli addon attivi non hanno restituito sorgenti per questo titolo. Prova con un altro addon o riprova più tardi."
                        else "Gli addon non hanno risposto: " + state.errors.entries.take(2).joinToString("; ") { "${it.key}: ${it.value}" },
                        Modifier.fillMaxWidth(),
                    ) { TvButton("Riprova", vm::start, icon = Icons.Filled.Refresh, primary = true, testTag = "streams.retry") }
                }
                if (unplayable.isNotEmpty()) item(key = "unplayable-title") {
                    Text("Non riproducibili qui (${unplayable.size})", style = MaterialTheme.typography.titleMedium, color = AetherColors.OnSurfaceMuted, modifier = Modifier.padding(top = 10.dp))
                }
                items(unplayable.size, key = { "u-" + unplayable[it].id }) { index ->
                    val item = unplayable[index]
                    StreamRow(item, best = false, cached = null, torBox = state.torBoxConfigured, requester = null, onClick = { vm.select(item) })
                }
                if (state.errors.isNotEmpty() && state.ranked.isNotEmpty()) item(key = "errors") {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.padding(top = 8.dp)) {
                        Text("Addon con problemi", style = MaterialTheme.typography.labelMedium, color = AetherColors.Warning)
                        for ((name, message) in state.errors.entries.take(5)) Text("$name: $message", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1)
                    }
                }
            }
        }
    }

    state.blocked?.let { message ->
        val ok = remember { FocusRequester() }
        AetherDialog("Non si può riprodurre", vm::dismissBlocked) {
            Text(message, style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
            TvButton("OK", vm::dismissBlocked, primary = true, focusRequester = ok)
            RequestFocusOnce(ok)
        }
    }
    state.askDownload?.let { item ->
        val yes = remember { FocusRequester() }
        AetherDialog("Torrent non in cache", vm::cancelDownloadPrompt) {
            Text("TorBox non ha questo torrent già pronto: scaricarlo richiede tempo, spazio e traffico sul tuo account TorBox. Vuoi scaricarlo?", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TvButton("Scarica su TorBox", { vm.confirmDownload(item) }, primary = true, focusRequester = yes, testTag = "streams.confirmDownload")
                TvButton("Annulla", vm::cancelDownloadPrompt)
            }
            RequestFocusOnce(yes)
        }
    }
    state.fileChoice?.let { choice ->
        val first = remember { FocusRequester() }
        AetherDialog("Scegli il file", { vm.chooseFile(null) }, width = 760.dp) {
            Text("Non riesco a capire da solo quale file corrisponde a questo episodio.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
            LazyColumn(Modifier.height(280.dp), verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(4.dp)) {
                items(choice.candidates.size) { i ->
                    val file = choice.candidates[i]
                    FocusSurface(onClick = { vm.chooseFile(file) }, modifier = Modifier.fillMaxWidth().height(48.dp), focusRequester = if (i == 0) first else null) {
                        Text(file.shortName, Modifier.padding(horizontal = 14.dp).align(Alignment.CenterStart), style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            RequestFocusOnce(first)
        }
    }
}

@Composable
private fun ResolveProgress(message: String, fraction: Double?, detail: String?, onCancel: () -> Unit) {
    val cancel = remember { FocusRequester() }
    Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(message, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground)
        if (fraction != null) ProgressLine(fraction, Modifier.width(420.dp))
        detail?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted) }
        TvChip("Annulla l'attesa", false, onCancel, focusRequester = cancel, testTag = "streams.cancel")
    }
}

@Composable
private fun StreamRow(item: RankedStream, best: Boolean, cached: Boolean?, torBox: Boolean, requester: FocusRequester?, onClick: () -> Unit) {
    val info = item.info
    val stream = item.stream
    val playable = info.support.isPlayable
    FocusSurface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        focusScale = 1.02f,
        focusRequester = requester,
        testTag = if (best) "streams.best" else null,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (best) Badge("Consigliata", color = LocalAccent.current, contentColor = AetherColors.Background)
                Text(stream.name ?: "Sorgente", style = MaterialTheme.typography.titleMedium, color = if (playable) AetherColors.OnBackground else AetherColors.OnSurfaceMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                stream.addonName?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1) }
            }
            stream.details?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = AetherColors.OnSurfaceMuted, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                for (text in info.badges) Badge(text)
                info.formatLabel?.let { Badge(it) }
                info.sizeLabel?.let { Badge(it) }
                for (lang in info.languages.take(3)) Badge(if (lang == "multi") "Multi" else Languages.displayName(lang))
                if (stream.source is StreamSource.Torrent) {
                    Badge("Torrent")
                    if (torBox) {
                        if (cached == true) Badge("In cache", color = AetherColors.Success, contentColor = AetherColors.Background)
                        else Badge("TorBox", color = AetherColors.SurfaceFocused)
                    }
                }
            }
            val support = info.support
            if (support is PlaybackSupport.Unsupported) Text(support.reason.message, style = MaterialTheme.typography.labelSmall, color = AetherColors.Warning, maxLines = 2)
            for (warning in info.warnings.take(2)) Text(warning, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1)
        }
    }
}
