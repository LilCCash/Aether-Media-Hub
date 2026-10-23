package app.aether.tv.ui.components

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Extension
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VideoLibrary
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import app.aether.tv.nav.Routes
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens
import app.aether.tv.ui.theme.LocalAccent
import app.aether.tv.ui.theme.LocalAnimations

data class NavEntry(val route: String, val label: String, val icon: ImageVector)

val navEntries = listOf(
    NavEntry(Routes.HOME, "Home", Icons.Filled.Home),
    NavEntry(Routes.DISCOVER, "Scopri", Icons.Filled.Explore),
    NavEntry(Routes.SEARCH, "Cerca", Icons.Filled.Search),
    NavEntry(Routes.LIBRARY, "Libreria", Icons.Filled.VideoLibrary),
    NavEntry(Routes.ADDONS, "Addon", Icons.Filled.Extension),
    NavEntry(Routes.SETTINGS, "Impostazioni", Icons.Filled.Settings),
)

/**
 * The menu on the left: only icons while the remote is in the content, labels when the remote moves onto it. It draws over the
 * content rather than pushing it, so the screens never reflow.
 */
@Composable
fun SideNav(current: String, onSelect: (String) -> Unit, modifier: Modifier = Modifier, entryRequester: FocusRequester? = null) {
    var expanded by remember { mutableStateOf(false) }
    val animated = LocalAnimations.current
    val width by animateDpAsState(if (expanded) AetherDimens.RailExpanded else AetherDimens.RailCollapsed, tween(if (animated) 180 else 0), label = "railWidth")
    Box(
        modifier
            .fillMaxHeight()
            .width(width)
            .background(
                Brush.horizontalGradient(
                    0f to AetherColors.Background,
                    if (expanded) 0.88f else 0.6f to AetherColors.Background.copy(alpha = if (expanded) 0.97f else 0.8f),
                    1f to Color.Transparent,
                ),
            )
            .onFocusChanged { expanded = it.hasFocus }
            .focusGroup(),
    ) {
        Column(
            Modifier.fillMaxHeight().padding(start = 12.dp, end = 12.dp, top = 28.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(Modifier.height(48.dp).padding(start = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.PlayCircle, null, Modifier.size(34.dp), tint = LocalAccent.current)
                if (expanded) Text("Aether", Modifier.padding(start = 12.dp), style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground)
            }
            androidx.compose.foundation.layout.Spacer(Modifier.height(10.dp))
            for (entry in navEntries) {
                val selected = entry.route == current
                FocusSurface(
                    onClick = { onSelect(entry.route) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(48.dp)
                        .then(if (selected && entryRequester != null) Modifier.focusRequester(entryRequester) else Modifier),
                    shape = RoundedCornerShape(24.dp),
                    focusScale = 1.03f,
                    borderWidth = 2.dp,
                    containerColor = if (selected) LocalAccent.current.copy(alpha = 0.22f) else Color.Transparent,
                    focusedContainerColor = AetherColors.SurfaceFocused,
                    testTag = "nav.${entry.route}",
                ) {
                    Row(Modifier.fillMaxHeight().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(entry.icon, entry.label, Modifier.size(26.dp), tint = if (selected) LocalAccent.current else AetherColors.OnBackground)
                        if (expanded) {
                            Text(
                                entry.label,
                                Modifier.padding(start = 14.dp),
                                style = MaterialTheme.typography.titleMedium,
                                color = if (selected) LocalAccent.current else AetherColors.OnBackground,
                                maxLines = 1,
                            )
                        }
                    }
                }
            }
        }
    }
}
