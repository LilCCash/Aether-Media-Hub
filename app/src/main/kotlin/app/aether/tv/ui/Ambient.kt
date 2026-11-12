package app.aether.tv.ui

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import app.aether.tv.ui.theme.LocalGraphics
import kotlinx.coroutines.delay

/**
 * The «atmosphere» of Aether: the picture of the title under the remote, large, soft and dark, behind the whole page. It follows the
 * focus with a short delay (a fast run along a row does not load every picture) and fades between titles. Off on the light level and
 * when «Immagini dietro le pagine» is off.
 */
object Ambient {
    private var wanted by mutableStateOf<String?>(null)
    internal var shown by mutableStateOf<String?>(null)
        private set

    fun show(url: String?) { wanted = url }
    fun clear() { wanted = null }

    @Composable
    fun Backdrop(modifier: Modifier = Modifier) {
        val graphics = LocalGraphics.current
        if (!graphics.backdropArt) return
        LaunchedEffect(wanted) {
            delay(if (wanted == null) 0 else 350)
            shown = wanted
        }
        Crossfade(targetState = shown, animationSpec = tween(graphics.ms(700)), label = "ambient", modifier = modifier) { url ->
            if (url == null) return@Crossfade
            Box(Modifier.fillMaxSize()) {
                coil3.compose.AsyncImage(
                    model = url, contentDescription = null, contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                        .then(if (graphics.blur) Modifier.blur(40.dp) else Modifier)
                        .graphicsLayer { alpha = if (graphics.blur) 0.55f else 0.32f },
                )
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color(0x660A0A0C), 0.55f to Color(0xB30A0A0C), 1f to Color(0xF20A0A0C))))
                Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(0f to Color(0x990A0A0C), 0.6f to Color.Transparent)))
            }
        }
    }
}
