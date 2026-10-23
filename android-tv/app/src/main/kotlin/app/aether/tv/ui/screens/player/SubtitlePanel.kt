package app.aether.tv.ui.screens.player

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.aether.core.playback.Languages
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.LocalAccent

private const val FILE = "\u0000file"

/**
 * Subtitles in two steps, like on the iPhone: first where they come from ("In the file", then one entry per addon), then the
 * languages of that source. The timing slider sits at the bottom of the first step: Left/Right move it by a tenth of a second,
 * a negative value shows the lines earlier, OK puts it back to zero.
 */
@Composable
fun SubtitlePanel(
    options: List<TrackOption>,
    preferredLanguage: String?,
    delayMs: Long,
    anticipationAvailable: Boolean,
    note: String?,
    onSelect: (TrackOption?) -> Unit,
    onDelay: (Long) -> Unit,
    onDismiss: () -> Unit,
) {
    var category by remember { mutableStateOf<String?>(null) }
    val sources = remember(options) {
        val order = LinkedHashMap<String, MutableList<TrackOption>>()
        options.filter { !it.fromAddon }.takeIf { it.isNotEmpty() }?.let { order[FILE] = it.toMutableList() }
        for (o in options.filter { it.fromAddon }) order.getOrPut(o.addonName ?: "Addon") { mutableListOf() }.add(o)
        order
    }
    val none = options.none { it.selected }
    val first = remember(category) { FocusRequester() }
    AetherDialog(if (category == null) "Sottotitoli" else sourceTitle(category!!), { if (category != null) category = null else onDismiss() }, width = 640.dp) {
        val current = category
        if (current == null) {
            LazyColumn(Modifier.height(380.dp), verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(4.dp)) {
                item {
                    Row0("Nessuno", check = none, focusRequester = first) { onSelect(null); onDismiss() }
                }
                items(sources.keys.toList()) { key ->
                    val list = sources.getValue(key)
                    Row0(sourceTitle(key), detail = "${list.size}", check = list.any { it.selected }, chevron = true) { category = key }
                }
                item { DelaySlider(delayMs, anticipationAvailable, onDelay) }
                note?.let { item { Text(it, style = MaterialTheme.typography.bodySmall, color = AetherColors.Warning, modifier = Modifier.padding(horizontal = 8.dp)) } }
            }
            RequestFocusOnce(first, current)
        } else {
            val list = sources[current].orEmpty()
            val groups = remember(list, preferredLanguage) {
                list.groupBy { it.lang?.let { l -> Languages.normalise(l) } ?: "?" }.entries
                    .sortedWith(compareByDescending<Map.Entry<String, List<TrackOption>>> { preferredLanguage != null && Languages.matches(it.key, preferredLanguage) }.thenBy { Languages.displayName(it.key) })
            }
            LazyColumn(Modifier.height(380.dp), verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(4.dp)) {
                var firstItem = true
                for ((lang, tracks) in groups) {
                    item(key = "h$lang") { Text(if (lang == "?") "Lingua non indicata" else Languages.displayName(lang), style = MaterialTheme.typography.titleSmall, color = AetherColors.OnSurfaceMuted, modifier = Modifier.padding(start = 8.dp, top = 6.dp)) }
                    tracks.forEachIndexed { i, option ->
                        val requester = if (firstItem) first else null
                        firstItem = false
                        item(key = option.id) {
                            val label = if (tracks.size > 1) "${Languages.displayName(lang).takeIf { lang != "?" } ?: option.label} ${i + 1}" else option.label
                            Row0(label, detail = option.detail.takeIf { current == FILE }, check = option.selected, focusRequester = requester) { onSelect(option); onDismiss() }
                        }
                    }
                }
            }
            RequestFocusOnce(first, current)
        }
    }
}

private fun sourceTitle(key: String) = if (key == FILE) "Nel file" else key

@Composable
private fun Row0(title: String, detail: String? = null, check: Boolean = false, chevron: Boolean = false, focusRequester: FocusRequester? = null, onClick: () -> Unit) {
    FocusSurface(onClick, Modifier.fillMaxWidth().height(48.dp), shape = RoundedCornerShape(12.dp), focusScale = 1.02f, focusRequester = focusRequester) {
        Row(Modifier.padding(horizontal = 16.dp).fillMaxHeight(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground, maxLines = 1, overflow = TextOverflow.Ellipsis)
            detail?.let { Text(it, style = MaterialTheme.typography.labelMedium, color = AetherColors.OnSurfaceMuted, maxLines = 1) }
            if (check) Icon(Icons.Filled.Check, null, tint = LocalAccent.current)
            if (chevron) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = AetherColors.OnSurfaceMuted)
        }
    }
}

/** −15 s … +15 s in tenths of a second. */
@Composable
private fun DelaySlider(delayMs: Long, anticipationAvailable: Boolean, onChange: (Long) -> Unit) {
    val accent = LocalAccent.current
    val shown = if (!anticipationAvailable && delayMs < 0) 0L else delayMs
    val fraction = ((shown + RANGE) / (2f * RANGE)).coerceIn(0f, 1f)
    FocusSurface(
        { onChange(0) },
        Modifier.fillMaxWidth().height(86.dp).onPreviewKeyEvent { event ->
            if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
            val step = if (event.nativeKeyEvent.repeatCount > 6) 500L else 100L
            val min = if (anticipationAvailable) -RANGE else 0L
            when (event.key) {
                Key.DirectionRight -> { onChange((shown + step).coerceIn(min, RANGE)); true }
                Key.DirectionLeft -> { onChange((shown - step).coerceIn(min, RANGE)); true }
                else -> false
            }
        },
        shape = RoundedCornerShape(12.dp), focusScale = 1.02f,
    ) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Sincronia", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
                Text(label(shown), style = MaterialTheme.typography.titleMedium, color = accent)
            }
            Box(Modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(5.dp)).background(AetherColors.OnSurfaceFaint.copy(alpha = 0.35f))) {
                Box(Modifier.fillMaxWidth(fraction).fillMaxHeight().clip(RoundedCornerShape(5.dp)).background(accent))
            }
            Text(
                if (anticipationAvailable) "◀ prima · dopo ▶   OK = azzera" else "◀ ▶ per ritardare (il file non permette di anticipare)   OK = azzera",
                style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted,
            )
        }
    }
}

private const val RANGE = 15_000L

private fun label(ms: Long): String = when {
    ms == 0L -> "Nessuna"
    ms > 0 -> "+%.1f s (dopo)".format(java.util.Locale.ITALY, ms / 1000.0)
    else -> "%.1f s (prima)".format(java.util.Locale.ITALY, ms / 1000.0)
}
