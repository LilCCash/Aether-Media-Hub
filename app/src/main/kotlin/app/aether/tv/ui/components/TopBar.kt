package app.aether.tv.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.aether.tv.nav.Routes
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalGraphics

data class NavEntry(val route: String, val label: String, val icon: ImageVector? = null)

/** The sections, left to right in the tab bar; Cerca and Impostazioni are round icons at the ends, as on tvOS. */
val navEntries = listOf(
    NavEntry(Routes.SEARCH, "Cerca", Icons.Filled.Search),
    NavEntry(Routes.HOME, "Home"),
    NavEntry(Routes.DISCOVER, "Scopri"),
    NavEntry(Routes.RECOMMEND, "Per te"),
    NavEntry(Routes.LIVE, "TV in diretta"),
    NavEntry(Routes.LIBRARY, "Libreria"),
    NavEntry(Routes.ADDONS, "Addon"),
    NavEntry(Routes.SETTINGS, "Impostazioni", Icons.Filled.Settings),
)

/**
 * The tab bar at the top of every section, in the manner of tvOS: glass pills, the current one lit, the one under the remote white.
 * It floats over the content (nothing reflows); [visible] false fades it away while the viewer scrolls down a long page, and it
 * comes back as soon as the remote reaches it.
 */
@Composable
fun TopBar(
    current: String,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    visible: Boolean = true,
    hidden: Set<String> = emptySet(),
    entryRequester: FocusRequester? = null,
    /** Where Down from the bar goes: the page under it (whatever it shows). */
    contentRequester: FocusRequester? = null,
) {
    var hasFocus by remember { mutableStateOf(false) }
    val graphics = LocalGraphics.current
    val shown = visible || hasFocus
    val alpha by animateFloatAsState(if (shown) 1f else 0f, tween(graphics.ms(220)), label = "topBar")
    Box(
        modifier
            .fillMaxWidth()
            .height(AetherDimens.TopBar + 24.dp)
            .graphicsLayer { this.alpha = alpha; translationY = (1f - alpha) * -24.dp.toPx() }
            .background(Brush.verticalGradient(0f to Color(0xCC0A0A0C), 0.7f to Color(0x660A0A0C), 1f to Color.Transparent))
            .onFocusChanged { hasFocus = it.hasFocus }
            .focusGroup(),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = AetherDimens.ScreenVertical - 4.dp).height(48.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Aether", style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Black), color = AetherColors.OnBackground, modifier = Modifier.padding(end = 18.dp))
            Spacer(Modifier.weight(1f))
            for (entry in navEntries) {
                if (entry.route in hidden) continue
                TabPill(entry, entry.route == current, { onSelect(entry.route) }, if (entry.route == current) entryRequester else null, contentRequester)
            }
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(64.dp))
        }
    }
}

@Composable
private fun TabPill(entry: NavEntry, selected: Boolean, onClick: () -> Unit, requester: FocusRequester?, content: FocusRequester?) {
    val round = entry.icon != null
    FocusSurface(
        onClick = onClick,
        modifier = (if (round) Modifier.size(44.dp) else Modifier.height(44.dp)).semanticsLabel(entry.label)
            // Down always enters the page, even when the bar floats over a picture with nothing right below the pill.
            .then(if (content != null) Modifier.focusProperties { down = content } else Modifier),
        shape = RoundedCornerShape(22.dp),
        focusScale = 1.1f,
        containerColor = if (selected) Color(0x40FFFFFF) else Color.Transparent,
        focusedContainerColor = Color.White,
        edge = false,
        focusRequester = requester,
        testTag = "nav.${entry.route}",
    ) { focused ->
        val color = if (focused) AetherColors.OnFocused else if (selected) AetherColors.OnBackground else AetherColors.OnSurfaceMuted
        if (round) {
            Icon(entry.icon!!, entry.label, Modifier.size(22.dp).align(Alignment.Center), tint = color)
        } else {
            Box(Modifier.fillMaxHeight().padding(horizontal = 18.dp), contentAlignment = Alignment.Center) {
                Text(entry.label, style = MaterialTheme.typography.labelLarge, color = color, maxLines = 1, modifier = Modifier.alpha(1f))
            }
        }
    }
}
