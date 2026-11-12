package app.aether.tv.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import app.aether.core.diagnostics.LogLevel
import app.aether.tv.aether
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.TvChip
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens

/**
 * Impostazioni ▸ Informazioni ▸ Registro diagnostico: what the app did (sources, subtitles, debrid, player errors), newest first.
 * Addresses are cut to their host and keys masked before a line is kept; nothing leaves the TV.
 */
@Composable
fun DiagnosticsScreen(modifier: Modifier = Modifier) {
    val log = LocalContext.current.aether.log
    var revision by remember { mutableStateOf(0) }
    var onlyProblems by remember { mutableStateOf(false) }
    var verbose by remember { mutableStateOf(log.verbose) }
    val entries = remember(revision, onlyProblems) { log.entries().reversed().filter { !onlyProblems || it.level >= LogLevel.WARNING } }
    val first = remember { FocusRequester() }
    val format = remember { java.text.SimpleDateFormat("dd/MM HH:mm:ss", java.util.Locale.ITALY) }
    Column(modifier.fillMaxSize().padding(top = AetherDimens.ScreenVertical), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Registro diagnostico", style = MaterialTheme.typography.headlineLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        Text("Indirizzi ridotti al nome del server, chiavi e token nascosti. Resta solo su questa TV.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, modifier = Modifier.padding(horizontal = AetherDimens.ScreenHorizontal))
        Row(Modifier.padding(horizontal = AetherDimens.ScreenHorizontal), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TvButton("Aggiorna", { revision++ }, primary = true, focusRequester = first, testTag = "diagnostics.refresh")
            TvChip("Solo problemi", onlyProblems, { onlyProblems = !onlyProblems })
            TvChip("Dettagliato", verbose, { verbose = !verbose; log.verbose = verbose })
            TvButton("Svuota", { log.clear(); revision++ })
        }
        LazyColumn(contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = 8.dp, bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (entries.isEmpty()) item { Text("Niente da mostrare.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted) }
            items(entries.take(600)) { e ->
                FocusSurface({}, Modifier.fillMaxWidth(), focusScale = 1.0f, containerColor = Color.Transparent, focusedContainerColor = Color(0x1FFFFFFF)) {
                    Row(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(format.format(java.util.Date(e.timeMillis)), Modifier.width(120.dp), style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace), color = AetherColors.OnSurfaceFaint)
                        Text(e.level.label, Modifier.width(56.dp), style = MaterialTheme.typography.labelSmall, color = when (e.level) { LogLevel.ERROR -> AetherColors.Danger; LogLevel.WARNING -> AetherColors.Warning; else -> AetherColors.OnSurfaceMuted })
                        Text(e.category, Modifier.width(110.dp), style = MaterialTheme.typography.labelSmall, color = AetherColors.OnSurfaceMuted, maxLines = 1)
                        Text(e.message, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = AetherColors.OnBackground, maxLines = 3)
                    }
                }
            }
        }
    }
    RequestFocusOnce(first)
}
