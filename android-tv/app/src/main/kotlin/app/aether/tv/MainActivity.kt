package app.aether.tv

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.aether.core.addons.AddonUrl
import app.aether.tv.nav.AetherNav
import app.aether.tv.ui.theme.AetherTheme

class MainActivity : ComponentActivity() {
    private var addonInput by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        addonInput = addonFrom(intent)
        setContent {
            val settings by aether.settings.value.collectAsStateWithLifecycle()
            AetherTheme(accent = Color(settings.appearance.accent.argb), animations = settings.appearance.animationsEnabled) {
                AetherNav(initialAddonInput = addonInput)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A link opened while the app runs (stremio:// or aether://): the addons screen asks the viewer before installing.
        addonFrom(intent)?.let { Session.pendingAddonInput = it; addonInput = it }
    }

    private fun addonFrom(intent: Intent?): String? = intent?.dataString?.let { AddonUrl.installUrlFromDeepLink(it) }
}
