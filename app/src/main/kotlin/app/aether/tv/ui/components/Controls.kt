package app.aether.tv.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.LocalAccent
import app.aether.tv.ui.theme.LocalAnimations

/**
 * A button in the manner of tvOS: a glass pill that turns white with dark text under the remote. [primary] ones are light already
 * (the main action of a screen stands out without a colour block).
 */
@Composable
fun TvButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    primary: Boolean = false,
    enabled: Boolean = true,
    focusRequester: FocusRequester? = null,
    testTag: String? = null,
) {
    FocusSurface(
        onClick = onClick,
        modifier = modifier.height(50.dp),
        shape = RoundedCornerShape(25.dp),
        enabled = enabled,
        focusScale = 1.07f,
        containerColor = if (primary) Color(0xE6F5F5F7) else AetherColors.SurfaceRaised,
        focusedContainerColor = Color.White,
        edge = false,
        focusRequester = focusRequester,
        testTag = testTag,
    ) { focused ->
        val content = if (focused || primary) AetherColors.OnFocused else AetherColors.OnBackground
        Row(
            Modifier.padding(horizontal = 24.dp).fillMaxHeight().alpha(if (enabled) 1f else 0.4f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
        ) {
            if (icon != null) Icon(icon, null, Modifier.size(22.dp), tint = content)
            Text(text, style = MaterialTheme.typography.labelLarge, color = content, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** A round icon-only button (favourites, watchlist…); [label] is what a screen reader says. */
@Composable
fun TvIconButton(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    active: Boolean = false,
    size: androidx.compose.ui.unit.Dp = 50.dp,
    focusRequester: FocusRequester? = null,
    testTag: String? = null,
) {
    val accent = LocalAccent.current
    FocusSurface(
        onClick = onClick,
        modifier = modifier.size(size).semanticsLabel(label),
        shape = CircleShape,
        focusScale = 1.12f,
        containerColor = AetherColors.SurfaceRaised,
        focusedContainerColor = Color.White,
        edge = false,
        focusRequester = focusRequester,
        testTag = testTag,
    ) { focused ->
        Box(Modifier.fillMaxWidth().fillMaxHeight(), contentAlignment = Alignment.Center) {
            Icon(icon, label, Modifier.size(size * 0.48f), tint = if (focused) AetherColors.OnFocused else if (active) accent else AetherColors.OnBackground)
        }
    }
}

/** A choice pill (tabs, filters): glass, light when selected, white under the remote. */
@Composable
fun TvChip(
    text: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    testTag: String? = null,
) {
    FocusSurface(
        onClick = onClick,
        modifier = modifier.height(40.dp),
        shape = RoundedCornerShape(20.dp),
        focusScale = 1.08f,
        containerColor = if (selected) Color(0x4DFFFFFF) else AetherColors.Glass,
        focusedContainerColor = Color.White,
        edge = false,
        focusRequester = focusRequester,
        testTag = testTag,
    ) { focused ->
        Box(Modifier.padding(horizontal = 18.dp).fillMaxHeight(), contentAlignment = Alignment.Center) {
            Text(
                text,
                style = MaterialTheme.typography.labelLarge,
                color = if (focused) AetherColors.OnFocused else if (selected) AetherColors.OnBackground else AetherColors.OnSurfaceMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** A small label such as "1080p", "HEVC" or "In cache": a quiet glass capsule. */
@Composable
fun Badge(text: String, modifier: Modifier = Modifier, color: Color = AetherColors.SurfaceRaised, contentColor: Color = AetherColors.OnBackground) {
    Box(modifier.clip(RoundedCornerShape(7.dp)).background(color).padding(horizontal = 8.dp, vertical = 3.dp)) {
        Text(text, style = MaterialTheme.typography.labelSmall, color = contentColor, maxLines = 1)
    }
}

@Composable
fun ProgressLine(fraction: Double, modifier: Modifier = Modifier, height: androidx.compose.ui.unit.Dp = 4.dp) {
    Box(modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(height)).background(Color(0x40FFFFFF))) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(fraction.coerceIn(0.0, 1.0).toFloat()).clip(RoundedCornerShape(height)).background(Color.White))
    }
}

@Composable
fun LoadingState(message: String = "Caricamento…", modifier: Modifier = Modifier) {
    val accent = LocalAccent.current
    Column(modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        CircularProgressIndicator(color = AetherColors.OnBackground, trackColor = Color(0x26FFFFFF), strokeWidth = 3.dp, modifier = Modifier.size(40.dp))
        Text(message, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
    }
}

/** A calm, complete screen for "nothing here": what is missing, why, and what can be done about it. */
@Composable
fun EmptyState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    icon: ImageVector = Icons.Filled.Movie,
    actions: @Composable () -> Unit = {},
) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = 48.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, null, Modifier.size(56.dp), tint = AetherColors.OnSurfaceFaint)
        Text(title, style = MaterialTheme.typography.headlineMedium, color = AetherColors.OnBackground, textAlign = TextAlign.Center)
        Text(message, style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted, textAlign = TextAlign.Center, modifier = Modifier.width(560.dp))
        Spacer(Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { actions() }
    }
}

@Composable
fun ErrorState(message: String, onRetry: (() -> Unit)?, modifier: Modifier = Modifier, retryRequester: FocusRequester? = null) {
    EmptyState("Qualcosa non va", message, modifier, icon = Icons.Filled.ErrorOutline) {
        if (onRetry != null) TvButton("Riprova", onRetry, primary = true, focusRequester = retryRequester)
    }
}

/** A grey block that breathes while the real content loads. */
@Composable
fun Placeholder(modifier: Modifier = Modifier, shape: androidx.compose.ui.graphics.Shape = RoundedCornerShape(10.dp)) {
    val animated = LocalAnimations.current
    val alpha = if (animated) {
        val transition = rememberInfiniteTransition(label = "placeholder")
        val value by transition.animateFloat(0.05f, 0.11f, infiniteRepeatable(tween(1100), RepeatMode.Reverse), label = "alpha")
        value
    } else 0.08f
    Box(modifier.clip(shape).background(Color.White.copy(alpha = alpha)))
}

/** A text field that looks right on a television (large, with a clear focus ring) and opens the system keyboard on OK. */
@Composable
fun TvTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    secret: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Done,
    onImeAction: (() -> Unit)? = null,
    focusRequester: FocusRequester? = null,
    singleLine: Boolean = true,
    testTag: String? = null,
) {
    val accent = LocalAccent.current
    var focused by remember { mutableStateOf(false) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted)
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = singleLine,
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = AetherColors.OnBackground),
            cursorBrush = SolidColor(accent),
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(keyboardType = if (secret) KeyboardType.Password else keyboardType, imeAction = imeAction),
            keyboardActions = KeyboardActions(onAny = { onImeAction?.invoke() }),
            modifier = Modifier
                .fillMaxWidth()
                .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
                .then(if (testTag != null) Modifier.testTag(testTag) else Modifier)
                .onFocusChanged { focused = it.isFocused }
                .clip(RoundedCornerShape(14.dp))
                .background(if (focused) Color(0x33FFFFFF) else AetherColors.Glass)
                .border(if (focused) 2.dp else 1.dp, if (focused) Color(0xCCFFFFFF) else AetherColors.GlassStroke, RoundedCornerShape(14.dp))
                .padding(horizontal = 18.dp, vertical = 13.dp),
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty() && placeholder.isNotEmpty()) {
                        Text(placeholder, style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceFaint, maxLines = 1)
                    }
                    inner()
                }
            },
        )
    }
}

