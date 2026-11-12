package app.aether.tv.ui.screens.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.aether.core.metadata.FilmographyEntry
import app.aether.core.metadata.PersonFilter
import app.aether.core.metadata.PersonProfile
import app.aether.core.metadata.PersonRole
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.LoadingState
import app.aether.tv.ui.components.RemoteImage
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent
import kotlinx.coroutines.launch

/**
 * A person's page, as on the iPhone: photo, life, profession, biography (OK reads it whole), the awards from Wikidata, then the whole
 * filmography with filters by role, kind, genre and decade. OK on a title opens its page.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun PersonScreen(personId: Int, name: String, onOpenTitle: (String, String) -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val scope = rememberCoroutineScope()
    var profile by remember { mutableStateOf<PersonProfile?>(null) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(personId) { profile = engine.metadata.personProfile(personId, name); loaded = true }
    var opening by remember { mutableStateOf(false) }
    var filter by remember { mutableStateOf(PersonFilter()) }
    var reading by remember { mutableStateOf(false) }
    val first = remember { FocusRequester() }
    val p = profile

    if (reading && p != null) {
        AetherDialog(p.name, { reading = false }, width = 820.dp) {
            Text(p.biography, style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
            val close = remember { FocusRequester() }
            TvButton("Chiudi", { reading = false }, primary = true, focusRequester = close)
            RequestFocusOnce(close)
        }
    }

    fun open(entry: FilmographyEntry) {
        if (opening) return
        scope.launch {
            opening = true
            val imdb = engine.metadata.imdbIdFor(entry.tmdbId, entry.isMovie)
            opening = false
            if (imdb != null) onOpenTitle(entry.metaType, imdb)
        }
    }

    when {
        !loaded -> LoadingState("Cerco $name…", modifier.fillMaxSize())
        p == null -> EmptyState(name, if (engine.metadata.hasTmdb) "TMDB non ha restituito informazioni su questa persona." else "Per le pagine delle persone serve la chiave TMDB (Impostazioni → Chiavi).", modifier.fillMaxSize())
        else -> {
            val shown = filter.apply(p.filmography)
            androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides app.aether.tv.ui.theme.GridScroll) {
                LazyVerticalGrid(
                    GridCells.Adaptive(150.dp), modifier.fillMaxSize(),
                    contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 12.dp, bottom = 72.dp),
                    horizontalArrangement = Arrangement.spacedBy(AetherDimens.RowSpacing), verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    item(key = "head", span = { GridItemSpan(maxLineSpan) }) { Header(p, first) { reading = true } }
                    if (p.awards.isNotEmpty()) item(key = "awards", span = { GridItemSpan(maxLineSpan) }) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            app.aether.tv.ui.components.SectionTitle("Premi e riconoscimenti")
                            @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
                            androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp), maxLines = 3) {
                                p.awards.forEach { AwardPill(it.line) }
                            }
                        }
                    }
                    item(key = "filters", span = { GridItemSpan(maxLineSpan) }) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            app.aether.tv.ui.components.SectionTitle(if (opening) "Apro la scheda…" else "Filmografia · ${shown.size} titoli")
                            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 6.dp)) {
                                item { TvChip("Tutto", filter == PersonFilter(), { filter = PersonFilter() }, testTag = "person.all") }
                                val roles = p.roles
                                if (roles.size > 1) items(roles.size) { i -> val r = roles[i]; TvChip(r.title, filter.role == r, { filter = filter.copy(role = if (filter.role == r) null else r) }) }
                                item { TvChip("Film", filter.onlyMovies == true, { filter = filter.copy(onlyMovies = if (filter.onlyMovies == true) null else true) }) }
                                item { TvChip("Serie", filter.onlyMovies == false, { filter = filter.copy(onlyMovies = if (filter.onlyMovies == false) null else false) }) }
                                val decades = PersonFilter.decades(p.filmography)
                                items(decades.size) { i -> val d = decades[i]; TvChip(if (d < 2000) "Anni ${d % 100}" else "Anni $d", filter.decade == d, { filter = filter.copy(decade = if (filter.decade == d) null else d) }) }
                                val genres = PersonFilter.genres(p.filmography)
                                items(genres.size) { i -> val g = genres[i]; TvChip(g, filter.genre == g, { filter = filter.copy(genre = if (filter.genre == g) null else g) }) }
                            }
                        }
                    }
                    if (shown.isEmpty()) item(key = "none", span = { GridItemSpan(maxLineSpan) }) {
                        Text("Nessun titolo con questi filtri.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
                    }
                    items(shown.size, key = { shown[it].key }) { i ->
                        val entry = shown[i]
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            FocusSurface({ open(entry) }, Modifier.fillMaxWidth().aspectRatio(0.675f), glow = true, testTag = "person.title.$i") {
                                RemoteImage(entry.poster, entry.title, Modifier.fillMaxSize())
                                entry.rating?.let { r ->
                                    Text("★ %.1f".format(java.util.Locale.ITALY, r), Modifier.align(Alignment.TopEnd).padding(6.dp).clip(RoundedCornerShape(8.dp)).background(Color(0xB3000000)).padding(horizontal = 6.dp, vertical = 2.dp), style = MaterialTheme.typography.labelSmall, color = Color.White)
                                }
                            }
                            Text(entry.title, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnBackground, maxLines = 2, minLines = 2, overflow = TextOverflow.Ellipsis)
                            val role = entry.character?.let { "nel ruolo di $it" } ?: entry.roles.filter { it != PersonRole.ACTOR }.joinToString { it.title }
                            Text(listOfNotNull(entry.year?.toString(), role.ifBlank { null }).joinToString(" · ").ifEmpty { " " }, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 2, minLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
            RequestFocusOnce(first, p.id)
        }
    }
}

@Composable
private fun Header(p: PersonProfile, first: FocusRequester, onRead: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(28.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.width(200.dp).aspectRatio(0.7f).clip(RoundedCornerShape(20.dp)).background(AetherColors.Surface)) {
            RemoteImage(p.photo, p.name, Modifier.fillMaxSize())
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(p.name, style = MaterialTheme.typography.displaySmall, color = AetherColors.OnBackground, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val facts = listOfNotNull(p.profession, p.lifeLine(), p.placeOfBirth).joinToString(" · ")
            if (facts.isNotEmpty()) Text(facts, style = MaterialTheme.typography.titleSmall, color = LocalAccent.current, maxLines = 2, overflow = TextOverflow.Ellipsis)
            FocusSurface(onRead, Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp), focusScale = 1.01f, containerColor = Color.Transparent, focusedContainerColor = Color(0x22FFFFFF), focusRequester = first, testTag = "person.bio") {
                Text(
                    p.biography.ifEmpty { "Nessuna biografia disponibile." }, Modifier.padding(10.dp),
                    style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground.copy(alpha = 0.85f), maxLines = 6, overflow = TextOverflow.Ellipsis,
                )
            }
            Text("${p.filmography.size} titoli · premi OK sulla biografia per leggerla intera", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint)
        }
    }
}

@Composable
private fun AwardPill(text: String) {
    Row(
        Modifier.height(40.dp).clip(RoundedCornerShape(20.dp)).background(Color(0x1FFFFFFF)).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("🏆", style = MaterialTheme.typography.labelLarge)
        Text(text, style = MaterialTheme.typography.labelLarge, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 520.dp))
    }
}
