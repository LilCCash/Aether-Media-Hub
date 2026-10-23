package app.aether.core.addons

import app.aether.core.net.AddonError
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpLimits
import app.aether.core.net.HttpRequest
import app.aether.core.net.HttpResponse
import app.aether.core.net.ResponseCache
import app.aether.core.model.AddonManifest
import app.aether.core.model.ResourcePath
import kotlin.coroutines.cancellation.CancellationException

/** Talks the Stremio addon HTTP protocol: manifest + resources, with validation, caching and error mapping. */
class AddonClient(
    private val http: HttpClient,
    private val cache: ResponseCache? = ResponseCache(),
    private val cacheEnabled: () -> Boolean = { true },
    private val defaultMaxAgeSeconds: (String) -> Int = { 300 },
) {
    enum class LoadMode {
        /** Fresh cache wins; stale cache is used when the network fails. */
        NORMAL,
        /** Bypass the cache for reading (pull-to-refresh) but still write it. */
        RELOAD,
        /** Never touch the cache. */
        NO_CACHE,
    }

    suspend fun fetchManifest(url: String, timeoutSeconds: Long = 12): AddonManifest {
        val response = http.send(HttpRequest(url, timeoutSeconds = timeoutSeconds, maxBytes = HttpLimits.MANIFEST))
        checkStatus(response)
        return try {
            ResponseDecoder.decodeManifest(response.text)
        } catch (error: ResponseDecodingError) {
            when (error) {
                ResponseDecodingError.NotJson ->
                    throw AddonError.InvalidManifest("La risposta non è JSON: l'URL non punta al manifest di un addon.")
                else -> throw AddonError.InvalidManifest("Il manifest non è un oggetto JSON valido.")
            }
        }
    }

    /** Fetches `{resource}/{type}/{id}[/{extra}].json` from the addon at [transport]. */
    suspend fun fetch(
        transport: String,
        path: ResourcePath,
        requestedMode: LoadMode = LoadMode.NORMAL,
        timeoutSeconds: Long = 15,
    ): AddonResponse {
        val mode = if (cacheEnabled()) requestedMode else LoadMode.NO_CACHE
        val url = ResourceUrlBuilder.url(transport, path) ?: throw AddonError.InvalidUrl("impossibile costruire l'URL della risorsa «${path.resource}»")
        var staleCandidate: ResponseCache.Hit? = null
        if (mode != LoadMode.NO_CACHE && cache != null) {
            val hit = cache.lookup(url)
            if (hit != null) {
                if (hit.isFresh && mode == LoadMode.NORMAL) {
                    runCatching { ResponseDecoder.decode(hit.body, path.resource) }.getOrNull()?.let { return it }
                }
                if (hit.usableAsStale) staleCandidate = hit
            }
        }
        try {
            val response = http.send(HttpRequest(url, timeoutSeconds = timeoutSeconds, maxBytes = HttpLimits.RESOURCE))
            checkStatus(response)
            val decoded = try {
                ResponseDecoder.decode(response.text, path.resource)
            } catch (error: ResponseDecodingError) {
                throw AddonError.MalformedResponse(error.detail)
            }
            if (mode != LoadMode.NO_CACHE && cache != null) {
                val maxAge = decoded.cache.maxAge ?: defaultMaxAgeSeconds(path.resource)
                cache.store(url, response.text, maxAge, decoded.cache.staleError ?: ResponseCache.DEFAULT_STALE_ERROR_SECONDS)
            }
            return decoded
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            val stale = staleCandidate
            if (stale != null && (error as? AddonError)?.isTransient == true) {
                runCatching { ResponseDecoder.decode(stale.body, path.resource) }.getOrNull()?.let { return it.copy(isStale = true) }
            }
            throw AddonError.from(error)
        }
    }

    private fun checkStatus(response: HttpResponse) {
        if (response.isSuccess) return
        if (response.status == 404) throw AddonError.NotFound
        throw AddonError.Http(response.status)
    }
}
