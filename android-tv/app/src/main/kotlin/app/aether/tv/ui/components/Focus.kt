package app.aether.tv.ui.components

import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.LocalAccent
import app.aether.tv.ui.theme.LocalAnimations
import app.aether.tv.ui.theme.LocalCorner

/**
 * The basic focusable surface of the app. Whatever the remote highlights is unmistakable: it grows a little, takes the accent colour as
 * a border and gets brighter. OK / Enter on the remote activates it; a long press runs [onLongClick] when there is one.
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
    borderWidth: Dp = 3.dp,
    enabled: Boolean = true,
    focusRequester: FocusRequester? = null,
    testTag: String? = null,
    onFocused: (() -> Unit)? = null,
    content: @Composable BoxScope.(focused: Boolean) -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val animated = LocalAnimations.current
    val scale by animateFloatAsState(if (focused) focusScale else 1f, tween(if (animated) 130 else 0), label = "focusScale")
    val accent = LocalAccent.current
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
            .then(if (focused) Modifier.shadow(14.dp, shape, ambientColor = accent, spotColor = accent) else Modifier)
            .clip(shape)
            .background(if (focused) focusedContainerColor else containerColor, shape)
            .then(if (focused) Modifier.border(borderWidth, accent, shape) else Modifier)
            .combinedClickable(enabled = enabled, interactionSource = interaction, indication = null, onClick = onClick, onLongClick = onLongClick),
    ) { content(focused) }
}

/** What a screen reader says for an element that shows only an icon. */
fun Modifier.semanticsLabel(label: String): Modifier = this.semantics { contentDescription = label }
