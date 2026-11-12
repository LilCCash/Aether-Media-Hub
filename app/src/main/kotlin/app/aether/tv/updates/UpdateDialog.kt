package app.aether.tv.updates

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.ProgressLine
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.theme.AetherColors
import kotlinx.coroutines.launch

/** The update window: what is new, then the download and the system installer. [onLater] closes it. */
@Composable
fun UpdateDialog(onLater: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val state by AppUpdater.state.collectAsState()
    val first = remember { FocusRequester() }
    val info = when (val s = state) {
        is AppUpdater.State.Available -> s.info
        is AppUpdater.State.Downloading -> s.info
        is AppUpdater.State.Installing -> s.info
        is AppUpdater.State.NeedsPermission -> s.info
        else -> null
    }
    AetherDialog(if (info != null) "Aggiornamento disponibile" else "Aggiornamenti", onLater, width = 680.dp) {
        when (val s = state) {
            AppUpdater.State.Checking, AppUpdater.State.Idle -> Text("Controllo…", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
            is AppUpdater.State.UpToDate -> Text("Hai già l'ultima versione: ${AppUpdater.currentVersion}.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
            is AppUpdater.State.Failed -> Text(s.message, style = MaterialTheme.typography.bodyLarge, color = AetherColors.Warning)
            is AppUpdater.State.NeedsPermission -> Text("Per aggiornarsi da sola, Aether deve avere il permesso «Installa app sconosciute». Apri le impostazioni, attivalo per Aether e torna qui.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
            is AppUpdater.State.Downloading -> {
                Text("Scarico la build ${s.info.versionCode}…", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
                ProgressLine(s.fraction ?: 0.0, Modifier.width(560.dp), height = 6.dp)
            }
            is AppUpdater.State.Installing -> Text("Confermo l'installazione: la TV ti chiederà di accettare l'aggiornamento.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
            is AppUpdater.State.Available -> {
                Text("Versione installata: ${AppUpdater.currentVersion}\nNuova: ${s.info.versionName} (build ${s.info.versionCode})" + if (s.info.size > 0) " · ${"%.1f".format(s.info.size / 1_048_576.0)} MB" else "",
                    style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
                if (s.info.notes.isNotBlank()) Text(s.info.notes, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted, maxLines = 6, overflow = TextOverflow.Ellipsis)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            when (state) {
                is AppUpdater.State.Available -> TvButton("Aggiorna ora", { scope.launch { AppUpdater.install(context, info!!) } }, primary = true, focusRequester = first, testTag = "update.install")
                is AppUpdater.State.NeedsPermission -> {
                    TvButton("Apri le impostazioni", { AppUpdater.openInstallPermission(context) }, primary = true, focusRequester = first)
                    TvButton("Riprova", { scope.launch { AppUpdater.install(context, info!!) } })
                }
                is AppUpdater.State.Failed, is AppUpdater.State.UpToDate -> TvButton("Controlla di nuovo", { scope.launch { AppUpdater.check() } }, focusRequester = first)
                else -> {}
            }
            TvButton(if (state is AppUpdater.State.Available) "Più tardi" else "Chiudi", onLater, focusRequester = if (state is AppUpdater.State.Downloading || state is AppUpdater.State.Installing || state is AppUpdater.State.Checking || state is AppUpdater.State.Idle) first else null)
        }
        RequestFocusOnce(first, state::class)
    }
}
