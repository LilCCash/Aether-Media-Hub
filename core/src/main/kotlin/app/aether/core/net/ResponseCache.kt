package app.aether.core.net

/** Memory cache of addon responses with freshness and stale-if-error (what the addon's `cacheMaxAge` hints allow). */
class ResponseCache(private val maxEntries: Int = 300, private val clock: () -> Long = System::currentTimeMillis) {
    private class Entry(val body: String, val storedAt: Long, val maxAgeMs: Long, val staleErrorMs: Long)

    data class Hit(val body: String, val isFresh: Boolean, val usableAsStale: Boolean)

    private val entries = object : LinkedHashMap<String, Entry>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>?): Boolean = size > maxEntries
    }

    @Synchronized
    fun lookup(key: String): Hit? {
        val entry = entries[key] ?: return null
        val age = clock() - entry.storedAt
        return Hit(entry.body, isFresh = age <= entry.maxAgeMs, usableAsStale = age <= entry.maxAgeMs + entry.staleErrorMs)
    }

    @Synchronized
    fun store(key: String, body: String, maxAgeSeconds: Int, staleErrorSeconds: Int = DEFAULT_STALE_ERROR_SECONDS) {
        entries[key] = Entry(body, clock(), maxAgeSeconds.coerceAtLeast(0) * 1000L, staleErrorSeconds.coerceAtLeast(0) * 1000L)
    }

    @Synchronized
    fun clear() = entries.clear()

    companion object {
        const val DEFAULT_STALE_ERROR_SECONDS = 24 * 3600
    }
}
