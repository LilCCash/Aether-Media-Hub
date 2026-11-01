package app.aether.aether_flutter

import android.app.PictureInPictureParams
import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts Flutter and the one piece of Android-only behaviour Aether needs from the activity: Picture in Picture. The Flutter side
 * asks with `enter`; the activity reports `pipChanged` so the player can hide its controls while it is a floating window.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** Set by the player while a video plays and «Picture-in-Picture automatico» is on: leaving the app then floats the video. */
    private var autoPip = false

    /** The launcher icons: each one is an alias of this activity in the manifest, and only one is enabled at a time. */
    private val iconStyles = listOf("Default", "Light", "Dark", "Cinema", "Halloween", "Natale", "Western", "SciFi", "Giallo")

    private fun iconAlias(style: String) = ComponentName(this, "${MainActivity::class.java.`package`?.name ?: packageName}.Icon$style")

    private fun currentIconStyle(): String {
        val pm = packageManager
        val explicit = iconStyles.firstOrNull {
            it != "Default" && pm.getComponentEnabledSetting(iconAlias(it)) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        }
        return explicit ?: "Default"
    }

    private fun setIconStyle(style: String): Boolean {
        if (!iconStyles.contains(style)) return false
        val pm = packageManager
        // The new one is switched on first, so the app never has no launcher entry.
        pm.setComponentEnabledSetting(iconAlias(style), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
        for (other in iconStyles) {
            if (other != style) {
                pm.setComponentEnabledSetting(iconAlias(other), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
            }
        }
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.aether/icon").setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> result.success(currentIconStyle())
                "set" -> result.success(setIconStyle(call.argument<String>("style") ?: "Default"))
                else -> result.notImplemented()
            }
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.aether/pip").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "enter" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                            result.error("unsupported", "Picture in Picture needs Android 8 or later", null)
                        } else {
                            val w = call.argument<Int>("width") ?: 16
                            val h = call.argument<Int>("height") ?: 9
                            val params = PictureInPictureParams.Builder().setAspectRatio(Rational(w, h)).build()
                            try {
                                result.success(enterPictureInPictureMode(params))
                            } catch (e: IllegalStateException) {
                                result.error("unsupported", e.message, null)
                            }
                        }
                    }
                    "setAuto" -> {
                        autoPip = call.argument<Boolean>("on") ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPip && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build())
            } catch (e: IllegalStateException) {
                // the device does not allow it: nothing to do
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }
}
