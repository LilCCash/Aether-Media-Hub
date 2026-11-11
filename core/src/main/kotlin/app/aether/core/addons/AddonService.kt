package app.aether.core.addons

import app.aether.core.model.AddonStream
import app.aether.core.model.AddonSubtitle
import app.aether.core.model.ExtraValue
import app.aether.core.model.MetaItem
import app.aether.core.model.ResourceName
import app.aether.core.model.ResourcePath
import app.aether.core.net.AddonError
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeout

data class MetaResolution(
    val meta: MetaItem,
    /** Addon that supplied the detail (null when only the catalog preview was available). */
    val providerName: String?,
    val failures: List<AddonError>,
    val hadDetailProvider: Boolean,
)

data class CatalogResult(val items: List<MetaItem>, val isStale: Boolean)

data class StreamBatch(
    val addonId: String,
    val addonName: String,
    val streams: List<AddonStream>,
    val error: AddonError?,
    val isStale: Boolean,
)

/**
 * High level façade used by the view models: plans requests from manifests, runs them concurrently with per-request deadlines and a
 * global concurrency cap, and merges the results.
 */
class AddonService(
    val registry: AddonRegistry,
    val client: AddonClient,
    maxConcurrentRequests: Int = 6,
    private val requestTimeoutSeconds: Long = 15,
) {
    private val limiter = Semaphore(maxConcurrentRequests)

    suspend fun handles(): List<AddonHandle> = registry.handles()

    /** One request to one addon: concurrency cap, hard deadline, health bookkeeping. */
    private suspend fun perform(handle: AddonHandle, path: ResourcePath, mode: AddonClient.LoadMode): AddonResponse {
        try {
            val response = limiter.withPermit {
                withTimeout((requestTimeoutSeconds + 1) * 1000) {
                    client.fetch(handle.transportUrl, path, mode, requestTimeoutSeconds)
                }
            }
            registry.recordHealth(handle.id, null)
            return response
        } catch (error: Throwable) {
            if (error is CancellationException && error !is kotlinx.coroutines.TimeoutCancellationException) throw error
            val addonError = if (error is kotlinx.coroutines.TimeoutCancellationException) AddonError.Timeout else AddonError.from(error)
            registry.recordHealth(handle.id, if (addonError is AddonError.NotFound) null else addonError.message)
            throw addonError
        }
    }

    // MARK: Catalog

    suspend fun catalog(ref: CatalogRef, extra: List<ExtraValue> = emptyList(), mode: AddonClient.LoadMode = AddonClient.LoadMode.NORMAL): CatalogResult {
        val handle = handles().firstOrNull { it.id == ref.addonId } ?: throw AddonError.NotFound
        val path = ResourcePath(ResourceName.CATALOG, ref.catalog.type, ref.catalog.id, extra)
        if (!handle.addon.manifest.supports(path)) throw AddonError.Unsupported("Il catalogo non supporta i filtri richiesti.")
        val response = perform(handle, path, mode)
        val payload = response.payload as? AddonPayload.Metas ?: throw AddonError.MalformedResponse("tipo di risposta inatteso")
        return CatalogResult(payload.items, response.isStale)
    }

    // MARK: Meta

    /**
     * Resolves the detail page. Asks every addon that declares `meta` for the type/id concurrently; the first addon *in user order* that
     * answers wins, and missing fields are filled from [fallback] (the catalog preview the user picked) and lower-priority answers.
     */
    suspend fun meta(type: String, id: String, fallback: MetaItem? = null, mode: AddonClient.LoadMode = AddonClient.LoadMode.NORMAL): MetaResolution =
        coroutineScope {
            val path = ResourcePath(ResourceName.META, type, id)
            val candidates = RequestPlanner.addons(path, handles())
            if (candidates.isEmpty()) {
                return@coroutineScope MetaResolution(fallback ?: MetaItem(id, type, id), null, emptyList(), false)
            }
            val jobs = candidates.map { handle ->
                async {
                    try {
                        val payload = perform(handle, path, mode).payload as? AddonPayload.Meta
                        if (payload != null) Result.success(handle.addon.displayName to payload.item)
                        else Result.failure(AddonError.MalformedResponse("tipo di risposta inatteso"))
                    } catch (error: Throwable) {
                        if (error is CancellationException) throw error
                        Result.failure(error)
                    }
                }
            }
            val results = jobs.map { it.await() }
            var merged: MetaItem? = null
            var provider: String? = null
            val failures = ArrayList<AddonError>()
            for (result in results) {
                val value = result.getOrNull()
                if (value != null) {
                    if (merged == null) { merged = value.second; provider = value.first } else merged = merged.merging(value.second)
                } else {
                    (result.exceptionOrNull() as? AddonError)?.let { failures.add(it) }
                }
            }
            var resolved = merged ?: return@coroutineScope MetaResolution(fallback ?: MetaItem(id, type, id), null, failures, true)
            if (fallback != null) resolved = resolved.merging(fallback)
            MetaResolution(resolved, provider, failures, true)
        }

    // MARK: Streams

    /**
     * Streams from every addon that declares `stream` for this type/video id, emitted as each addon answers. Cancelling the collector
     * cancels the outstanding requests. A 404 means "no streams", not an error.
     */
    fun streams(type: String, videoId: String, mode: AddonClient.LoadMode = AddonClient.LoadMode.NORMAL): Flow<StreamBatch> = callbackFlow {
        val path = ResourcePath(ResourceName.STREAM, type, videoId)
        val candidates = RequestPlanner.addons(path, handles())
        val job = launch {
            coroutineScope {
                for (handle in candidates) {
                    launch {
                        val batch = try {
                            val payload = perform(handle, path, mode)
                            val items = (payload.payload as? AddonPayload.Streams)?.items.orEmpty().map {
                                it.copy(addonId = handle.addon.id, addonName = handle.addon.displayName)
                            }
                            StreamBatch(handle.id, handle.addon.displayName, items, null, payload.isStale)
                        } catch (error: Throwable) {
                            if (error is CancellationException) throw error
                            val addonError = AddonError.from(error)
                            StreamBatch(handle.id, handle.addon.displayName, emptyList(), if (addonError is AddonError.NotFound) null else addonError, false)
                        }
                        trySend(batch)
                    }
                }
            }
            close()
        }
        awaitClose { job.cancel() }
    }

    // MARK: Subtitles

    /**
     * Subtitles for a video from every addon that declares `subtitles` for the type and the id prefix, in addon order, de-duplicated by
     * URL. The hash, size and file name come from the stream's hints when known.
     */
    suspend fun subtitles(type: String, videoId: String, stream: AddonStream?): List<AddonSubtitle> = coroutineScope {
        val extras = ArrayList<ExtraValue>()
        stream?.behaviorHints?.videoHash?.let { extras.add(ExtraValue("videoHash", it)) }
        stream?.behaviorHints?.videoSize?.let { extras.add(ExtraValue("videoSize", it.toString())) }
        stream?.behaviorHints?.filename?.let { extras.add(ExtraValue("filename", it)) }
        val path = ResourcePath(ResourceName.SUBTITLES, type, videoId, extras)
        val barePath = ResourcePath(ResourceName.SUBTITLES, type, videoId)
        val candidates = RequestPlanner.addons(barePath, handles()).filter { declaresSubtitleId(it.addon.manifest, videoId) }
        val jobs = candidates.map { handle ->
            async {
                try {
                    val items = (perform(handle, path, AddonClient.LoadMode.NORMAL).payload as? AddonPayload.Subtitles)?.items.orEmpty()
                    items.map { it.copy(addonName = handle.addon.displayName) }
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    emptyList()
                }
            }
        }
        val seen = HashSet<String>()
        jobs.flatMap { it.await() }.filter { seen.add(it.url) }
    }

    companion object {
        /**
         * True when the id starts with one of the prefixes the addon declares for `subtitles` (the resource's own, else the manifest's);
         * no prefixes at all means every id.
         */
        fun declaresSubtitleId(manifest: app.aether.core.model.AddonManifest, id: String): Boolean {
            val resource = manifest.resource(ResourceName.SUBTITLES) ?: return false
            val declared = resource.idPrefixes ?: manifest.idPrefixes
            if (declared.isNullOrEmpty()) return true
            return declared.any { id.startsWith(it) }
        }
    }
}
