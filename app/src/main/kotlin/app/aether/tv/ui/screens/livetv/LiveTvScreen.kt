package app.aether.tv.ui.screens.livetv

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.aether.core.addons.CatalogRef
import app.aether.core.addons.RequestPlanner
import app.aether.core.livetv.LiveChannelList
import app.aether.core.livetv.LiveFavorite
import app.aether.core.livetv.LiveGuideStyle
import app.aether.core.livetv.M3uChannel
import app.aether.core.livetv.TvProgramme
import app.aether.core.model.AddonStream
import app.aether.core.model.MetaItem
import app.aether.core.model.PosterShape
import app.aether.core.model.StreamSource
import app.aether.tv.PlaybackRequest
import app.aether.tv.Session
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.Badge
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.PosterCard
import app.aether.tv.ui.components.ProgressLine
import app.aether.tv.ui.components.RemoteImage
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.components.TvTextField
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class LiveTab(val title: String) { CHANNELS("Canali"), GUIDE("Guida"), FAVORITES("Preferiti"), ADDONS("Dagli addon") }

/**
 * Live TV: the channels of the viewer's M3U playlists with what is on now (from the XMLTV guide), a time grid of the guide, the
 * favourite channels and the «tv» catalogs of the addons. Playlists are added in Impostazioni ▸ TV in diretta or from the phone.
 */
