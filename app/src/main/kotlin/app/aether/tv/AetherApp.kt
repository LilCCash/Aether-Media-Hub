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

class AetherApp : Application(), SingletonImageLoader.Factory {
    /** Built on first use, off the critical path of the first frame where possible. */
    val engine: AetherEngine by lazy {
        AetherEngine(filesDir.resolve("aether"), AndroidSecretStore(this), traktClientId = BuildConfig.TRAKT_CLIENT_ID).also { it.syncLibraryPolicy(); it.trakt.bootstrap() }
    }

    /**
     * Posters and backdrops: decoded at the size of their card, RGB_565 where there is no transparency (half the memory), a modest
     * memory share (TV boxes often have 1–2 GB of RAM) and a disk cache that survives restarts.
     */
    override fun newImageLoader(context: PlatformContext): ImageLoader = ImageLoader.Builder(context)
        .crossfade(120)
        .allowRgb565(true)
        .memoryCache { MemoryCache.Builder().maxSizePercent(context, 0.15).build() }
        .diskCache { DiskCache.Builder().directory(cacheDir.resolve("images")).maxSizeBytes(200L * 1024 * 1024).build() }
        .build()
}

val Context.aether: AetherEngine get() = (applicationContext as AetherApp).engine
