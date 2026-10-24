package app.aether.core

import app.aether.core.addons.AddonClient
import app.aether.core.addons.AddonRegistry
import app.aether.core.addons.AddonRegistryState
import app.aether.core.addons.AddonService
import app.aether.core.debrid.DebridResolver
import app.aether.core.debrid.TorBoxClient
import app.aether.core.library.LibraryPolicy
import app.aether.core.library.LibraryState
import app.aether.core.library.LibraryStore
import app.aether.core.metadata.MetadataEnrichment
import app.aether.core.net.HttpClient
import app.aether.core.net.NetworkPolicy
import app.aether.core.net.OkHttpTransport
import app.aether.core.net.ResponseCache
import app.aether.core.playback.PlaybackCapabilities
import app.aether.core.playback.StreamPreferences
import app.aether.core.search.SearchService
import app.aether.core.segments.IntroDbClient
import app.aether.core.settings.AppSettings
import app.aether.core.settings.SettingsStore
import app.aether.core.util.JsonFileStore
import app.aether.core.util.SecretStore
import java.io.File

/**
 * Everything the app needs, wired once: the addon engine, the library, the settings and the services. The Android app builds one of
 * these with its own storage directory and secret store; the tests build one on a temporary directory.
 */
class AetherEngine(
    dataDir: File,
    val secrets: SecretStore,
    http: HttpClient? = null,
) {
    val settings = SettingsStore(JsonFileStore(File(dataDir, "settings.json"), AppSettings.serializer()))

    private fun currentPolicy() = NetworkPolicy(allowLocalNetwork = settings.value.value.network.allowLocalNetwork)

    val http: HttpClient = http ?: OkHttpTransport(::currentPolicy)
    val cache = ResponseCache()
    val metadata = MetadataEnrichment(this.http, secrets) { settings.value.value.content.metadataLanguage }
    val client = AddonClient(
        this.http, cache,
        cacheEnabled = { settings.value.value.network.cacheResponses },
        defaultMaxAgeSeconds = { resource -> if (resource == "stream") 60 else settings.value.value.content.catalogRefreshMinutes * 60 },
    )
    val registry = AddonRegistry(
        JsonFileStore(File(dataDir, "addons.json"), AddonRegistryState.serializer()), secrets, client, ::currentPolicy,
    )
    val addons = AddonService(registry, client)
    val search = SearchService(addons)
    val library = LibraryStore(
        JsonFileStore(File(dataDir, "library.json"), LibraryState.serializer()),
        LibraryPolicy(watchedThreshold = settings.value.value.playback.watchedThreshold, recordHistory = settings.value.value.privacy.recordHistory),
    )
    val torBox = TorBoxClient(this.http, secrets)
    val debrid = DebridResolver(torBox)
    val introDb = IntroDbClient(this.http)

    fun syncLibraryPolicy() {
        val s = settings.value.value
        library.policy = library.policy.copy(watchedThreshold = s.playback.watchedThreshold, recordHistory = s.privacy.recordHistory)
    }

    /** The preferences the ranking of the sources uses, from the settings and the order of the installed addons. */
    suspend fun streamPreferences(languageFromSystem: String?): StreamPreferences {
        val s = settings.value.value
        val language = when (s.playback.preferredAudioLanguage) {
            "off" -> null
            "system" -> languageFromSystem
            else -> s.playback.preferredAudioLanguage
        }
        return StreamPreferences(
            qualityCap = s.playback.qualityCap,
            preferredLanguage = language,
            preferLanguage = s.playback.preferStreamsInPreferredLanguage,
            addonOrder = registry.all().map { it.id },
            ordering = s.playback.streamOrdering,
            capabilities = PlaybackCapabilities(
                debridAvailable = torBox.isConfigured,
                streamingServer = s.network.streamingServerUrl.trim().ifEmpty { null },
            ),
        )
    }

    /** The keys a backup may carry: TMDB, TheTVDB (with PIN) and TorBox. */
    fun backupKeys(): Map<String, String> = buildMap {
        secrets.get(MetadataEnrichment.TMDbKey)?.takeIf { it.isNotBlank() }?.let { put("tmdb", it) }
        secrets.get(MetadataEnrichment.TVDbKey)?.takeIf { it.isNotBlank() }?.let { put("tvdb", it) }
        secrets.get(MetadataEnrichment.TVDbPin)?.takeIf { it.isNotBlank() }?.let { put("tvdbPin", it) }
        secrets.get(MetadataEnrichment.FanartKey)?.takeIf { it.isNotBlank() }?.let { put("fanart", it) }
        secrets.get(TorBoxClient.KEY_SECRET)?.takeIf { it.isNotBlank() }?.let { put("torbox", it) }
    }

    /** Stores the keys of a backup so the services are configured by themselves; returns the names that were set. */
    fun applyBackupKeys(keys: Map<String, String>): List<String> {
        val done = ArrayList<String>()
        keys["tmdb"]?.let { secrets.put(MetadataEnrichment.TMDbKey, it.trim()); done.add("TMDB") }
        keys["tvdb"]?.let { secrets.put(MetadataEnrichment.TVDbKey, it.trim()); done.add("TheTVDB") }
        keys["tvdbPin"]?.let { secrets.put(MetadataEnrichment.TVDbPin, it.trim()) }
        keys["fanart"]?.let { secrets.put(MetadataEnrichment.FanartKey, it.trim()); done.add("fanart.tv") }
        keys["torbox"]?.let { try { torBox.saveKey(it); done.add("TorBox") } catch (_: IllegalArgumentException) { } }
        if (done.isNotEmpty()) metadata.clearCaches()
        return done
    }

    /** Restores a decoded backup: library (merged or replaced), addons and keys. Returns a sentence for the viewer. */
    suspend fun restoreBackup(contents: app.aether.core.library.BackupContents, replace: Boolean): String {
        if (replace) library.replace(contents.library) else library.merge(contents.library)
        var ok = 0
        var failed = 0
        for (url in contents.addonUrls) { try { registry.install(url); ok++ } catch (_: Throwable) { failed++ } }
        val keys = applyBackupKeys(contents.keys)
        return buildString {
            append(if (replace) "Libreria sostituita con il backup" else "Backup unito alla libreria")
            if (contents.addonUrls.isNotEmpty()) append(": $ok addon installati" + if (failed > 0) ", $failed non raggiungibili" else "")
            if (keys.isNotEmpty()) append(". Chiavi configurate: ${keys.joinToString(", ")}")
            append(".")
        }
    }
}
