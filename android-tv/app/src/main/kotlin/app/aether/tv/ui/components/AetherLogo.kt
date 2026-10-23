package app.aether.tv.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.aether.tv.R
import app.aether.tv.ui.theme.AetherColors
import kotlinx.coroutines.launch

private val whispers = listOf(
    "Ehi, mi hai toccato!",
    "Fai piano, sto guardando una serie.",
    "Hai già finito la serie? No? Allora continua a guardarla.",
    "Il telecomando non è un tasto per il turbo.",
    "Ancora un episodio e poi vado a dormire. Promesso.",
    "🍿 Il pop-corn è finito. Qualcuno è andato a prenderne altro?",
    "Sai che il divano ha un consumo di ore di sonno?",
)

/** The Aether logo; pressing OK on it a few times is worth a smile. */
@Composable
fun AetherLogo(modifier: Modifier = Modifier, focusRequester: FocusRequester? = null, size: Int = 96) {
    var taps by remember { mutableIntStateOf(0) }
    val spin = remember { Animatable(0f) }
    val pop = remember { Animatable(1f) }
    val scope = rememberCoroutineScope()
    val final = taps >= whispers.size + 2
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        FocusSurface(
            {
                taps += 1
                scope.launch { spin.snapTo(0f); spin.animateTo(360f, tween(if (final) 1400 else 600)) }
                scope.launch { pop.animateTo(1.25f, tween(120)); pop.animateTo(1f, tween(220)) }
            },
            focusRequester = focusRequester, testTag = "logo",
        ) {
            Image(painterResource(R.drawable.aether_logo), "Logo di Aether", Modifier.padding(8.dp).size(size.dp).rotate(spin.value).scale(pop.value))
        }
        Column {
            Text("Aether TV", style = MaterialTheme.typography.headlineMedium, color = AetherColors.OnBackground)
            val line = when {
                taps == 0 -> "Premi OK sul logo."
                taps <= whispers.size -> whispers[taps - 1]
                else -> "🎬 Hai trovato il segreto: ora ti meriti davvero un film. Buona visione!"
            }
            Text(line, style = MaterialTheme.typography.bodyMedium, color = AetherColors.OnSurfaceMuted)
        }
    }
}
