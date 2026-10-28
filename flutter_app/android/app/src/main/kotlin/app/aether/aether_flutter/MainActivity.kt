package app.aether.aether_flutter

import android.app.PictureInPictureParams
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