@Composable
fun LiveTvScreen(onOpenDetail: (MetaItem) -> Unit, onPlay: () -> Unit, onPhone: () -> Unit) {
    val engine = LocalContext.current.aether
    val scope = rememberCoroutineScope()
    val live by engine.liveTv.state.collectAsState()
    val settings by engine.settings.value.collectAsState()
    val liveSettings = settings.liveTv
    var tab by remember { mutableStateOf(if (liveSettings.guideStyle == LiveGuideStyle.GRID) LiveTab.GUIDE else LiveTab.CHANNELS) }
    var showSettings by remember { mutableStateOf(false) }
    val onOpenSettings = { showSettings = true }
    var group by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var info by remember { mutableStateOf<M3uChannel?>(null) }
    val firstTab = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        engine.liveTv.load()
        engine.liveTv.refreshGuide()
    }
    LaunchedEffect(Unit) { while (true) { delay(30_000); now = System.currentTimeMillis() } }

    fun play(channel: M3uChannel) {
        val meta = MetaItem(channel.id, "tv", channel.name, poster = channel.logo, posterShape = PosterShape.SQUARE, description = engine.liveTv.now(channel)?.title)
        Session.playback = PlaybackRequest(meta, null, AddonStream(StreamSource.Url(channel.url), name = channel.name), channel.url, channel.requestHeaders, emptyList(), null)
        onPlay()
    }

    fun toggleFavorite(channel: M3uChannel) = engine.settings.update {
        it.copy(liveTv = it.liveTv.togglingFavorite(LiveFavorite(channel.id, channel.name, channel.logo, channel.url, channel.userAgent, channel.referrer)))
    }

    val channels = live.allChannels
    Column(Modifier.fillMaxSize().padding(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = AetherDimens.ScreenVertical)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("TV in diretta", style = MaterialTheme.typography.displaySmall, color = AetherColors.OnBackground)
            Spacer(Modifier.weight(1f))
            if (live.loadingGuide) Text("Aggiorno la guida…", style = MaterialTheme.typography.labelLarge, color = AetherColors.OnSurfaceMuted)
            TvButton("Playlist e guida", onOpenSettings, testTag = "live.settings")
        }
        Spacer(Modifier.height(14.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
            items(LiveTab.entries.toList(), key = { it.name }) { entry ->
                TvChip(entry.title, tab == entry, { tab = entry }, focusRequester = if (entry == tab) firstTab else null, testTag = "live.tab.${entry.name}")
            }
        }
        RequestFocusOnce(firstTab)
        live.guideMessage?.let { Text(it, style = MaterialTheme.typography.labelLarge, color = AetherColors.Warning, modifier = Modifier.padding(top = 6.dp)) }
        Spacer(Modifier.height(10.dp))
        when (tab) {
            LiveTab.CHANNELS -> {
                if (channels.isEmpty()) {
                    EmptyState("Nessuna playlist", "Aggiungi l'indirizzo di una playlist M3U (anche dal telefono, in Impostazioni ▸ TV in diretta): i canali compaiono qui, con la guida dei programmi.", icon = Icons.Filled.LiveTv) {
                        TvButton("Aggiungi una playlist", onOpenSettings, primary = true)
                    }
                } else {
                    val groups = remember(channels) { LiveChannelList.groups(channels) }
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        TvTextField(query, { query = it }, "Cerca un canale", modifier = Modifier.width(360.dp))
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
                            item(key = "all") { TvChip("Tutti (${channels.size})", group == null, { group = null }) }
                            items(groups, key = { it.first }) { (name, count) -> TvChip("$name ($count)", group == name, { group = name }) }
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    val visible = remember(channels, query, group) { LiveChannelList.filter(channels, query, group) }
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(bottom = 48.dp)) {
                        items(visible, key = { it.id }) { channel ->
                            ChannelRow(channel, engine.liveTv.now(channel, now), engine.liveTv.upcoming(channel, 2).drop(1).firstOrNull(), now,
                                favorite = liveSettings.isFavorite(channel.id), onPlay = { play(channel) }, onLong = { info = channel })
                        }
                    }
                }
            }
            LiveTab.GUIDE -> {
                if (channels.isEmpty() || live.guide.isEmpty) {
                    EmptyState("Guida non disponibile", if (channels.isEmpty()) "Serve almeno una playlist M3U." else "La guida si scarica da sola; puoi scegliere un indirizzo XMLTV in Impostazioni ▸ TV in diretta.", icon = Icons.Filled.LiveTv) {
                        TvButton("Aggiorna la guida", { scope.launch { engine.liveTv.refreshGuide(force = true) } }, primary = true)
                    }
                } else {
                    GuideGrid(channels.filter { engine.liveTv.channelId(it) != null }.take(300), now, { engine.liveTv.between(it, now - 30 * 60_000, now + 4 * 3_600_000) }, ::play)
                }
            }
            LiveTab.FAVORITES -> {
                val favorites = liveSettings.favorites
                if (favorites.isEmpty()) {
                    EmptyState("Nessun preferito", "Tieni premuto OK su un canale per aggiungerlo ai preferiti.", icon = Icons.Filled.LiveTv)
                } else {
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(bottom = 48.dp)) {
                        items(favorites, key = { it.id }) { fav ->
                            val channel = channels.firstOrNull { it.id == fav.id } ?: fav.url?.let { M3uChannel(fav.id, fav.name, fav.logo, null, it, fav.userAgent, fav.referrer) }
                            if (channel != null) {
                                ChannelRow(channel, engine.liveTv.now(channel, now), null, now, favorite = true, onPlay = { play(channel) }, onLong = { info = channel })
                            } else if (fav.metaId != null && fav.metaType != null) {
                                FocusSurface(onClick = { onOpenDetail(MetaItem(fav.metaId!!, fav.metaType!!, fav.name, poster = fav.logo)) }, modifier = Modifier.fillMaxWidth().height(72.dp), focusScale = 1.02f) {
                                    Text(fav.name, Modifier.align(Alignment.CenterStart).padding(horizontal = 20.dp), style = MaterialTheme.typography.titleMedium, color = AetherColors.OnBackground)
                                }
                            }
                        }
                    }
                }
            }
            LiveTab.ADDONS -> AddonChannels(onOpenDetail)
        }
    }

    if (showSettings) LiveTvSettingsDialog({ showSettings = false }, onPhone)

    info?.let { channel ->
        val ok = remember { FocusRequester() }
        val favorite = liveSettings.isFavorite(channel.id)
        AetherDialog(channel.name, { info = null }, width = 720.dp) {
            val upcoming = engine.liveTv.upcoming(channel, 6)
            if (upcoming.isEmpty()) Text("La guida non ha programmi per questo canale.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
            for (programme in upcoming) {
                Column(Modifier.padding(vertical = 4.dp)) {
                    Text("${time(programme.start)} – ${time(programme.stop)}  ${programme.title}", style = MaterialTheme.typography.titleSmall, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    programme.summary?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = AetherColors.OnSurfaceMuted, maxLines = 2, overflow = TextOverflow.Ellipsis) }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TvButton("Guarda", { info = null; play(channel) }, primary = true, focusRequester = ok)
                TvButton(if (favorite) "Togli dai preferiti" else "Aggiungi ai preferiti", { toggleFavorite(channel) })
                TvButton("Chiudi", { info = null })
            }
            RequestFocusOnce(ok)
        }
    }
}

private val clock = SimpleDateFormat("HH:mm", Locale.ITALY)
private fun time(millis: Long): String = synchronized(clock) { clock.format(Date(millis)) }

