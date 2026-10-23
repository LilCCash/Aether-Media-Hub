package app.aether.tv.ui.screens.detail

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SmartDisplay
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import app.aether.core.AetherEngine
import app.aether.core.addons.AddonClient
import app.aether.core.addons.RequestPlanner
import app.aether.core.library.PlaybackProgress
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.core.net.AddonError
import app.aether.tv.Session
import app.aether.tv.aether
import app.aether.tv.ui.components.ErrorState
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.ProgressLine
import app.aether.tv.ui.components.RemoteImage
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.components.TvIconButton
import app.aether.tv.ui.components.factsLine
import app.aether.tv.ui.components.formatDuration
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.backdropScrimHorizontal
import app.aether.tv.ui.theme.backdropScrimVertical
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class DetailViewModel(private val engine: AetherEngine, private val type: String, private val id: String) : ViewModel() {
    data class UiState(
        val meta: MetaItem,
        val loading: Boolean = true,
        val error: String? = null,
        val provider: String? = null,
        val canPlay: Boolean = true,
        val season: Int? = null,
        val progress: Map<String, PlaybackProgress> = emptyMap(),
        val watched: Set<String> = emptySet(),
        val inWatchlist: Boolean = false,
        val favorite: Boolean = false,
        val primary: Video? = null,
    )

    private val _state = MutableStateFlow(UiState(Session.preview(type, id) ?: MetaItem(id, type, id)))
    val state: StateFlow<UiState> get() = _state

    init {
        load()
        viewModelScope.launch { engine.library.revision.collect { refreshLibrary() } }
    }

    fun load(mode: AddonClient.LoadMode = AddonClient.LoadMode.NORMAL) {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            try {
                val resolution = engine.addons.meta(type, id, Session.preview(type, id), mode)
                val handles = engine.addons.handles()
                val playableId = resolution.meta.videos.firstOrNull()?.id ?: resolution.meta.id
                val error = if (!resolution.hadDetailProvider && Session.preview(type, id) == null) "Nessun addon fornisce i dettagli di questo titolo." else null
                _state.update {
                    it.copy(
                        meta = resolution.meta, loading = false, provider = resolution.providerName, error = error,
                        canPlay = RequestPlanner.canProvideStreams(resolution.meta.type, playableId, handles),
                    )
                }
                refreshLibrary()
            } catch (error: Throwable) {
                if (error is kotlin.coroutines.cancellation.CancellationException) throw error
                _state.update { it.copy(loading = false, error = AddonError.from(error).message) }
            }
        }
    }

    private fun refreshLibrary() {
        _state.update { s ->
            val meta = s.meta
            val progress = engine.library.progressFor(meta.id)
            val primary = if (meta.hasEpisodes) engine.library.episodeToPlay(meta) else null
            val season = s.season ?: primary?.season ?: meta.seasons.firstOrNull { it != 0 } ?: meta.seasons.firstOrNull()
            s.copy(
                progress = progress, watched = engine.library.watchedVideoIds(meta.id), primary = primary, season = season,
                inWatchlist = engine.library.isInWatchlist(meta.id), favorite = engine.library.isFavorite(meta.id),
            )
        }
    }

    fun selectSeason(season: Int) = _state.update { it.copy(season = season) }
    fun toggleWatchlist() { val s = _state.value; engine.library.setWatchlist(!s.inWatchlist, s.meta) }
    fun toggleFavorite() { val s = _state.value; engine.library.setFavorite(!s.favorite, s.meta) }

    fun toggleWatched(video: Video?) {
        val s = _state.value
        val key = video?.id ?: s.meta.id
        engine.library.markWatched(key !in s.watched, s.meta, listOf(video))
    }

    fun markSeason(season: Int, watched: Boolean) {
        val s = _state.value
        engine.library.markWatched(watched, s.meta, s.meta.videos(season))
    }
}

