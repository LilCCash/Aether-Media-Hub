package app.aether.tv.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.aether.tv.aether
import app.aether.tv.ui.components.AetherDialog
import app.aether.tv.ui.components.QrCode
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.theme.AetherColors
import fi.iki.elonen.NanoHTTPD
import kotlinx.coroutines.delay

/**
 * The TV side of «Configura dal telefono»: the QR code, the time left, the request of a phone to be approved and what the phone did.
 * The server lives exactly as long as this dialog.
 */
@Composable
fun PhoneConfigDialog(onDismiss: () -> Unit) {
    val engine = LocalContext.current.aether
    val server = remember { PhoneConfigServer(engine) }
    var address by remember { mutableStateOf<String?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    DisposableEffect(server) {
        try {
            server.start(PhoneConfigServer.SOCKET_TIMEOUT_MS, true)
            address = server.address
            if (address == null) problem = "La TV non è collegata a una rete locale (Wi-Fi o cavo)."
        } catch (e: Exception) {
            problem = "Non riesco ad aprire il collegamento locale."
        }
        onDispose { runCatching { server.stop() } }
    }
    LaunchedEffect(server) {
        while (true) {
            delay(1000)
            now = System.currentTimeMillis()
            if (server.session.isClosed) { runCatching { server.stop() }; onDismiss(); break }
        }
    }
    val pending by server.pending.collectAsState()
    val events by server.events.collectAsState()
    val close = remember { FocusRequester() }
    val allow = remember { FocusRequester() }

    AetherDialog("Configura dal telefono", { runCatching { server.stop() }; onDismiss() }, width = 900.dp) {
        val url = address
        if (url == null) {
            Text(problem ?: "Preparo il collegamento…", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(28.dp), verticalAlignment = Alignment.CenterVertically) {
                QrCode(url, size = 240.dp)
                Column(Modifier.width(520.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Inquadra il codice con la fotocamera del telefono, collegato alla stessa rete della TV.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
                    Text("Dal telefono puoi aggiungere e gestire gli addon, inserire le chiavi di TorBox, Real-Debrid, TMDB, TheTVDB, fanart.tv e MDBList, aggiungere playlist della TV in diretta e ripristinare un backup.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
                    Text(url.substringBefore("/s/") + "/…", style = MaterialTheme.typography.labelLarge, color = AetherColors.OnSurfaceFaint)
                    val left = ((server.session.expiresAt() - now) / 1000).coerceAtLeast(0)
                    Text("Il collegamento si chiude da solo tra ${left / 60}:${"%02d".format(left % 60)} (si allunga mentre lo usi).", style = MaterialTheme.typography.labelLarge, color = AetherColors.OnSurfaceFaint)
                }
            }
            for (event in events.takeLast(4)) Text("• ${event.text}", style = MaterialTheme.typography.bodyMedium, color = AetherColors.Success)
        }
        TvButton("Chiudi il collegamento", { runCatching { server.stop() }; onDismiss() }, focusRequester = close)
        RequestFocusOnce(close)
    }

    pending?.let { client ->
        AetherDialog("Collegare questo telefono?", { server.answer(false) }, width = 620.dp) {
            Text("Un dispositivo ($client) ha aperto la pagina di configurazione. Consenti solo se è il tuo telefono.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TvButton("Consenti", { server.answer(true) }, primary = true, focusRequester = allow, testTag = "phone.allow")
                TvButton("Rifiuta", { server.answer(false) })
            }
            RequestFocusOnce(allow)
        }
    }
}
