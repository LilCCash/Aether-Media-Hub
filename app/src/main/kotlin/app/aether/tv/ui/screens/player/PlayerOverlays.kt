package app.aether.tv.ui.screens.player

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import app.aether.core.metadata.RichDetails
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.tv.ui.components.ProgressLine
import app.aether.tv.ui.components.RemoteImage
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.LocalAccent
import app.aether.tv.ui.theme.LocalGraphics

/**
 * The start screen of a playback, as on the iPhone: the title's logo comes out of the dark (from big to its size), the scene of the
 * film behind it with year, length, genres and plot ("Apertura cinematografica"), and «Guarda» when the source is ready. Without the
 * intro it is only the preparing screen.
 */
@Composable
fun IntroOverlay(
    meta: MetaItem,
    video: Video?,
    title: String,
    logoUrl: String?,
    preparing: PlayerViewModel.Preparing?,
    ready: Boolean,
    intro: Boolean,
    scene: Boolean,
    resuming: Boolean,
    onWatch: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val graphics = LocalGraphics.current
    val zoom = remember { Animatable(if (intro && graphics.animations) 2.6f else 1f) }
    val fade = remember { Animatable(if (intro && graphics.animations) 0f else 1f) }
    LaunchedEffect(Unit) {
        kotlinx.coroutines.coroutineScope {
            launch { zoom.animateTo(1f, tween(graphics.ms(2000), easing = FastOutSlowInEasing)) }
            launch { fade.animateTo(1f, tween(graphics.ms(1400))) }
        }
    }
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        if (scene && intro && graphics.backdropArt) {
            RemoteImage(meta.background ?: meta.poster, meta.name, Modifier.fillMaxSize().graphicsLayer { alpha = 0.45f * fade.value }.then(if (graphics.blur) Modifier.blur(6.dp) else Modifier))
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0x59000000), Color(0xEB000000)))))
        }
        Column(Modifier.widthIn(max = 900.dp).padding(horizontal = 48.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(if (scene && intro) 16.dp else 24.dp)) {
            Box(Modifier.graphicsLayer { scaleX = zoom.value; scaleY = zoom.value; alpha = fade.value }, contentAlignment = Alignment.Center) {
                if (logoUrl != null) coil3.compose.AsyncImage(
                    model = logoUrl, contentDescription = title, contentScale = androidx.compose.ui.layout.ContentScale.Fit,
                    modifier = Modifier.widthIn(max = if (scene) 460.dp else 560.dp).heightIn(max = if (scene) 150.dp else 220.dp),
                ) else Text(title, style = MaterialTheme.typography.displaySmall, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
            }
            if (scene && intro) {
                val facts = listOfNotNull(meta.releaseInfo, meta.runtime, meta.genres.take(3).joinToString(" · ").ifEmpty { null }).filter { it.isNotBlank() }.joinToString("   ·   ")
                video?.episodeLabel?.let { label -> Text(listOfNotNull(label, video.title.takeIf { it.isNotBlank() }).joinToString(" · "), style = MaterialTheme.typography.titleMedium, color = LocalAccent.current, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                if (facts.isNotEmpty()) Text(facts.uppercase(), style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.75f * fade.value), maxLines = 1, overflow = TextOverflow.Ellipsis)
                val plot = video?.overview?.takeIf { it.isNotBlank() } ?: meta.description
                plot?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodyLarge, color = Color.White.copy(alpha = 0.82f * fade.value), maxLines = 3, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 720.dp)) }
            }
            Box(Modifier.heightIn(min = 64.dp), contentAlignment = Alignment.Center) {
                if (ready && intro) {
                    val watch = remember { FocusRequester() }
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        TvButton(if (resuming) "Riprendi" else "Guarda", onWatch, icon = Icons.Filled.PlayArrow, primary = true, focusRequester = watch, testTag = "player.intro.watch")
                        TvButton("Annulla", onCancel)
                    }
                    RequestFocusOnce(watch)
                } else Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (preparing?.fraction != null) ProgressLine(preparing.fraction!!, Modifier.width(420.dp))
                    else CircularProgressIndicator(Modifier.size(36.dp), color = Color.White, trackColor = Color(0x26FFFFFF), strokeWidth = 3.dp)
                    Text(preparing?.message ?: "Preparo il video…", style = MaterialTheme.typography.titleSmall, color = AetherColors.OnSurfaceMuted)
                    preparing?.detail?.let { Text(it, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted) }
                }
            }
        }
    }
}