@Composable
fun DetailScreen(type: String, id: String, onPlay: (MetaItem, Video?, Double?) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val engine = context.aether
    val vm: DetailViewModel = viewModel(key = "detail/$type/$id") { DetailViewModel(engine, type, id) }
    val state by vm.state.collectAsStateWithLifecycle()
    val meta = state.meta
    val primaryRequester = remember { FocusRequester() }
    val listState = rememberLazyListState()
    if (!state.loading) RequestFocusOnce(primaryRequester, meta.id)

    val primaryVideo = if (meta.hasEpisodes) state.primary else null
    val primaryProgress = state.progress[primaryVideo?.id ?: meta.id]
    val resume = primaryProgress?.takeIf { !it.isCompleted && it.position >= 10 }
    val playLabel = buildString {
        append(if (resume != null) "Riprendi" else "Guarda")
        primaryVideo?.episodeLabel?.let { append(" ").append(it) }
    }

    Box(modifier.fillMaxSize()) {
        RemoteImage(meta.background ?: meta.poster, meta.name, Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().background(backdropScrimHorizontal()))
        Box(Modifier.fillMaxSize().background(backdropScrimVertical()))
        if (state.loading && meta.name == meta.id) {
            LoadingState("Carico i dettagli…", Modifier.align(Alignment.Center))
        } else if (state.error != null && meta.name == meta.id) {
            ErrorState(state.error ?: "", { vm.load(AddonClient.LoadMode.RELOAD) }, Modifier.align(Alignment.Center))
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(top = 36.dp, bottom = 60.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                item(key = "header") {
                    Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal).width(640.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(RequestPlanner.friendlyTypeName(meta.type).uppercase(), style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted)
                        Text(meta.name, style = MaterialTheme.typography.displayMedium, color = AetherColors.OnBackground, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        meta.factsLine().takeIf { it.isNotEmpty() }?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted) }
                        meta.description?.takeIf { it.isNotBlank() }?.let {
                            Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground.copy(alpha = 0.88f), maxLines = 5, overflow = TextOverflow.Ellipsis)
                        }
                        if (resume != null) Column(Modifier.width(320.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            ProgressLine(resume.fraction)
                            Text("Ti sei fermato a ${formatDuration(resume.position)}", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted)
                        }
                        if (!state.canPlay && !state.loading) Text("Nessun addon attivo fornisce sorgenti per questo titolo.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.Warning)
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 6.dp)) {
                            TvButton(
                                playLabel,
                                { onPlay(meta, primaryVideo, resume?.position) },
                                icon = Icons.Filled.PlayArrow,
                                primary = true,
                                enabled = state.canPlay && (!meta.hasEpisodes || primaryVideo != null),
                                focusRequester = primaryRequester,
                                testTag = "detail.play",
                            )
                            TvIconButton(if (state.inWatchlist) Icons.Filled.Check else Icons.Filled.Add, if (state.inWatchlist) "Rimuovi dalla watchlist" else "Aggiungi alla watchlist", vm::toggleWatchlist, active = state.inWatchlist, testTag = "detail.watchlist")
                            TvIconButton(if (state.favorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, if (state.favorite) "Rimuovi dai preferiti" else "Aggiungi ai preferiti", vm::toggleFavorite, active = state.favorite, testTag = "detail.favorite")
                            if (!meta.hasEpisodes) {
                                val watched = meta.id in state.watched
                                TvIconButton(if (watched) Icons.Filled.VisibilityOff else Icons.Filled.Visibility, if (watched) "Segna come non visto" else "Segna come visto", { vm.toggleWatched(null) }, active = watched, testTag = "detail.watched")
                            }
                            meta.trailers.firstOrNull()?.let { trailer ->
                                TvIconButton(Icons.Filled.SmartDisplay, "Guarda il trailer", {
                                    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(trailer.watchUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                                }, testTag = "detail.trailer")
                            }
                        }
                    }
                }
                if (meta.hasEpisodes) {
                    item(key = "episodes") {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            LazyRow(contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                items(meta.seasons.size, key = { meta.seasons[it] }) { i ->
                                    val season = meta.seasons[i]
                                    TvChip(if (season == 0) "Speciali" else "Stagione $season", state.season == season, { vm.selectSeason(season) }, testTag = "detail.season.$season")
                                }
                            }
                            val episodes = state.season?.let { meta.videos(it) }.orEmpty()
                            val seasonKey = state.season
                            LazyRow(contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                items(episodes.size, key = { "${seasonKey}-${episodes[it].id}" }) { i ->
                                    val video = episodes[i]
                                    EpisodeCard(
                                        video, progress = state.progress[video.id], watched = video.id in state.watched,
                                        onClick = { onPlay(meta, video, state.progress[video.id]?.takeIf { p -> !p.isCompleted && p.position >= 10 }?.position) },
                                        onLongClick = { vm.toggleWatched(video) },
                                    )
                                }
                            }
                            state.season?.let { season ->
                                Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    TvChip("Segna la stagione come vista", false, { vm.markSeason(season, true) }, testTag = "detail.markSeason")
                                    TvChip("Segna come non vista", false, { vm.markSeason(season, false) })
                                }
                                Text("Tieni premuto OK su un episodio per segnarlo come visto o non visto.", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
                            }
                        }
                    }
                }
                item(key = "credits") {
                    Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal).fillMaxWidth(0.8f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        InfoLine("Cast", meta.cast.take(10))
                        InfoLine("Regia", meta.directors)
                        InfoLine("Sceneggiatura", meta.writers)
                        InfoLine("Generi", meta.genres)
                        InfoLine("Lingua", listOfNotNull(meta.language))
                        InfoLine("Paese", listOfNotNull(meta.country))
                        InfoLine("Premi", listOfNotNull(meta.awards))
                        state.provider?.let { Text("Dettagli forniti da $it", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, modifier = Modifier.padding(top = 8.dp)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun InfoLine(label: String, values: List<String>) {
    if (values.isEmpty()) return
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, Modifier.width(120.dp), style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceFaint)
        Text(values.joinToString(", "), style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground.copy(alpha = 0.9f))
    }
}

@Composable
private fun EpisodeCard(video: Video, progress: PlaybackProgress?, watched: Boolean, onClick: () -> Unit, onLongClick: () -> Unit) {
    Column(Modifier.width(240.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FocusSurface(onClick = onClick, onLongClick = onLongClick, enabled = !video.isFuture, modifier = Modifier.fillMaxWidth().height(135.dp), testTag = "episode.${video.id}") {
            RemoteImage(video.thumbnail, video.id, Modifier.fillMaxSize())
            if (watched) Box(Modifier.align(Alignment.TopEnd).padding(6.dp).background(Color0, androidx.compose.foundation.shape.CircleShape).padding(4.dp)) {
                androidx.compose.material3.Icon(Icons.Filled.Check, "Visto", tint = AetherColors.Success, modifier = Modifier.width(16.dp).height(16.dp))
            }
            if (progress != null && !progress.isCompleted && progress.fraction > 0) ProgressLine(progress.fraction, Modifier.align(Alignment.BottomCenter).padding(8.dp))
        }
        Text("${video.episode?.let { "$it. " }.orEmpty()}${video.title.ifBlank { "Episodio" }}", style = MaterialTheme.typography.labelLarge, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (video.isFuture) Text("Non ancora uscito", style = MaterialTheme.typography.labelSmall, color = AetherColors.Warning)
        else video.overview?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 2, overflow = TextOverflow.Ellipsis) }
    }
}

private val Color0 = androidx.compose.ui.graphics.Color(0xCC0B0A12)
