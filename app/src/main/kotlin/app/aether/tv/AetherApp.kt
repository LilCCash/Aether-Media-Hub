package app.aether.tv

import android.app.Application
import android.content.Context
import app.aether.core.AetherEngine
import app.aether.tv.data.AndroidSecretStore
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.disk.directory
import coil3.memory.MemoryCache
import coil3.request.allowRgb565
import coil3.request.crossfade

open class AetherApp : Application(), SingletonImageLoader.Factory {
    /** Built on first use, off the critical path of the first frame where possible. */
    val engine: AetherEngine by lazy { createEngine() }

    /** The remote is the only input: focus is always drawn and every element can take it (the tests force it too). */
    open val keyboardInputOnly: Boolean get() = !packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_TOUCHSCREEN)

    /** The tests build the engine on fake storage and a fake network. */
    protected open fun createEngine(): AetherEngine =
        AetherEngine(filesDir.resolve("aether"), AndroidSecretStore(this), traktClientId = BuildConfig.TRAKT_CLIENT_ID, downloadsDir = (getExternalFilesDir("Downloads") ?: filesDir.resolve("downloads"))).also { it.syncLibraryPolicy(); it.deviceDecoders = DeviceCapabilities.decoders(); it.deviceHdr = DeviceCapabilities.hdrFormats(this); it.trakt.bootstrap(); it.log.enabled = it.settings.value.value.privacy.diagnosticLog; it.log.mirror = { level, category, message -> if (level >= app.aether.core.diagnostics.LogLevel.WARNING) android.util.Log.w("Aether/$category", message) }; it.log.info("app", "avvio, versione ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}), Android ${android.os.Build.VERSION.SDK_INT}, ${android.os.Build.MODEL}") }

    /**
     * Posters and backdrops: decoded at the size of their card, RGB_565 where there is no transparency (half the memory), a modest
     * memory share (TV boxes often have 1–2 GB of RAM) and a disk cache that survives restarts.
     */
    override fun newImageLoader(context: PlatformContext): ImageLoader = ImageLoader.Builder(context)
        .crossfade(120)
        .allowRgb565(true)
        .memoryCache {
            // Lighter TVs keep fewer decoded pictures in memory.
            val light = app.aether.tv.ui.theme.Graphics.autoLevel(this) == app.aether.core.settings.GraphicsQuality.LIGHT
            MemoryCache.Builder().maxSizePercent(context, if (light) 0.08 else 0.15).build()
        }
        .diskCache { DiskCache.Builder().directory(cacheDir.resolve("images")).maxSizeBytes(200L * 1024 * 1024).build() }
        .build()
}

val Context.aether: AetherEngine get() = (applicationContext as AetherApp).engine