/** After some seconds of pause: the logo (or the title) top left, the plot below, the cast on the right, over the dimmed picture. */
@Composable
fun PauseOverlay(meta: MetaItem, video: Video?, title: String, logoUrl: String?, rich: RichDetails?, modifier: Modifier = Modifier) {
    val fade = remember { Animatable(0f) }
    val graphics = LocalGraphics.current
    LaunchedEffect(Unit) { fade.animateTo(1f, tween(graphics.ms(600))) }
    Box(modifier.graphicsLayer { alpha = fade.value }.background(Brush.horizontalGradient(listOf(Color(0xE6000000), Color(0x99000000), Color(0x66000000))))) {
        Row(Modifier.fillMaxSize().padding(horizontal = 72.dp, vertical = 56.dp), horizontalArrangement = Arrangement.spacedBy(48.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("IN PAUSA", style = MaterialTheme.typography.labelLarge, color = LocalAccent.current)
                if (logoUrl != null) coil3.compose.AsyncImage(logoUrl, title, Modifier.widthIn(max = 420.dp).heightIn(max = 140.dp), alignment = Alignment.CenterStart, contentScale = androidx.compose.ui.layout.ContentScale.Fit)
                else Text(meta.name, style = MaterialTheme.typography.displaySmall, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                video?.episodeLabel?.let { Text(listOfNotNull(it, video.title.takeIf { t -> t.isNotBlank() }).joinToString(" · "), style = MaterialTheme.typography.titleMedium, color = Color.White.copy(alpha = 0.85f), maxLines = 1, overflow = TextOverflow.Ellipsis) }
                Spacer(Modifier.weight(1f))
                val plot = video?.overview?.takeIf { it.isNotBlank() } ?: meta.description
                plot?.takeIf { it.isNotBlank() }?.let {
                    Text(it, Modifier.clip(RoundedCornerShape(18.dp)).background(Color(0x1FFFFFFF)).padding(18.dp), style = MaterialTheme.typography.bodyLarge, color = Color.White.copy(alpha = 0.9f), maxLines = 6, overflow = TextOverflow.Ellipsis)
                }
                Text("Premi OK per continuare", style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted)
            }
            val cast = rich?.cast.orEmpty().take(6).map { Triple(it.name, it.role, it.photo) }.ifEmpty { meta.cast.take(6).map { Triple(it, null, null) } }
            if (cast.isNotEmpty()) Column(Modifier.width(300.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Nel cast", style = MaterialTheme.typography.titleMedium, color = Color.White)
                cast.forEach { (name, role, photo) ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(Modifier.size(48.dp).clip(CircleShape).background(Color(0x26FFFFFF))) { if (photo != null) RemoteImage(photo, name, Modifier.fillMaxSize()) }
                        Column {
                            Text(name, style = MaterialTheme.typography.labelLarge, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            role?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                        }
                    }
                }
            }
        }
    }
}

/** The end of a film: the credits as a page (cast, crew), and the way out. */
@Composable
fun CreditsOverlay(meta: MetaItem, rich: RichDetails?, onClose: () -> Unit, modifier: Modifier = Modifier) {
    val close = remember { FocusRequester() }
    Box(modifier.background(Color(0xF2050507))) {
        if (LocalGraphics.current.backdropArt) RemoteImage(meta.background, meta.name, Modifier.fillMaxSize().graphicsLayer { alpha = 0.18f })
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = 72.dp, vertical = 48.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("TITOLI DI CODA", style = MaterialTheme.typography.labelLarge, color = LocalAccent.current)
                    Text(meta.name, style = MaterialTheme.typography.displaySmall, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 8.dp)) {
                        TvButton("Chiudi", onClose, primary = true, focusRequester = close, testTag = "player.credits.close")
                    }
                }
            }
            val crew = rich?.crew.orEmpty().ifEmpty { (meta.directors.map { RichDetails.Person(it, "Regia", null) } + meta.writers.map { RichDetails.Person(it, "Sceneggiatura", null) }) }
            if (crew.isNotEmpty()) item { CreditsBlock("Dietro la macchina da presa", crew) }
            val cast = rich?.cast.orEmpty().ifEmpty { meta.cast.map { RichDetails.Person(it, null, null) } }
            if (cast.isNotEmpty()) item { CreditsBlock("Interpreti", cast) }
            rich?.companies?.takeIf { it.isNotEmpty() }?.let { companies -> item { Text("Produzione: " + companies.joinToString(" · "), style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted) } }
        }
    }
    RequestFocusOnce(close)
}

@Composable
private fun CreditsBlock(title: String, people: List<RichDetails.Person>) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        app.aether.tv.ui.components.SectionTitle(title)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            items(people.size) { i ->
                val p = people[i]
                Column(Modifier.width(120.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    app.aether.tv.ui.components.FocusSurface({}, Modifier.size(96.dp), shape = CircleShape, focusScale = 1.1f, glow = true) { if (p.photo != null) RemoteImage(p.photo, p.name, Modifier.fillMaxSize()) }
                    Text(p.name, style = MaterialTheme.typography.labelLarge, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                    Text(p.role ?: " ", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                }
            }
        }
    }
}
