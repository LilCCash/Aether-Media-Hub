package app.aether.core.addons

import app.aether.core.model.AddonManifest
import app.aether.core.model.ManifestCatalog
import app.aether.core.net.AddonError
import app.aether.core.net.NetworkPolicy
import app.aether.core.util.JsonFileStore
import app.aether.core.util.SecretStore
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable

/**
 * A persisted addon. The transport URL (which may embed API keys) is *not* stored here: it lives in the [SecretStore] under
 * [secretKey]. Only the host is kept for display.
 */
@Serializable
data class InstalledAddon(
    val id: String,
    val manifest: AddonManifest,
    val host: String,
    val fingerprint: String,
    val isEnabled: Boolean = true,
    val installedAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val lastRefreshAt: Long? = null,
    val lastError: String? = null,
    /** Catalog keys (`type/id`) the user hid from Home / Discover. */
    val hiddenCatalogs: List<String> = emptyList(),
    val nameOverride: String? = null,
    val isLocalNetwork: Boolean = false,
    val isOfficial: Boolean = false,
    /** The secret URL is missing (restored from a backup, store cleared): the addon must be added again. */
    val needsReinstall: Boolean = false,
) {
    val displayName: String get() = nameOverride?.takeIf { it.isNotEmpty() } ?: manifest.name
    val secretKey: String get() = AddonRegistry.SECRET_PREFIX + id
    fun isCatalogVisible(catalog: ManifestCatalog): Boolean = catalog.key !in hiddenCatalogs
}

/** Everything the request layer needs to talk to one addon. */
data class AddonHandle(val addon: InstalledAddon, val transportUrl: String) {
    val id: String get() = addon.id
}

sealed class AddonInstallWarning {
    object UnknownAddon : AddonInstallWarning()
    object P2p : AddonInstallWarning()
    object Adult : AddonInstallWarning()
    object LocalNetwork : AddonInstallWarning()
}

data class AddonInstallPreview(
    val transportUrl: String,
    val manifest: AddonManifest,
    val warnings: List<AddonInstallWarning>,
    /** Non-null when an addon with the same transport URL is already installed (installing updates it). */
    val existing: InstalledAddon?,
    val isOfficial: Boolean,
)

@Serializable
data class AddonRegistryState(val schemaVersion: Int = 1, val addons: List<InstalledAddon> = emptyList())

object KnownAddons {
    /** Stremio's public metadata addon. Offered as a recommendation; never installed silently. */
    const val CINEMETA_MANIFEST_URL = "https://v3-cinemeta.strem.io/manifest.json"
    const val CINEMETA_ID = "com.linvo.cinemeta"
    const val CINEMETA_HOST = "v3-cinemeta.strem.io"

    fun isOfficial(manifest: AddonManifest, url: String): Boolean =
        manifest.id == CINEMETA_ID && AddonUrl.displayHost(url).lowercase() == CINEMETA_HOST && url.lowercase().startsWith("https://")
}