@Composable
private fun ChannelRow(channel: M3uChannel, current: TvProgramme?, next: TvProgramme?, now: Long, favorite: Boolean, onPlay: () -> Unit, onLong: () -> Unit) {
    FocusSurface(onClick = onPlay, onLongClick = onLong, modifier = Modifier.fillMaxWidth().height(84.dp), shape = RoundedCornerShape(14.dp), focusScale = 1.02f, testTag = "live.channel") {
        Row(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.size(width = 96.dp, height = 56.dp).clip(RoundedCornerShape(10.dp)).background(AetherColors.Surface), contentAlignment = Alignment.Center) {
                RemoteImage(channel.logo, channel.name, Modifier.fillMaxSize().padding(6.dp), contentScale = ContentScale.Fit)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(channel.name, style = MaterialTheme.typography.titleMedium, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (favorite) Badge("Preferito", color = LocalAccent.current.copy(alpha = 0.3f))
                    channel.group?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1) }
                }
                if (current != null) {
                    Text("Ora: ${current.title}", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    ProgressLine(current.progress(now), Modifier.width(320.dp))
                } else {
                    Text("Nessuna informazione sui programmi", style = MaterialTheme.typography.bodySmall, color = AetherColors.OnSurfaceFaint)
                }
            }
            next?.let { Text("Dopo, ${time(it.start)}: ${it.title}", style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceFaint, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.width(260.dp)) }
        }
    }
}

