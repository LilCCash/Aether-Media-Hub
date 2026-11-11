package app.aether.tv.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.aether.core.addons.RequestPlanner
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.components.TvIconButton
import app.aether.tv.ui.theme.AetherColors

/**
 * Impostazioni ▸ Aspetto ▸ Personalizza la Home: every section of the Home (continue watching, next episode, each catalog of the
 * addons) in the order it appears, with arrows to move it and a switch to show or hide it. Same model as the iOS customisation.
 */
@Composable
fun HomeLayoutDialog(onDismiss: () -> Unit) {
    val engine = LocalContext.current.aether
    val settings by engine.settings.value.collectAsState()
    var sections by remember { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    LaunchedEffect(Unit) {
        val refs = RequestPlanner.feedCatalogs(engine.registry.handles())
        sections = listOf("continue" to "Continua a guardare", "nextup" to "Prossimo episodio") + refs.map { it.id to "${it.title} · ${it.addonName}" }
    }
    val order = settings.appearance.homeSectionOrder
    val ordered = sections.sortedBy { (id, _) -> order.indexOf(id).let { if (it < 0) Int.MAX_VALUE else it } }
    val hidden = settings.appearance.hiddenHomeSections

    fun move(index: Int, delta: Int) {
        val ids = ordered.map { it.first }.toMutableList()
        val target = index + delta
        if (target !in ids.indices) return
        ids.add(target, ids.removeAt(index))
        engine.settings.update { it.copy(appearance = it.appearance.copy(homeSectionOrder = ids)) }
    }

    fun toggle(id: String) = engine.settings.update {
        val list = it.appearance.hiddenHomeSections
        it.copy(appearance = it.appearance.copy(hiddenHomeSections = if (id in list) list - id else list + id))
    }

    val done = remember { FocusRequester() }
    AetherDialog("Personalizza la Home", onDismiss, width = 860.dp) {
        Text("Sposta le sezioni con le frecce, premi sul nome per mostrarla o nasconderla.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
        LazyColumn(Modifier.height(480.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            itemsIndexed(ordered, key = { _, it -> it.first }) { index, (id, title) ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvIconButton(Icons.Filled.KeyboardArrowUp, "Sposta su", { if (index > 0) move(index, -1) }, size = 40.dp)
                    TvIconButton(Icons.Filled.KeyboardArrowDown, "Sposta giù", { if (index < ordered.lastIndex) move(index, 1) }, size = 40.dp)
                    TvChip((if (id in hidden) "Nascosta · " else "Visibile · ") + title, id !in hidden, { toggle(id) }, testTag = "home.section.$index")
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TvButton("Fatto", onDismiss, primary = true, focusRequester = done)
            TvButton("Ordine iniziale", { engine.settings.update { it.copy(appearance = it.appearance.copy(homeSectionOrder = emptyList(), hiddenHomeSections = emptyList())) } })
        }
        RequestFocusOnce(done)
    }
}
