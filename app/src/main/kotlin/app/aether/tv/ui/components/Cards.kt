package app.aether.tv.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.aether.core.library.PlaybackProgress
import app.aether.core.model.MetaItem
import app.aether.core.model.PosterShape
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.LocalAccent
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.allowRgb565
import coil3.request.crossfade

/** A picture from the network with a calm placeholder behind it (a gradient from the title, never an empty box). */
@Composable
fun RemoteImage(url: String?, seed: String, modifier: Modifier = Modifier, contentScale: ContentScale = ContentScale.Crop, alignment: Alignment = Alignment.Center) {
    val hue = ((seed.hashCode() and 0x7fffffff) % 360).toFloat()
    val base = Color.hsv(hue, 0.22f, 0.22f)
    val top = Color.hsv((hue + 30f) % 360f, 0.25f, 0.13f)
    val fades = app.aether.tv.ui.theme.LocalGraphics.current.imageFades
    Box(modifier.background(Brush.linearGradient(listOf(base, top)))) {
        if (!url.isNullOrBlank()) {
            AsyncImage(
                model = ImageRequest.Builder(LocalContext.current).data(url).crossfade(if (fades) 180 else 0).allowRgb565(true).build(),
                contentDescription = null,
                contentScale = contentScale,
                alignment = alignment,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Icon(Icons.Filled.Movie, null, Modifier.align(Alignment.Center).size(36.dp), tint = Color(0x55FFFFFF))
        }
    }
}

private fun shapeWidth(shape: PosterShape, base: Dp): Dp = when (shape) {
    PosterShape.POSTER -> base
    PosterShape.SQUARE -> base * 1.2f
    PosterShape.LANDSCAPE -> base * 1.9f
}

/** A poster: image, rating badge, optional watch progress, and the title under it. */
@Composable
fun PosterCard(
    meta: MetaItem,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = 150.dp,
    progress: Double? = null,
    watched: Boolean = false,
    onLongClick: (() -> Unit)? = null,
    focusRequester: FocusRequester? = null,
    onFocused: (() -> Unit)? = null,
    testTag: String? = null,
) {
    val cardWidth = shapeWidth(meta.posterShape, width)
    var focused by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    // The gap leaves room for the lifted poster, so it never covers its own title.
    Column(modifier.width(cardWidth), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        FocusSurface(
            onClick = onClick,
            onLongClick = onLongClick,
            modifier = Modifier.fillMaxWidth().aspectRatio(meta.posterShape.aspectRatio.toFloat())
                .onFocusChanged { focused = it.isFocused },
            shape = RoundedCornerShape(app.aether.tv.ui.theme.LocalCorner.current),
            focusScale = 1.08f,
            containerColor = AetherColors.Glass,
            focusedContainerColor = AetherColors.Glass,
            focusRequester = focusRequester,
            onFocused = onFocused,
            testTag = testTag,
        ) {
            RemoteImage(meta.poster ?: meta.background, meta.name, Modifier.fillMaxSize())
            meta.imdbRating?.takeIf { it.isNotBlank() }?.let { rating ->
                Row(
                    Modifier.align(Alignment.TopEnd).padding(7.dp).clip(RoundedCornerShape(8.dp)).background(Color(0xB3000000)).padding(horizontal = 6.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.Star, null, Modifier.size(12.dp), tint = Color(0xFFFFD60A))
                    Text(" $rating", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnBackground)
                }
            }
            if (watched) {
                Box(Modifier.align(Alignment.TopStart).padding(7.dp).clip(RoundedCornerShape(50)).background(Color(0xB3000000)).padding(4.dp)) {
                    Icon(Icons.Filled.Check, "Visto", Modifier.size(14.dp), tint = AetherColors.Success)
                }
            }
            if (progress != null && progress > 0.0) {
                ProgressLine(progress, Modifier.align(Alignment.BottomCenter).padding(8.dp), height = 4.dp)
            }
        }
        Text(
            meta.name,
            style = MaterialTheme.typography.labelLarge,
            color = if (focused) AetherColors.OnBackground else AetherColors.OnSurfaceMuted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp, vertical = 0.dp),
        )
        // One title line and one detail line, so every card has the same height and rows never jump.
        val sub = listOfNotNull(meta.year?.toString(), meta.genres.firstOrNull()).joinToString(" · ")
        Text(sub.ifEmpty { " " }, style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 2.dp))
    }
}

/** A wide card for "continua a guardare": the backdrop, what is being watched, and how far along. */
@Composable
fun ContinueCard(
    progress: PlaybackProgress,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = 300.dp,
    onLongClick: (() -> Unit)? = null,
    focusRequester: FocusRequester? = null,
    onFocused: (() -> Unit)? = null,
) {
    Column(modifier.width(width), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        FocusSurface(
            onClick = onClick,
            onLongClick = onLongClick,
            modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f),
            shape = RoundedCornerShape(app.aether.tv.ui.theme.LocalCorner.current),
            focusScale = 1.08f,
            containerColor = AetherColors.Glass,
            focusedContainerColor = AetherColors.Glass,
            focusRequester = focusRequester,
            onFocused = onFocused,
        ) {
            RemoteImage(progress.background ?: progress.poster, progress.title, Modifier.fillMaxSize())
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.45f to Color.Transparent, 1f to Color(0xD9000000))))
            Column(Modifier.align(Alignment.BottomStart).padding(10.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    progress.episodeLabel?.let { "$it · ${progress.episodeTitle.orEmpty()}" } ?: "Riprendi",
                    style = MaterialTheme.typography.labelMedium, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                ProgressLine(progress.fraction)
            }
        }
        Text(progress.title, style = MaterialTheme.typography.labelLarge, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
        progress.remaining?.let {
            Text("Mancano ${formatDuration(it)}", style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceFaint)
        }
    }
}

fun formatDuration(seconds: Double): String {
    val total = seconds.toLong().coerceAtLeast(0)
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
