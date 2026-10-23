package app.aether.tv

import android.app.Application
import android.content.Context
import app.aether.core.AetherEngine
import app.aether.tv.data.AndroidSecretStore
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.disk.DiskCache
import coil.memory.MemoryCache

class AetherApp : Application(), ImageLoaderFactory {
    lateinit var engine: AetherEngine
        private set

    override fun onCreate() {
        super.onCreate()
        engine = AetherEngine(filesDir.resolve("aether"), AndroidSecretStore(this))
        engine.syncLibraryPolicy()
    }

    /** Posters and backdrops are cached on disk and in memory; a TV has little RAM, so the memory share stays modest. */
    override fun newImageLoader(): ImageLoader = ImageLoader.Builder(this)
        .crossfade(true)
        .respectCacheHeaders(false)
        .memoryCache { MemoryCache.Builder(this).maxSizePercent(0.18).build() }
        .diskCache { DiskCache.Builder().directory(cacheDir.resolve("images")).maxSizeBytes(200L * 1024 * 1024).build() }
        .build()
}

val Context.aether: AetherEngine get() = (applicationContext as AetherApp).engine
