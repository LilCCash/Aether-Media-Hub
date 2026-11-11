package app.aether.tv.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.unit.dp
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens

/**
 * Remembers which item of a screen the remote was on, so that coming back (Back from the details) lands on the same poster and
 * not at the top-left corner. The key survives the navigation round trip through the saved state of the back stack entry.
 */
class FocusMemory(initial: String, private val store: (String) -> Unit) {
    var key: String = initial
        private set

    fun remember(newKey: String) {
        if (newKey != key) { key = newKey; store(newKey) }
    }
}

@Composable
fun rememberFocusMemory(): FocusMemory {
    val saved = androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf("") }
    return remember { FocusMemory(saved.value) { saved.value = it } }
}

/** A titled, horizontally scrolling row of cards. [content] gets the item and may ask for the focus through [restore]. */
@Composable
fun <T> ContentRow(
    title: String,
    items: List<T>,
    key: (T) -> String,
    modifier: Modifier = Modifier,
    rowId: String = title,
    memory: FocusMemory? = null,
    trailing: @Composable (() -> Unit)? = null,
    card: @Composable (item: T, requester: FocusRequester?, onFocused: () -> Unit) -> Unit,
) {
    val state = rememberLazyListState()
    // Two entries with the same key would crash a lazy list: the first one wins.
    val unique = remember(items) { items.distinctBy { key(it) } }
    val restoreKey = memory?.key?.takeIf { it.startsWith("$rowId|") }?.removePrefix("$rowId|")
    val restoreIndex = restoreKey?.let { target -> unique.indexOfFirst { key(it) == target } } ?: -1
    val requester = remember(restoreKey) { FocusRequester() }
    var arrived by remember(restoreKey) { androidx.compose.runtime.mutableStateOf(false) }
    if (restoreIndex >= 0) {
        LaunchedEffect(restoreKey, unique.size) {
            state.scrollToItem(restoreIndex)
            // The poster may not be attached yet: ask again until the focus has really arrived (a few tries, then give up quietly).
            repeat(25) {
                if (arrived) return@LaunchedEffect
                runCatching { requester.requestFocus() }
                kotlinx.coroutines.delay(60)
            }
        }
    }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text(title, style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(end = 12.dp))
            trailing?.invoke()
        }
        LazyRow(
            state = state,
            contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(AetherDimens.RowSpacing),
        ) {
            items(unique.size, key = { key(unique[it]) }) { index ->
                val item = unique[index]
                val itemKey = key(item)
                card(item, if (index == restoreIndex) requester else null) { arrived = true; memory?.remember("$rowId|$itemKey") }
            }
        }
    }
}

/** The grey stand-ins shown in a row while its catalog loads. */
@Composable
fun RowPlaceholder(title: String, modifier: Modifier = Modifier, count: Int = 8) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        LazyRow(
            userScrollEnabled = false,
            contentPadding = PaddingValues(horizontal = AetherDimens.ScreenHorizontal, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(AetherDimens.RowSpacing),
        ) {
            items(count) { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { Placeholder(Modifier.width(150.dp).height(222.dp)); Placeholder(Modifier.width(110.dp).height(12.dp)) } }
        }
    }
}
