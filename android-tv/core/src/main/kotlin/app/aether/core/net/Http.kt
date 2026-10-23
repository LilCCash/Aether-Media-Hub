package app.aether.core.net

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

data class HttpRequest(
    val url: String,
    val method: String = "GET",
    val headers: Map<String, String> = emptyMap(),
    val body: String? = null,
    val contentType: String? = null,
    val timeoutSeconds: Long = 15,
    val maxBytes: Int = HttpLimits.RESOURCE,
)

data class HttpResponse(val status: Int, val body: ByteArray, val headers: Map<String, String> = emptyMap()) {
    val isSuccess: Boolean get() = status in 200..299
    val text: String get() = body.toString(Charsets.UTF_8)
}

object HttpLimits {
    const val MANIFEST = 1 * 1024 * 1024
    const val RESOURCE = 8 * 1024 * 1024
    const val SMALL = 256 * 1024
}

/** The transport the addon engine and the services use; tests replace it. */
fun interface HttpClient {
    suspend fun send(request: HttpRequest): HttpResponse
}

/** OkHttp transport: cancellable, size-capped, redirects limited to http(s) and re-checked by [policy]. */
class OkHttpTransport(
    private val policy: () -> NetworkPolicy = { NetworkPolicy() },
    base: OkHttpClient = OkHttpClient(),
) : HttpClient {
    private val client: OkHttpClient = base.newBuilder()
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    override suspend fun send(request: HttpRequest): HttpResponse {
        policy().check(request.url)?.let { throw AddonError.Blocked(it) }
        val builder = Request.Builder().url(request.url)
        for ((name, value) in request.headers) builder.header(name, value)
        if (request.headers.keys.none { it.equals("User-Agent", true) }) builder.header("User-Agent", "Aether-AndroidTV/1.0")
        if (request.method == "POST") {
            val type = (request.contentType ?: "application/json").toMediaType()
            builder.post((request.body ?: "").toRequestBody(type))
        } else if (request.method != "GET") {
            builder.method(request.method, (request.body ?: "").toRequestBody())
        }
        val call = client.newBuilder()
            .callTimeout(request.timeoutSeconds, TimeUnit.SECONDS)
            .connectTimeout(minOf(request.timeoutSeconds, 10), TimeUnit.SECONDS)
            .readTimeout(request.timeoutSeconds, TimeUnit.SECONDS)
            .build()
            .newCall(builder.build())
        val response = try {
            call.await()
        } catch (error: Throwable) {
            throw AddonError.from(error)
        }
        response.use {
            // After redirects the final address is checked too.
            policy().check(it.request.url.toString())?.let { reason -> throw AddonError.Blocked(reason) }
            val source = it.body?.source()
            val buffer = okio.Buffer()
            var total = 0L
            if (source != null) {
                while (true) {
                    val read = source.read(buffer, 8192)
                    if (read < 0) break
                    total += read
                    if (total > request.maxBytes) throw AddonError.ResponseTooLarge(request.maxBytes)
                }
            }
            val headers = it.headers.toMultimap().mapValues { entry -> entry.value.firstOrNull().orEmpty() }
            return HttpResponse(it.code, buffer.readByteArray(), headers)
        }
    }

    private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (!continuation.isCancelled) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response)
            }
        })
        continuation.invokeOnCancellation { cancel() }
    }
}