/** The guide as a grid: channels down the side, half-hour columns across, the programmes as focusable blocks. */
@Composable
private fun GuideGrid(channels: List<M3uChannel>, now: Long, programmes: (M3uChannel) -> List<TvProgramme>, onPlay: (M3uChannel) -> Unit) {
    val start = now - (now % (30 * 60_000))
    val end = start + 4 * 3_600_000L
    val perMinute = 6.dp
    val scroll = rememberScrollState()
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(start = 180.dp).horizontalScroll(scroll)) {
            var t = start
            while (t < end) {
                Text(time(t), Modifier.width(perMinute * 30), style = MaterialTheme.typography.labelLarge, color = AetherColors.OnSurfaceMuted)
                t += 30 * 60_000
            }
        }
        Spacer(Modifier.height(6.dp))
        LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp), contentPadding = PaddingValues(bottom = 48.dp)) {
            items(channels, key = { it.id }) { channel ->
                Row(Modifier.height(64.dp), verticalAlignment = Alignment.CenterVertically) {
                    Row(Modifier.width(180.dp).fillMaxHeight(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        RemoteImage(channel.logo, channel.name, Modifier.size(width = 56.dp, height = 36.dp), contentScale = ContentScale.Fit)
                        Text(channel.name, style = MaterialTheme.typography.labelLarge, color = AetherColors.OnBackground, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(end = 8.dp))
                    }
                    Box(Modifier.horizontalScroll(scroll).width(perMinute * ((end - start) / 60_000).toInt()).fillMaxHeight()) {
                        for (p in programmes(channel)) {
                            val from = maxOf(p.start, start)
                            val to = minOf(p.stop, end)
                            if (to <= from) continue
                            val offset = perMinute * ((from - start) / 60_000).toInt()
                            val width = perMinute * ((to - from) / 60_000).toInt().coerceAtLeast(4)
                            val on = p.isOn(now)
                            FocusSurface(
                                onClick = { onPlay(channel) },
                                modifier = Modifier.offset(x = offset).width(width - 4.dp).fillMaxHeight(),
                                shape = RoundedCornerShape(8.dp), focusScale = 1.0f,
                                containerColor = if (on) LocalAccent.current.copy(alpha = 0.22f) else AetherColors.SurfaceRaised,
                            ) {
                                Column(Modifier.fillMaxSize().padding(horizontal = 8.dp, vertical = 4.dp), verticalArrangement = Arrangement.Center) {
                                    Text(p.title, style = MaterialTheme.typography.labelLarge, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text("${time(p.start)} – ${time(p.stop)}", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** The «tv» catalogs of the installed addons (and those the viewer marked as live), as rows of channels. */
@Composable
private fun AddonChannels(onOpenDetail: (MetaItem) -> Unit) {
    val engine = LocalContext.current.aether
    val settings by engine.settings.value.collectAsState()
    var rows by remember { mutableStateOf<List<Pair<CatalogRef, List<MetaItem>>>?>(null) }
    LaunchedEffect(settings.liveTv.includedCatalogs, settings.liveTv.excludedCatalogs) {
        val refs = RequestPlanner.feedCatalogs(engine.registry.handles()).filter { settings.liveTv.includes(it.id, it.type == "tv") }
        rows = refs.mapNotNull { ref -> runCatching { ref to engine.addons.catalog(ref).items }.getOrNull()?.takeIf { it.second.isNotEmpty() } }
    }
    val loaded = rows
    when {
        loaded == null -> LoadingState("Carico i canali degli addon…")
        loaded.isEmpty() -> EmptyState("Nessun canale dagli addon", "Nessun addon installato offre cataloghi di canali TV.", icon = Icons.Filled.LiveTv)
        else -> LazyColumn(verticalArrangement = Arrangement.spacedBy(18.dp), contentPadding = PaddingValues(bottom = 48.dp)) {
            items(loaded, key = { it.first.id }) { (ref, items) ->
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("${ref.title} · ${ref.addonName}", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground)
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(vertical = 8.dp)) {
                        items(items, key = { it.id }) { meta -> PosterCard(meta, { onOpenDetail(meta) }) }
                    }
                }
            }
        }
    }
}

/** Impostazioni ▸ TV in diretta: the playlists, the guide and the side-menu entry. */
@Composable
fun LiveTvSettingsDialog(onDismiss: () -> Unit, onPhone: () -> Unit) {
    val engine = LocalContext.current.aether
    val scope = rememberCoroutineScope()
    val settings by engine.settings.value.collectAsState()
    val live by engine.liveTv.state.collectAsState()
    var name by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("") }
    var guide by remember { mutableStateOf(settings.liveTv.guideUrl) }
    var message by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    val first = remember { FocusRequester() }
    AetherDialog("TV in diretta", onDismiss, width = 820.dp) {
        LazyColumn(Modifier.height(560.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvChip(if (settings.liveTv.showTab) "Nel menu: sì" else "Nel menu: no", settings.liveTv.showTab, { engine.settings.update { it.copy(liveTv = it.liveTv.copy(showTab = !it.liveTv.showTab)) } }, focusRequester = first)
                    TvChip(if (settings.liveTv.guideEnabled) "Guida: accesa" else "Guida: spenta", settings.liveTv.guideEnabled, { engine.settings.update { it.copy(liveTv = it.liveTv.copy(guideEnabled = !it.liveTv.guideEnabled)) } })
                    TvChip("Guida: ${settings.liveTv.guideStyle.title}", false, {
                        engine.settings.update { it.copy(liveTv = it.liveTv.copy(guideStyle = if (it.liveTv.guideStyle == LiveGuideStyle.ROWS) LiveGuideStyle.GRID else LiveGuideStyle.ROWS)) }
                    })
                }
            }
            item { Text("Playlist", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground) }
            items(settings.liveTv.playlists, key = { it.id }) { playlist ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(playlist.name, style = MaterialTheme.typography.titleMedium, color = AetherColors.OnBackground)
                        Text("${live.channels[playlist.id]?.size ?: 0} canali" + (live.playlistErrors[playlist.id]?.let { " · $it" } ?: ""), style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted)
                    }
                    TvButton("Rimuovi", { scope.launch { engine.liveTv.removePlaylist(playlist.id) } })
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    TvTextField(name, { name = it }, "Nome della playlist (facoltativo)")
                    TvTextField(url, { url = it }, "Indirizzo M3U (https://…)")
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        TvButton(if (working) "Scarico…" else "Aggiungi", {
                            if (working) return@TvButton
                            working = true
                            scope.launch {
                                message = engine.liveTv.addPlaylist(name, url) ?: "Playlist aggiunta.".also { name = ""; url = "" }
                                working = false
                                engine.liveTv.refreshGuide()
                            }
                        }, primary = true, enabled = url.isNotBlank())
                        TvButton("Dal telefono", onPhone)
                        if (settings.liveTv.playlists.isNotEmpty()) TvButton("Aggiorna le playlist", { scope.launch { engine.liveTv.refreshPlaylists(); message = "Playlist aggiornate." } })
                    }
                }
            }
            item { Text("Guida dei programmi", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground) }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Vuoto: la guida che la playlist indica, altrimenti quella pubblica dei canali italiani. ${live.guideSource?.let { "In uso: ${it.substringAfter("://").substringBefore('/')}" } ?: ""}", style = MaterialTheme.typography.bodySmall, color = AetherColors.OnSurfaceMuted)
                    TvTextField(guide, { guide = it }, "Indirizzo XMLTV (.xml o .xml.gz)")
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        TvButton("Salva e aggiorna", { engine.settings.update { it.copy(liveTv = it.liveTv.copy(guideUrl = guide.trim())) }; scope.launch { engine.liveTv.refreshGuide(force = true); message = engine.liveTv.state.value.guideMessage ?: "Guida aggiornata." } })
                        TvButton("Cancella la guida", { scope.launch { engine.liveTv.clearGuide(); message = "Guida cancellata." } })
                    }
                }
            }
            message?.let { item { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted) } }
            item { TvButton("Fatto", onDismiss) }
        }
        RequestFocusOnce(first)
    }
}
