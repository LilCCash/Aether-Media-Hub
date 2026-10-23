package app.aether.tv.ui.components

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.aether.core.model.MetaItem
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAnimations
import app.aether.tv.ui.theme.backdropScrimHorizontal
import app.aether.tv.ui.theme.backdropScrimVertical
import kotlinx.coroutines.delay

/** The line of facts under a title: year, runtime, rating and the first genres. Only what the data really says. */
fun MetaItem.factsLine(): String = listOfNotNull(
    year?.toString(),
    runtime?.takeIf { it.isNotBlank() },
    imdbRating?.takeIf { it.isNotBlank() }?.let { "★ $it" },
    genres.take(3).takeIf { it.isNotEmpty() }?.joinToString(" · "),
).joinToString("   ·   ")

/**
 * The big picture at the top of the Home: the backdrop of a featured title with its name, facts and description, and the two actions.
 * With several titles it turns to the next every few seconds, but never while the remote is on its buttons.
 */
@Composable
fun HeroBanner(
    items: List<MetaItem>,
    autoScroll: Boolean,
    onPlay: (MetaItem) -> Unit,
    onDetails: (MetaItem) -> Unit,
    modifier: Modifier = Modifier,
    playRequester: FocusRequester? = null,
    height: androidx.compose.ui.unit.Dp = 330.dp,
) {
    if (items.isEmpty()) return
    var index by remember(items.size) { mutableIntStateOf(0) }
    var buttonsFocused by remember { mutableStateOf(false) }
    val animated = LocalAnimations.current
    if (autoScroll && animated && items.size > 1) {
        LaunchedEffect(items.size, buttonsFocused) {
            if (buttonsFocused) return@LaunchedEffect
            while (true) {
                delay(9_000)
                index = (index + 1) % items.size
            }
        }
    }
    val item = items[index.coerceIn(0, items.size - 1)]
    Box(modifier.fillMaxWidth().height(height)) {
        Crossfade(targetState = item, animationSpec = tween(if (animated) 600 else 0), label = "hero") { current ->
            Box(Modifier.fillMaxSize()) {
                RemoteImage(current.background ?: current.poster, current.name, Modifier.fillMaxSize())
                Box(Modifier.fillMaxSize().background(backdropScrimHorizontal()))
                Box(Modifier.fillMaxSize().background(backdropScrimVertical()))
                Column(
                    Modifier.align(Alignment.BottomStart).padding(start = AetherDimens.ScreenHorizontal, bottom = 74.dp).width(560.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(current.name, style = MaterialTheme.typography.displayMedium, color = AetherColors.OnBackground, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    current.factsLine().takeIf { it.isNotEmpty() }?.let {
                        Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, maxLines = 1)
                    }
                    current.description?.takeIf { it.isNotBlank() }?.let {
                        Text(it, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnBackground.copy(alpha = 0.85f), maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
        Row(
            Modifier
                .align(Alignment.BottomStart)
                .padding(start = AetherDimens.ScreenHorizontal, bottom = 16.dp)
                .onFocusChanged { buttonsFocused = it.hasFocus }
                .focusGroup(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            TvButton("Guarda", { onPlay(item) }, icon = Icons.Filled.PlayArrow, primary = true, focusRequester = playRequester, testTag = "hero.play")
            TvButton("Dettagli", { onDetails(item) }, icon = Icons.Filled.Info, testTag = "hero.details")
        }
        if (items.size > 1) {
            Row(Modifier.align(Alignment.BottomEnd).padding(end = AetherDimens.ScreenHorizontal, bottom = 28.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (i in items.indices) {
                    Box(Modifier.width(if (i == index) 22.dp else 8.dp).height(6.dp).background(if (i == index) AetherColors.OnBackground else AetherColors.OnSurfaceFaint, androidx.compose.foundation.shape.RoundedCornerShape(3.dp)))
                }
            }
        }
    }
}
