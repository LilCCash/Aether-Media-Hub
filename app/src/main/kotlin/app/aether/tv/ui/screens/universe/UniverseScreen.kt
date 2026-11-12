package app.aether.tv.ui.screens.universe

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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.aether.core.model.MetaItem
import app.aether.core.universe.UniverseCatalog
import app.aether.core.universe.UniverseEntry
import app.aether.core.universe.UniverseOrder
import app.aether.core.universe.UniverseProgress
import app.aether.tv.aether
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.ProgressLine
import app.aether.tv.ui.components.RemoteImage
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.SectionTitle
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent

/**
 * An universe (a saga of cinema), as on the iPhone: what it is, how far the viewer is, what to watch next, and the map of its titles
 * along a line in the chosen order (release or story), each joined to the one before it, the watched ones marked.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun UniverseScreen(id: String, onOpenTitle: (String, String) -> Unit, onOpenUniverse: (String) -> Unit, modifier: Modifier = Modifier) {
    val engine = LocalContext.current.aether
    val universe = remember(id) { UniverseCatalog.universe(id) }
    if (universe == null) { EmptyState("Universo non trovato", "", modifier.fillMaxSize()); return }
    val settings by engine.settings.value.collectAsStateWithLifecycle()
    val revision by engine.library.revision.collectAsStateWithLifecycle()
    val watched = remember(revision) { engine.library.history(3000).filter { it.isCompleted }.map { it.metaId }.toSet() + engine.library.diary().map { it.metaId } }
    val order = settings.universeOrders[id]?.let { o -> UniverseOrder.entries.firstOrNull { it.name == o } } ?: UniverseOrder.RELEASE
    val ordered = universe.ordered(order)
    val progress = UniverseProgress.compute(universe, order, watched)
    val following = id in settings.followedUniverses
    val first = remember { FocusRequester() }
    fun open(e: UniverseEntry) = onOpenTitle(e.type, e.id)

    Box(modifier.fillMaxSize()) {
        RemoteImage(universe.heroBackground, universe.name, Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().background(app.aether.tv.ui.theme.backdropScrimHorizontal()))
        Box(Modifier.fillMaxSize().background(app.aether.tv.ui.theme.backdropScrimVertical()))
        androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides app.aether.tv.ui.theme.PivotScroll) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 40.dp, bottom = 60.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            item(key = "head") {
                Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal).width(720.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("UNIVERSO", style = MaterialTheme.typography.labelLarge, color = LocalAccent.current)
                    Text(universe.name, style = MaterialTheme.typography.displayMedium, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(universe.summary, style = MaterialTheme.typography.bodyLarge, color = Color.White.copy(alpha = 0.85f), maxLines = 3, overflow = TextOverflow.Ellipsis)
                    Text(listOfNotNull("${universe.films.size} film", universe.shows.size.takeIf { it > 0 }?.let { "$it serie" }, universe.years?.let { "${it.first}–${it.last}" }).joinToString(" · "), style = MaterialTheme.typography.labelLarge, color = AetherColors.OnSurfaceMuted)
                    Column(Modifier.width(480.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        ProgressLine(progress.fraction, Modifier.fillMaxWidth())
                        Text(if (progress.isComplete) "Hai visto tutto: complimenti!" else "Visti ${progress.watched} su ${progress.total} · ${progress.percent}%", style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        val next = progress.next
                        if (next != null) TvButton("Prossimo: ${next.name}", { open(next) }, icon = Icons.Filled.PlayArrow, primary = true, focusRequester = first, testTag = "universe.next")
                        TvButton(if (following) "Lo segui" else "Segui sulla Home", {
                            engine.settings.update { s -> s.copy(followedUniverses = if (id in s.followedUniverses) s.followedUniverses - id else s.followedUniverses + id) }
                        }, icon = if (following) Icons.Filled.Check else null, focusRequester = if (next == null) first else null, testTag = "universe.follow")
                    }
                }
                RequestFocusOnce(first, id)
            }
            item(key = "order") {
                Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        for (o in UniverseOrder.entries) {
                            if (o == UniverseOrder.CHRONOLOGICAL && universe.chronological == null) continue
                            TvChip(o.title, o == order, { engine.settings.update { s -> s.copy(universeOrders = s.universeOrders + (id to o.name)) } }, testTag = "universe.order.${o.name}")
                        }
                    }
                    val note = if (order == UniverseOrder.CHRONOLOGICAL) universe.chronologicalNote ?: "Ordine della storia ricostruito da fonti editoriali, non ufficiale." else "L'ordine in cui i titoli sono usciti."
                    Text(note, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 2)
                }
            }
            item(key = "map") {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionTitle("La mappa", Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
                    androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides app.aether.tv.ui.theme.EdgeScroll) {
                        LazyRow(contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 16.dp), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                            itemsIndexed(ordered, key = { _, e -> e.id }) { index, e ->
                                MapStop(e, index, last = index == ordered.lastIndex, seen = e.id in watched, isNext = e.id == progress.next?.id) { open(e) }
                            }
                        }
                    }
                }
            }
            val linked = UniverseCatalog.linked(id)
            if (linked.isNotEmpty()) item(key = "linked") {
                Column(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionTitle("Universi collegati")
                    linked.forEach { (u, note) ->
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            TvChip(u.name, false, { onOpenUniverse(u.id) })
                            Text(note, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
        }
    }
}

/** One stop of the map: the poster, the year above it, the line that joins it to the next one, a check when it was watched. */
@Composable
private fun MapStop(e: UniverseEntry, index: Int, last: Boolean, seen: Boolean, isNext: Boolean, onClick: () -> Unit) {
    val accent = LocalAccent.current
    Column(Modifier.width(176.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("${e.year}", style = MaterialTheme.typography.labelLarge, color = if (isNext) accent else AetherColors.OnSurfaceMuted, modifier = Modifier.padding(start = 4.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(14.dp).clip(CircleShape).background(if (seen) accent else if (isNext) Color.White else Color(0x66FFFFFF)))
            Box(Modifier.width(162.dp).height(3.dp).background(if (last) Color.Transparent else if (seen) accent.copy(alpha = 0.7f) else Color(0x33FFFFFF)))
        }
        FocusSurface(onClick, Modifier.width(150.dp).aspectRatio(0.675f), glow = true, testTag = "universe.stop.$index", onFocused = { app.aether.tv.ui.Ambient.show(e.background) }) {
            RemoteImage(e.poster, e.name, Modifier.fillMaxSize())
            if (seen) Box(Modifier.align(Alignment.TopStart).padding(7.dp).clip(CircleShape).background(Color(0xB3000000)).padding(4.dp)) {
                Icon(Icons.Filled.Check, "Visto", Modifier.size(14.dp), tint = AetherColors.Success)
            }
            if (isNext) Text("PROSSIMO", Modifier.align(Alignment.BottomStart).padding(8.dp).clip(RoundedCornerShape(8.dp)).background(accent).padding(horizontal = 8.dp, vertical = 3.dp), style = MaterialTheme.typography.labelSmall, color = Color.White)
        }
        Text(e.name, Modifier.width(150.dp), style = MaterialTheme.typography.labelMedium, color = AetherColors.OnBackground, maxLines = 2, minLines = 2, overflow = TextOverflow.Ellipsis)
        Text(if (e.series) "Serie" else "Film", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint)
    }
}
