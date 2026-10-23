package app.aether.tv.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.unit.dp
import app.aether.tv.BuildConfig
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.AetherDimens

private val libraries = listOf(
    "Jetpack Compose, AndroidX, Media3 (ExoPlayer)" to "Apache License 2.0 — Google",
    "OkHttp, Okio" to "Apache License 2.0 — Square",
    "Coil" to "Apache License 2.0 — Coil Contributors",
    "Kotlin, kotlinx.coroutines, kotlinx.serialization" to "Apache License 2.0 — JetBrains",
)

@Composable
fun AboutScreen(modifier: Modifier = Modifier) {
    val first = remember { FocusRequester() }
    RequestFocusOnce(first)
    LazyColumn(
        modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = AetherDimens.ScreenHorizontal, end = AetherDimens.ScreenHorizontal, top = AetherDimens.ScreenVertical, bottom = 56.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            FocusSurface({}, Modifier.fillMaxWidth(), focusRequester = first) {
                Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Aether per Android TV", style = MaterialTheme.typography.displayMedium, color = AetherColors.OnBackground)
                    Text("Versione ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.titleMedium, color = AetherColors.OnSurfaceMuted)
                    Text("Un media center per la TV, in italiano, che mostra e riproduce i contenuti dei tuoi addon Stremio. È un progetto indipendente e non ha legami con Stremio o con altri servizi.", style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnBackground)
                }
            }
        }
        item {
            Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Cosa fa e cosa no", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground)
                Text("Aether non fornisce nessun contenuto: cataloghi e sorgenti arrivano dagli addon che installi tu, e sei tu responsabile di ciò che installi e guardi.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
                Text("Non c'è nessun account e nessuna statistica. Cronologia, libreria e impostazioni restano su questa TV; gli indirizzi degli addon (che possono contenere chiavi) e la chiave TorBox sono cifrati con il Keystore di Android. L'unica richiesta volontaria a un servizio di Aether è «Salta intro», che chiede a IntroDB i tempi dell'episodio (codice IMDb, stagione ed episodio) e si può spegnere nelle impostazioni.", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
            }
        }
        item {
            Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Licenza", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground)
                Text("Aether è distribuito con licenza MIT (vedi il file LICENSE del repository).", style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
            }
        }
        item { Text("Librerie di terze parti", style = MaterialTheme.typography.titleLarge, color = AetherColors.OnBackground, modifier = Modifier.padding(horizontal = 4.dp)) }
        for ((name, license) in libraries) item {
            Column(Modifier.padding(horizontal = 4.dp)) {
                Text(name, style = MaterialTheme.typography.titleMedium, color = AetherColors.OnBackground)
                Text(license, style = MaterialTheme.typography.bodySmall, color = AetherColors.OnSurfaceMuted)
            }
        }
    }
}
