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
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
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
import app.aether.tv.ui.components.ContentRow
import app.aether.tv.ui.components.PosterCard
import androidx.compose.foundation.layout.aspectRatio
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
        val rich: app.aether.core.metadata.RichDetails? = null,
        /** IMDb, Rotten Tomatoes, Metacritic… from MDBList, when the viewer set a key. */
        val ratings: List<app.aether.core.metadata.MdbRating> = emptyList(),
        val collection: app.aether.core.metadata.RichDetails.Collection? = null,
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
                val meta = engine.metadata.enrich(resolution.meta)
                val handles = engine.addons.handles()
                val playableId = meta.videos.firstOrNull()?.id ?: meta.id
                val error = if (!resolution.hadDetailProvider && Session.preview(type, id) == null) "Nessun addon fornisce i dettagli di questo titolo." else null
                _state.update {
                    it.copy(
                        meta = meta, loading = false, provider = resolution.providerName, error = error,
                        canPlay = RequestPlanner.canProvideStreams(meta.type, playableId, handles),
                    )
                }
                refreshLibrary()
                val rich = engine.metadata.rich(meta)
                _state.update { it.copy(rich = rich) }
                rich?.collectionId?.let { cid -> launch { val c = engine.metadata.collection(cid); _state.update { it.copy(collection = c?.takeIf { x -> x.parts.size > 1 }) } } }
                val tmdb = rich?.tmdbId ?: meta.externalIds.tmdb
                if (tmdb != null && engine.mdbList.isConfigured) {
                    val ratings = engine.mdbList.ratings(tmdb, isMovie = meta.type == "movie")
                    _state.update { it.copy(ratings = ratings) }
                }
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

    /** Opens a similar title: TMDB only knows its own id, so the IMDb id is asked first. */
    fun openSimilar(similar: app.aether.core.metadata.RichDetails.Similar, open: (String, String) -> Unit) {
        viewModelScope.launch {
            val imdb = engine.metadata.imdbIdFor(similar) ?: return@launch
            open(if (similar.isMovie) "movie" else "series", imdb)
        }
    }

    /** A name of the addon's cast (no TMDB id): the person is looked up by name, the best known match is opened. */
    fun openPersonByName(name: String, open: (Int, String) -> Unit) {
        viewModelScope.launch {
            val found = engine.metadata.searchPeople(name, limit = 1).firstOrNull() ?: return@launch
            open(found.id, found.name)
        }
    }

    fun openPart(part: app.aether.core.metadata.RichDetails.Part, open: (String, String) -> Unit) {
        viewModelScope.launch { engine.metadata.imdbIdFor(part.tmdbId, true)?.let { open("movie", it) } }
    }

    fun selectSeason(season: Int) = _state.update { it.copy(season = season) }
    fun toggleWatchlist() { val s = _state.value; engine.library.setWatchlist(!s.inWatchlist, s.meta); engine.trakt.watchlistChanged(s.meta, !s.inWatchlist) }
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

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun DetailScreen(type: String, id: String, onPlay: (MetaItem, Video?, Double?) -> Unit, onOpenTitle: (String, String) -> Unit = { _, _ -> }, onOpenPerson: (Int, String) -> Unit = { _, _ -> }, modifier: Modifier = Modifier, onOpenUniverse: (String) -> Unit = {}) {
    val context = LocalContext.current
    val engine = context.aether
    val vm: DetailViewModel = viewModel(key = "detail/$type/$id") { DetailViewModel(engine, type, id) }
    val state by vm.state.collectAsStateWithLifecycle()
    val meta = state.meta
    val primaryRequester = remember { FocusRequester() }
    var opened by remember { mutableStateOf<Pair<String, String>?>(null) }
    val listState = rememberLazyListState()
    val appearance = engine.settings.value.collectAsStateWithLifecycle().value.appearance
    val sections = remember(appearance.detailSectionOrder, appearance.hiddenDetailSections) { app.aether.core.settings.DetailSections.ordered(appearance.detailSectionOrder, appearance.hiddenDetailSections) }
    if (!state.loading) RequestFocusOnce(primaryRequester, meta.id)

    val primaryVideo = if (meta.hasEpisodes) state.primary else null
    val primaryProgress = state.progress[primaryVideo?.id ?: meta.id]
    val resume = primaryProgress?.takeIf { !it.isCompleted && it.position >= 10 }
    val playLabel = buildString {
        append(if (resume != null) "Riprendi" else "Guarda")
        primaryVideo?.episodeLabel?.let { append(" ").append(it) }
    }

    opened?.let { (title, text) ->
        app.aether.tv.ui.components.AetherDialog(title, { opened = null }, width = 760.dp) {
            Text(text, style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
            val close = remember { FocusRequester() }
            TvButton("Chiudi", { opened = null }, primary = true, focusRequester = close)
            RequestFocusOnce(close)
        }
    }
    var diaryOpen by remember { mutableStateOf(false) }
    var collectionsOpen by remember { mutableStateOf(false) }
    if (diaryOpen) {
        val video = if (meta.hasEpisodes) state.primary else null
        app.aether.tv.ui.screens.profile.DiaryEditor(
            app.aether.core.library.DiaryEntry(
                metaId = meta.id, type = meta.type, name = meta.name, poster = meta.poster, year = meta.releaseInfo, genres = meta.genres,
                runtimeMinutes = state.rich?.runtimeMinutes ?: meta.runtime?.filter { it.isDigit() }?.toIntOrNull(), people = meta.directors + meta.cast.take(4),
                episodeLabel = video?.episodeLabel, publicRating = meta.imdbRating?.replace(',', '.')?.toDoubleOrNull() ?: state.rich?.voteAverage,
            ),
            onSave = { engine.library.saveDiary(it); diaryOpen = false }, onDelete = null,
        ) { diaryOpen = false }
    }
    if (collectionsOpen) CollectionsDialog(meta) { collectionsOpen = false }
    val graphics = app.aether.tv.ui.theme.LocalGraphics.current
    // The backdrop scrolls away with the header (tvOS: the picture belongs to the first page of the title).
    val headerGone = listState.firstVisibleItemIndex > 0
    val backdropAlpha by androidx.compose.animation.core.animateFloatAsState(if (headerGone) 0.35f else 1f, androidx.compose.animation.core.tween(graphics.ms(400)), label = "backdrop")
    Box(modifier.fillMaxSize()) {
        if (graphics.backdropArt) {
            RemoteImage(meta.background ?: meta.poster, meta.name, Modifier.fillMaxSize().then(if (graphics.blur && headerGone) Modifier.blur(30.dp) else Modifier).graphicsLayer { alpha = backdropAlpha }, alignment = androidx.compose.ui.BiasAlignment(0.3f, -0.4f))
            Box(Modifier.fillMaxSize().background(backdropScrimHorizontal()))
            Box(Modifier.fillMaxSize().background(backdropScrimVertical()))
        }
        if (state.loading && meta.name == meta.id) {
            LoadingState("Carico i dettagli…", Modifier.align(Alignment.Center))
        } else if (state.error != null && meta.name == meta.id) {
            ErrorState(state.error ?: "", { vm.load(AddonClient.LoadMode.RELOAD) }, Modifier.align(Alignment.Center))
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = 60.dp),
                verticalArrangement = Arrangement.spacedBy(22.dp),
            ) {
                item(key = "header") {
                    Box(Modifier.fillParentMaxHeight(0.9f).fillMaxWidth()) {
                    Column(Modifier.align(Alignment.BottomStart).padding(horizontal = AetherDimens.ScreenHorizontal).width(680.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(RequestPlanner.friendlyTypeName(meta.type).uppercase(), style = MaterialTheme.typography.labelMedium, color = AetherColors.OnBackground.copy(alpha = 0.7f))
                        val logo = meta.logo
                        if (!logo.isNullOrBlank()) {
                            coil3.compose.AsyncImage(logo, meta.name, Modifier.height(120.dp).width(460.dp), alignment = Alignment.CenterStart, contentScale = androidx.compose.ui.layout.ContentScale.Fit)
                        } else {
                            Text(meta.name, style = MaterialTheme.typography.displayMedium, color = AetherColors.OnBackground, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                        state.rich?.tagline?.let { Text("«$it»", style = MaterialTheme.typography.titleSmall.copy(fontStyle = androidx.compose.ui.text.font.FontStyle.Italic), color = app.aether.tv.ui.theme.LocalAccent.current, maxLines = 2, overflow = TextOverflow.Ellipsis) }
                        val pills = buildList {
                            meta.releaseInfo?.takeIf { it.isNotBlank() }?.let { add(it) }
                            (state.rich?.runtimeMinutes?.let { m -> if (m >= 60) "${m / 60} h ${m % 60} min" else "$m min" } ?: meta.runtime)?.let { add(it) }
                            (meta.imdbRating?.takeIf { it.isNotBlank() } ?: state.rich?.voteAverage?.let { "%.1f".format(java.util.Locale.ITALY, it) })?.let { add("★ $it") }
                            if (meta.hasEpisodes) state.rich?.seasonCount?.let { add(if (it == 1) "1 stagione" else "$it stagioni") }
                        }
                        if (pills.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { pills.forEach { app.aether.tv.ui.components.Badge(it) } }
                        if (meta.genres.isNotEmpty()) Text(meta.genres.take(4).joinToString("  ·  "), style = MaterialTheme.typography.labelLarge, color = AetherColors.OnBackground.copy(alpha = 0.75f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        meta.description?.takeIf { it.isNotBlank() }?.let { plot ->
                            FocusSurface({ opened = "Trama" to plot }, Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp), focusScale = 1.02f, containerColor = Color.Transparent, focusedContainerColor = Color(0x26FFFFFF)) {
                                Text(plot, Modifier.padding(horizontal = 6.dp, vertical = 4.dp), style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground.copy(alpha = 0.88f), maxLines = 4, overflow = TextOverflow.Ellipsis)
                            }
                        }
                        if (resume != null) Column(Modifier.width(320.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            ProgressLine(resume.fraction)
                            Text("Ti sei fermato a ${formatDuration(resume.position)}", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted)
                        }
                        val universes = remember(meta.id, meta.externalIds.imdb) { app.aether.core.universe.UniverseCatalog.containing(meta.externalIds.imdb ?: meta.id) }
                        if (universes.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            universes.forEach { u -> TvChip("Universo · ${u.name}", false, { onOpenUniverse(u.id) }, testTag = "detail.universe.${u.id}") }
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
                            TvIconButton(Icons.Filled.EditNote, "Segna nel diario", { diaryOpen = true }, testTag = "detail.diary")
                            TvIconButton(Icons.AutoMirrored.Filled.PlaylistAdd, "Aggiungi a una collezione", { collectionsOpen = true }, testTag = "detail.collections")
                            meta.trailers.firstOrNull()?.let { trailer ->
                                TvIconButton(Icons.Filled.SmartDisplay, "Guarda il trailer", {
                                    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(trailer.watchUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                                }, testTag = "detail.trailer")
                            }
                        }
                    }
                    }
                }
                val r = state.rich
                val open: (String, String) -> Unit = { l, t -> opened = l to t }
                for (section in sections) when (section) {
                    "episodes" -> if (meta.hasEpisodes) item(key = "episodes") {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            app.aether.tv.ui.components.SectionTitle("Episodi", Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
                            LazyRow(contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                items(meta.seasons.size, key = { "$it|" + meta.seasons[it] }) { i ->
                                    val season = meta.seasons[i]
                                    TvChip(if (season == 0) "Speciali" else "Stagione $season", state.season == season, { vm.selectSeason(season) }, testTag = "detail.season.$season")
                                }
                            }
                            val episodes = state.season?.let { meta.videos(it) }.orEmpty()
                            val seasonKey = state.season
                            androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides app.aether.tv.ui.theme.EdgeScroll) {
                                LazyRow(contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                                    items(episodes.size, key = { "${seasonKey}-$it-${episodes[it].id}" }) { i ->
                                        val video = episodes[i]
                                        EpisodeCard(
                                            video, progress = state.progress[video.id], watched = video.id in state.watched,
                                            onClick = { onPlay(meta, video, state.progress[video.id]?.takeIf { p -> !p.isCompleted && p.position >= 10 }?.position) },
                                            onLongClick = { vm.toggleWatched(video) },
                                        )
                                    }
                                }
                            }
                            val seasonStatus by app.aether.tv.downloads.SeasonDownloader.status.collectAsStateWithLifecycle()
                            seasonStatus?.takeIf { it.title.startsWith(meta.name) }?.let { st ->
                                Text(st.message + if (st.running) " (${st.done + st.skipped}/${st.total})" else "", style = MaterialTheme.typography.labelMedium, color = if (st.running) app.aether.tv.ui.theme.LocalAccent.current else AetherColors.OnSurfaceMuted, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), maxLines = 2)
                            }
                            state.season?.let { season ->
                                Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                                    TvChip("Segna la stagione come vista", false, { vm.markSeason(season, true) }, testTag = "detail.markSeason")
                                    TvChip("Segna come non vista", false, { vm.markSeason(season, false) })
                                    TvChip("Scarica la stagione", false, { app.aether.tv.downloads.SeasonDownloader.start(context, engine, meta, season, meta.videos(season)) }, testTag = "detail.downloadSeason")
                                    Text("Tieni premuto OK su un episodio per segnarlo come visto.", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }
                    "cast" -> {
                        if (r != null && r.cast.isNotEmpty()) item(key = "cast") {
                            ContentRow("Cast", r.cast, { it.name + it.role.orEmpty() }, rowId = "cast") { person, requester, onFocused ->
                                app.aether.tv.ui.components.PersonBubble(person.name, person.photo, person.role, requester, onFocused, testTag = "detail.cast.${person.name}") { person.id?.let { onOpenPerson(it, person.name) } ?: vm.openPersonByName(person.name, onOpenPerson) }
                            }
                        } else if (meta.cast.isNotEmpty()) item(key = "cast") {
                            ContentRow("Cast", meta.cast.distinct().take(20), { it }, rowId = "cast") { name, requester, onFocused ->
                                app.aether.tv.ui.components.PersonBubble(name, null, null, requester, onFocused, testTag = "detail.cast.$name") { vm.openPersonByName(name, onOpenPerson) }
                            }
                        }
                    }
                    "collection" -> state.collection?.let { c ->
                        item(key = "collection") {
                            ContentRow(c.name, c.parts, { "${it.tmdbId}" }, rowId = "collection") { part, requester, onFocused ->
                                PosterCard(
                                    MetaItem("tmdb:${part.tmdbId}", "movie", part.title, poster = part.poster, background = part.backdrop, releaseInfo = part.year),
                                    { vm.openPart(part, onOpenTitle) }, focusRequester = requester, onFocused = onFocused, testTag = "detail.saga.${part.tmdbId}",
                                    badge = if (part.tmdbId == r?.tmdbId) "Questo" else null,
                                )
                            }
                        }
                    }
                    "ratings" -> if (state.ratings.isNotEmpty()) item(key = "ratings") {
                        Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            app.aether.tv.ui.components.SectionTitle("Voti")
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                for (rating in state.ratings.take(8)) RatingTile(rating.title.orEmpty(), rating.display.orEmpty())
                            }
                        }
                    }
                    "info" -> item(key = "credits") {
                        Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal - 6.dp).fillMaxWidth(0.8f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            app.aether.tv.ui.components.SectionTitle("Dettagli", Modifier.padding(start = 6.dp, bottom = 6.dp))
                            InfoLine("Regia", meta.directors.ifEmpty { r?.directors.orEmpty() }, open)
                            InfoLine("Creato da", r?.creators.orEmpty(), open)
                            InfoLine("Sceneggiatura", meta.writers, open)
                            InfoLine("Generi", meta.genres, open)
                            InfoLine("Uscita", listOfNotNull(r?.releaseDate?.let(::italianDate) ?: meta.releaseInfo), open)
                            InfoLine("Durata", listOfNotNull(r?.runtimeMinutes?.let { "${it / 60} h ${it % 60} min".removePrefix("0 h ") } ?: meta.runtime), open)
                            InfoLine("Lingua", listOfNotNull(meta.language), open)
                            InfoLine("Paese", if (meta.country != null) listOf(meta.country!!) else r?.countries.orEmpty(), open)
                            InfoLine("Premi", listOfNotNull(meta.awards), open)
                            if (r != null) {
                                InfoLine("Produzione", r.companies, open)
                                InfoLine("Stato", listOfNotNull(r.status), open)
                                InfoLine("Lingua originale", listOfNotNull(r.originalLanguage?.let { app.aether.core.playback.Languages.displayName(it) }), open)
                                if (r.seasonCount != null) InfoLine("Stagioni", listOfNotNull("${r.seasonCount}" + (r.episodeCount?.let { " · $it episodi" } ?: "")), open)
                                InfoLine("Budget", listOfNotNull(r.budget?.let(::money)), open)
                                InfoLine("Incassi", listOfNotNull(r.revenue?.let(::money)), open)
                                InfoLine("Parole chiave", r.keywords, open)
                            }
                            state.provider?.let { Text("Dettagli forniti da $it · premi OK su una voce per leggerla intera", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, modifier = Modifier.padding(start = 6.dp, top = 8.dp)) }
                        }
                    }
                    "crew" -> if (r != null && r.crew.isNotEmpty()) item(key = "crew") {
                        ContentRow("Dietro la macchina da presa", r.crew, { it.name + it.role.orEmpty() }, rowId = "crew") { person, requester, onFocused ->
                            app.aether.tv.ui.components.PersonBubble(person.name, person.photo, person.role, requester, onFocused) { person.id?.let { onOpenPerson(it, person.name) } }
                        }
                    }
                    "trailers" -> if (r != null && r.trailers.isNotEmpty()) item(key = "trailers") {
                        Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            app.aether.tv.ui.components.SectionTitle("Trailer")
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                r.trailers.forEachIndexed { i, t ->
                                    TvChip("${if (t.type == "Teaser") "Teaser" else "Trailer"} ${i + 1}", false, {
                                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(t.watchUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                                    }, testTag = "detail.richTrailer.$i")
                                }
                            }
                        }
                    }
                    "similar" -> if (r != null && r.similar.isNotEmpty()) item(key = "similar") {
                        ContentRow("Titoli simili", r.similar, { "${it.tmdbId}" }, rowId = "similar") { sim, requester, onFocused ->
                            PosterCard(
                                MetaItem("tmdb:${sim.tmdbId}", if (sim.isMovie) "movie" else "series", sim.title, poster = sim.poster, releaseInfo = sim.year),
                                { vm.openSimilar(sim, onOpenTitle) }, focusRequester = requester, onFocused = onFocused, testTag = "detail.similar.${sim.tmdbId}",
                            )
                        }
                    }
                }
            }
        }
    }
}

/** «Aggiungi a una collezione»: every list with a check where the title is, and a new list made on the spot. */
@Composable
private fun CollectionsDialog(meta: MetaItem, onDismiss: () -> Unit) {
    val engine = LocalContext.current.aether
    val revision by engine.library.revision.collectAsStateWithLifecycle()
    val lists = remember(revision) { engine.library.collections() }
    var name by remember { mutableStateOf("") }
    val first = remember { FocusRequester() }
    app.aether.tv.ui.components.AetherDialog("Aggiungi a una collezione", onDismiss, width = 640.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            lists.forEachIndexed { i, c ->
                val inside = c.items.any { it.id == meta.id }
                TvChip((if (inside) "✓ " else "") + c.name + " · ${c.items.size}", inside, { engine.library.toggleInCollection(c.id, meta) }, focusRequester = if (i == 0) first else null, testTag = "collection.$i")
            }
            if (lists.isEmpty()) Text("Non hai ancora collezioni: creane una qui sotto.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
            app.aether.tv.ui.components.TvTextField(name, { name = it.take(40) }, "Nuova collezione", Modifier.fillMaxWidth(), focusRequester = if (lists.isEmpty()) first else null, onImeAction = {
                engine.library.createCollection(name)?.let { engine.library.toggleInCollection(it.id, meta) }; name = ""
            })
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TvButton("Crea e aggiungi", { engine.library.createCollection(name)?.let { engine.library.toggleInCollection(it.id, meta) }; name = "" }, enabled = name.isNotBlank())
                TvButton("Fatto", onDismiss, primary = true)
            }
        }
        RequestFocusOnce(first)
    }
}

private fun italianDate(iso: String): String = runCatching { java.time.LocalDate.parse(iso).format(java.time.format.DateTimeFormatter.ofPattern("d MMMM yyyy", java.util.Locale.ITALIAN)) }.getOrDefault(iso)

@Composable
private fun RatingTile(source: String, value: String) {
    Column(
        Modifier.width(132.dp).background(Color(0x1AFFFFFF), RoundedCornerShape(16.dp)).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(value, style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground, maxLines = 1)
        Text(source, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private fun money(value: Long): String = if (value >= 1_000_000) "%.1f M$".format(java.util.Locale.ITALY, value / 1_000_000.0) else "%,d $".format(java.util.Locale.ITALY, value)

@Composable
private fun PersonCard(person: app.aether.core.metadata.RichDetails.Person, requester: FocusRequester?, onFocused: () -> Unit, onClick: () -> Unit) {
    Column(Modifier.width(120.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FocusSurface(onClick, Modifier.fillMaxWidth().aspectRatio(0.75f), focusRequester = requester, onFocused = onFocused) {
            RemoteImage(person.photo, person.name, Modifier.fillMaxSize())
        }
        Text(person.name, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
        person.role?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    }
}

@Composable
private fun InfoLine(label: String, values: List<String>, onOpen: (String, String) -> Unit) {
    if (values.isEmpty()) return
    val text = values.joinToString(", ")
    FocusSurface({ onOpen(label, text) }, Modifier.fillMaxWidth(), shape = RoundedCornerShape(10.dp), focusScale = 1.01f, containerColor = Color.Transparent) {
        Row(Modifier.padding(horizontal = 6.dp, vertical = 5.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(label, Modifier.width(150.dp), style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceFaint)
            Text(text, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground.copy(alpha = 0.9f), maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
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

private val Color0 = androidx.compose.ui.graphics.Color(0xCC0A0A0C)