/** Installed-addon database: all mutations are serialised and every change is persisted. */
class AddonRegistry(
    private val store: JsonFileStore<AddonRegistryState>,
    private val secrets: SecretStore,
    private val client: AddonClient,
    private val policy: () -> NetworkPolicy,
    private val newId: () -> String = { java.util.UUID.randomUUID().toString() },
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val lock = Mutex()
    private var addons: MutableList<InstalledAddon> = mutableListOf()
    private val urls = HashMap<String, String>()
    private var loaded = false

    private val _revision = kotlinx.coroutines.flow.MutableStateFlow(0L)

    /** Increases after every change to the installed addons: the screens that show their catalogs reload. */
    val revision: kotlinx.coroutines.flow.StateFlow<Long> get() = _revision

    /** Loads persisted addons and their secret URLs. Safe to call repeatedly. */
    suspend fun load(): List<InstalledAddon> = lock.withLock { loadLocked(); addons.toList() }

    private fun loadLocked() {
        if (loaded) return
        loaded = true
        addons = (store.load() ?: AddonRegistryState()).addons.toMutableList()
        urls.clear()
        var changed = false
        for (index in addons.indices) {
            val addon = addons[index]
            val url = secrets.get(addon.secretKey)
            if (url != null) {
                urls[addon.id] = url
                if (addon.needsReinstall) { addons[index] = addon.copy(needsReinstall = false); changed = true }
            } else if (!addon.needsReinstall) {
                addons[index] = addon.copy(needsReinstall = true)
                changed = true
            }
        }
        if (changed) persist()
    }

    suspend fun all(): List<InstalledAddon> = lock.withLock { loadLocked(); addons.toList() }

    suspend fun addon(id: String): InstalledAddon? = lock.withLock { loadLocked(); addons.firstOrNull { it.id == id } }

    /** Enabled, usable addons in user order, ready for requests. */
    suspend fun handles(includeDisabled: Boolean = false): List<AddonHandle> = lock.withLock {
        loadLocked()
        addons.mapNotNull { addon ->
            val url = urls[addon.id]
            if ((!includeDisabled && !addon.isEnabled) || addon.needsReinstall || url == null) null else AddonHandle(addon, url)
        }
    }

    /** The secret URL, for copying the addon link or opening its configuration page. Never log it. */
    suspend fun transportUrl(id: String): String? = lock.withLock { loadLocked(); urls[id] }

    // MARK: Install

    /** Fetches and validates the manifest without changing any state. */
    suspend fun preview(input: String): AddonInstallPreview {
        load()
        val url = AddonUrl.parseInstallInput(input)
        policy().check(url)?.let { throw AddonError.Blocked(it) }
        val manifest = client.fetchManifest(url)
        if (manifest.behaviorHints.configurationRequired) throw AddonError.ConfigurationRequired
        val fingerprint = AddonUrl.sha256Hex(AddonUrl.canonicalKey(url))
        val existing = lock.withLock { addons.firstOrNull { it.fingerprint == fingerprint } }
        val official = KnownAddons.isOfficial(manifest, url)
        val warnings = ArrayList<AddonInstallWarning>()
        if (!official) warnings.add(AddonInstallWarning.UnknownAddon)
        if (manifest.behaviorHints.p2p) warnings.add(AddonInstallWarning.P2p)
        if (manifest.behaviorHints.adult) warnings.add(AddonInstallWarning.Adult)
        if (isLocal(url)) warnings.add(AddonInstallWarning.LocalNetwork)
        return AddonInstallPreview(url, manifest, warnings, existing, official)
    }

    suspend fun install(preview: AddonInstallPreview): InstalledAddon = lock.withLock {
        loadLocked()
        val fingerprint = AddonUrl.sha256Hex(AddonUrl.canonicalKey(preview.transportUrl))
        val index = addons.indexOfFirst { it.fingerprint == fingerprint }
        val result: InstalledAddon
        if (index >= 0) {
            val updated = addons[index].copy(manifest = preview.manifest, updatedAt = now(), lastRefreshAt = now(), lastError = null, needsReinstall = false)
            addons[index] = updated
            result = updated
        } else {
            val id = newId()
            result = InstalledAddon(
                id = id, manifest = preview.manifest, host = AddonUrl.displayHost(preview.transportUrl), fingerprint = fingerprint,
                installedAt = now(), updatedAt = now(), lastRefreshAt = now(), isLocalNetwork = isLocal(preview.transportUrl),
                isOfficial = preview.isOfficial,
            )
            addons.add(result)
        }
        secrets.put(result.secretKey, preview.transportUrl)
        urls[result.id] = preview.transportUrl
        persist()
        result
    }

    suspend fun install(input: String): InstalledAddon = install(preview(input))

    // MARK: Changes

    private fun update(id: String, change: (InstalledAddon) -> InstalledAddon) {
        val index = addons.indexOfFirst { it.id == id }
        if (index < 0) return
        addons[index] = change(addons[index])
        persist()
    }

    suspend fun setEnabled(enabled: Boolean, id: String) = lock.withLock { loadLocked(); update(id) { it.copy(isEnabled = enabled) } }

    suspend fun setNameOverride(name: String?, id: String) =
        lock.withLock { loadLocked(); update(id) { it.copy(nameOverride = name?.trim()?.takeIf { n -> n.isNotEmpty() }) } }

    suspend fun setCatalogVisible(visible: Boolean, catalogKey: String, id: String) = lock.withLock {
        loadLocked()
        update(id) { addon ->
            val hidden = addon.hiddenCatalogs.toMutableList()
            if (visible) hidden.remove(catalogKey) else if (catalogKey !in hidden) hidden.add(catalogKey)
            addon.copy(hiddenCatalogs = hidden)
        }
    }

    /** Moves an addon one place up (`-1`) or down (`+1`); the order of the list is the user's priority. */
    suspend fun move(id: String, delta: Int) = lock.withLock {
        loadLocked()
        val from = addons.indexOfFirst { it.id == id }
        val to = from + delta
        if (from < 0 || to < 0 || to >= addons.size) return@withLock
        val item = addons.removeAt(from)
        addons.add(to, item)
        persist()
    }

    suspend fun uninstall(id: String) = lock.withLock {
        loadLocked()
        val addon = addons.firstOrNull { it.id == id } ?: return@withLock
        secrets.remove(addon.secretKey)
        urls.remove(id)
        addons.removeAll { it.id == id }
        persist()
    }

    suspend fun removeAll() = lock.withLock {
        loadLocked()
        for (addon in addons) secrets.remove(addon.secretKey)
        urls.clear()
        addons.clear()
        persist()
    }

    data class RefreshOutcome(val id: String, val previousVersion: String, val newVersion: String?, val error: String?) {
        val versionChanged: Boolean get() = newVersion != null && newVersion != previousVersion
    }

    /** Re-reads the manifest of one addon (catalogs and resources can change when the addon is updated). */
    suspend fun refresh(id: String): RefreshOutcome? {
        val (addon, url) = lock.withLock { loadLocked(); val a = addons.firstOrNull { it.id == id }; a to urls[id] }
        if (addon == null) return null
        if (url == null) return RefreshOutcome(id, addon.manifest.version, null, "Indirizzo dell'addon mancante: reinstallalo.")
        return try {
            policy().check(url)?.let { throw AddonError.Blocked(it) }
            val manifest = client.fetchManifest(url)
            lock.withLock {
                update(id) { it.copy(manifest = manifest, updatedAt = now(), lastRefreshAt = now(), lastError = null) }
            }
            RefreshOutcome(id, addon.manifest.version, manifest.version, null)
        } catch (error: Throwable) {
            val message = AddonError.from(error).message
            lock.withLock { update(id) { it.copy(lastError = message) } }
            RefreshOutcome(id, addon.manifest.version, null, message)
        }
    }

    suspend fun refreshAll(): List<RefreshOutcome> = all().mapNotNull { refresh(it.id) }

    /** Health bookkeeping after a request: shown on the addons screen, never changes behaviour. */
    suspend fun recordHealth(id: String, error: String?) = lock.withLock {
        loadLocked()
        val index = addons.indexOfFirst { it.id == id }
        if (index >= 0 && addons[index].lastError != error) {
            addons[index] = addons[index].copy(lastError = error)
            persist()
        }
    }

    private fun isLocal(url: String): Boolean = NetworkPolicy(allowLocalNetwork = false).check(url) is AddonError.BlockReason.PrivateAddress ||
        NetworkPolicy(allowLocalNetwork = false).check(url) is AddonError.BlockReason.LocalHostname

    private fun persist() {
        store.save(AddonRegistryState(addons = addons.toList()))
        _revision.value = _revision.value + 1
    }

    companion object {
        const val SECRET_PREFIX = "addon.transport."
    }
}
