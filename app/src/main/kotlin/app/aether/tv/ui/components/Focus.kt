package app.aether.tv.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.LocalCorner
import app.aether.tv.ui.theme.LocalGraphics

/**
 * The focusable surface of the whole app, in the manner of tvOS: the element under the remote lifts (grows, brightens, a thin light
 * edge and a soft shadow below it). The shadow is a few translucent rounded rectangles drawn behind (no platform shadow: cheap and
 * exact on every TV) and is left out on the light graphics level. OK activates; a long press runs [onLongClick].
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FocusSurface(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onLongClick: (() -> Unit)? = null,
    shape: Shape = RoundedCornerShape(LocalCorner.current),
    focusScale: Float = 1.06f,
    containerColor: Color = AetherColors.SurfaceRaised,
    focusedContainerColor: Color = AetherColors.SurfaceFocused,
    borderWidth: Dp = 2.dp,
    enabled: Boolean = true,
    focusRequester: FocusRequester? = null,
    testTag: String? = null,
    onFocused: (() -> Unit)? = null,
    /** The light edge when focused; buttons that turn white do without it. */
    edge: Boolean = true,
    content: @Composable BoxScope.(focused: Boolean) -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val graphics = LocalGraphics.current
    val scale by animateFloatAsState(
        if (focused) focusScale else 1f,
        if (graphics.animations) spring(dampingRatio = 0.72f, stiffness = 520f) else tween(0),
        label = "focusScale",
    )
    val background by animateColorAsState(if (focused) focusedContainerColor else containerColor, tween(graphics.ms(140)), label = "focusColor")
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            .zIndex(if (focused) 1f else 0f)
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .then(if (testTag != null) Modifier.testTag(testTag) else Modifier)
            .onFocusChanged { state ->
                focused = state.isFocused
                if (state.isFocused) onFocused?.invoke()
            }
            .then(if (focused && graphics.shadows) Modifier.drawBehind { softShadow(shape) } else Modifier)
            .clip(shape)
            .background(background, shape)
            .then(if (focused && edge) Modifier.border(borderWidth, Color(0x8CFFFFFF), shape) else Modifier)
            .combinedClickable(enabled = enabled, interactionSource = interaction, indication = null, onClick = onClick, onLongClick = onLongClick),
    ) { content(focused) }
}

/** A soft dark shadow under a lifted element: four widening, fading layers shifted down a little. */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.softShadow(shape: Shape) {
    val outline = shape.createOutline(size, layoutDirection, this)
    val radius = (outline as? Outline.Rounded)?.roundRect?.topLeftCornerRadius?.x ?: 0f
    for (i in 1..4) {
        val spread = i * 4.dp.toPx()
        val color = Color.Black.copy(alpha = 0.16f - i * 0.03f)
        drawRoundRect(
            color,
            topLeft = Offset(-spread / 2, spread * 0.9f - spread / 2),
            size = Size(size.width + spread, size.height + spread),
            cornerRadius = CornerRadius(radius + spread / 2),
        )
    }
}

/** What a screen reader says for an element that shows only an icon. */
fun Modifier.semanticsLabel(label: String): Modifier = this.semantics { contentDescription = label }