/**
 * A modal panel. The first element asks for the focus (through [initialFocus]) so the remote works at once; Back closes it.
 */
@Composable
fun AetherDialog(
    title: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    width: androidx.compose.ui.unit.Dp = 640.dp,
    content: @Composable () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier
                .width(width)
                .clip(RoundedCornerShape(28.dp))
                .background(AetherColors.Surface.copy(alpha = 0.97f))
                .border(1.dp, AetherColors.GlassStroke, RoundedCornerShape(28.dp))
                .padding(horizontal = 34.dp, vertical = 30.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Text(title, style = MaterialTheme.typography.headlineMedium, color = AetherColors.OnBackground)
            content()
        }
    }
}

/** Asks for the focus once the composable is in place; used by dialogs and by screens that should start on a given element. */
@Composable
fun RequestFocusOnce(requester: FocusRequester, key: Any? = Unit) {
    LaunchedEffect(key) {
        // The target is attached a frame after the first composition; one retry is enough in practice.
        repeat(3) {
            if (runCatching { requester.requestFocus() }.isSuccess) return@LaunchedEffect
            kotlinx.coroutines.delay(60)
        }
    }
}

/** A dialog with one row per option and a check on the current one. */
@Composable
fun <T> ChoiceDialog(
    title: String,
    options: List<Pair<T, String>>,
    selected: T?,
    onSelect: (T) -> Unit,
    onDismiss: () -> Unit,
) {
    val requesters = remember(options.size) { List(options.size) { FocusRequester() } }
    val start = options.indexOfFirst { it.first == selected }.coerceAtLeast(0)
    AetherDialog(title, onDismiss, width = 520.dp) {
        androidx.compose.foundation.lazy.LazyColumn(
            Modifier.height((minOf(options.size, 7) * 56).dp),
            contentPadding = PaddingValues(vertical = 4.dp, horizontal = 4.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(options.size) { index ->
                val (value, label) = options[index]
                FocusSurface(
                    onClick = { onSelect(value); onDismiss() },
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(14.dp),
                    focusScale = 1.03f,
                    containerColor = Color.Transparent,
                    focusedContainerColor = Color.White,
                    edge = false,
                    focusRequester = requesters.getOrNull(index),
                ) { focused ->
                    Row(Modifier.padding(horizontal = 18.dp).fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
                        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = if (focused) AetherColors.OnFocused else AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (value == selected) Icon(Icons.Filled.Check, null, tint = if (focused) AetherColors.OnFocused else LocalAccent.current)
                    }
                }
            }
        }
        requesters.getOrNull(start)?.let { RequestFocusOnce(it) }
    }
}

/** A drop-down filter: a pill showing "Label: value ▾" that opens the list of choices in a dialog. */
@Composable
fun FilterPill(
    label: String,
    options: List<Pair<String, String>>,
    selected: String,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    testTag: String? = null,
) {
    var open by remember { mutableStateOf(false) }
    val shown = options.firstOrNull { it.first == selected }?.second ?: selected
    FocusSurface(
        { open = true }, modifier.height(40.dp), shape = RoundedCornerShape(20.dp), focusScale = 1.07f,
        containerColor = AetherColors.Glass, focusedContainerColor = Color.White, edge = false, focusRequester = focusRequester, testTag = testTag,
    ) { focused ->
        Row(Modifier.padding(horizontal = 16.dp).fillMaxHeight(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("$label:", style = MaterialTheme.typography.labelMedium, color = if (focused) AetherColors.OnFocused.copy(alpha = 0.7f) else AetherColors.OnSurfaceMuted, maxLines = 1)
            Text(shown, style = MaterialTheme.typography.labelLarge, color = if (focused) AetherColors.OnFocused else AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 220.dp))
            Icon(Icons.Filled.ArrowDropDown, null, Modifier.size(20.dp), tint = if (focused) AetherColors.OnFocused else AetherColors.OnSurfaceMuted)
        }
    }
    if (open) ChoiceDialog(label, options, selected, onSelect, { open = false })
}
