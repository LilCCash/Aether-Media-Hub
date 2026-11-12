package app.aether.tv

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.background
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
        setContent { AetherRoot(addonInput, (application as AetherApp).keyboardInputOnly) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A link opened while the app runs (stremio:// or aether://): the addons screen asks the viewer before installing.
        addonFrom(intent)?.let { Session.pendingAddonInput = it; addonInput = it }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        val allowed = aether.settings.value.value.playback.pictureInPicture
        if (Session.playerActive && allowed && Build.VERSION.SDK_INT >= 26 && packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            runCatching { enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()) }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        Session.inPictureInPicture.value = isInPictureInPictureMode
    }

    private fun addonFrom(intent: Intent?): String? = intent?.dataString?.let { AddonUrl.installUrlFromDeepLink(it) }
}


/** The whole app: theme, background and navigation (the tour tests compose it the same way). */
@androidx.compose.runtime.Composable
fun AetherRoot(addonInput: String?, keyboardInputOnly: Boolean) {
    val context = androidx.compose.ui.platform.LocalContext.current
    // On a TV without a touchscreen the input is the remote: Compose is told so, and every button can take the focus.
    val inputMode = androidx.compose.ui.platform.LocalInputModeManager.current
    if (keyboardInputOnly) androidx.compose.runtime.SideEffect { inputMode.requestInputMode(androidx.compose.ui.input.InputMode.Keyboard) }
    val settings by context.aether.settings.value.collectAsStateWithLifecycle()
    val accent = Color(settings.appearance.accent.argb)
    val autoLevel = androidx.compose.runtime.remember { app.aether.tv.ui.theme.Graphics.autoLevel(context) }
    val graphics = androidx.compose.runtime.remember(settings.appearance) { app.aether.tv.ui.theme.Graphics.resolve(settings.appearance, autoLevel) }
    val configuration = androidx.compose.ui.platform.LocalConfiguration.current
    val pct = settings.appearance.overscanPercent.coerceIn(0, 6)
    val overscan = app.aether.tv.ui.theme.Overscan((configuration.screenWidthDp * pct / 100).dp, (configuration.screenHeightDp * pct / 100).dp)
    AetherTheme(accent = accent, animations = settings.appearance.animationsEnabled, corner = settings.appearance.corners.dp.dp, graphics = graphics, overscan = overscan) {
        androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.fillMaxSize().background(app.aether.tv.ui.theme.AetherColors.Background)) {
            app.aether.tv.ui.theme.AppBackdrop(settings.appearance.background, accent, settings.appearance.animationsEnabled)
            AetherNav(initialAddonInput = addonInput)
        }
    }
}
