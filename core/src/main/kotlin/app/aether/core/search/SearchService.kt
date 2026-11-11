package app.aether.core.search

import app.aether.core.addons.AddonService
import app.aether.core.addons.CatalogRef
import app.aether.core.addons.RequestPlanner
import app.aether.core.model.ExtraValue
import app.aether.core.model.MetaItem
import app.aether.core.net.AddonError
import java.text.Normalizer
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch

data class SearchRow(val ref: CatalogRef, val items: List<MetaItem>, val error: AddonError?, val isStale: Boolean) {
    val id: String get() = ref.id
}

data class SearchUpdate(val row: SearchRow, val completed: Int, val total: Int)

enum class SearchSort(val title: String) {
    RELEVANCE("Rilevanza"), TITLE("Titolo"), YEAR_DESCENDING("Anno"), RATING_DESCENDING("Valutazione");

    fun apply(items: List<MetaItem>): List<MetaItem> = when (this) {
        RELEVANCE -> items
        TITLE -> items.sortedBy { it.name.lowercase() }
        YEAR_DESCENDING -> items.sortedByDescending { it.year ?: 0 }
        RATING_DESCENDING -> items.sortedByDescending { it.ratingValue ?: 0.0 }
    }
}

/**
 * Remote search across every installed catalog that declares the `search` extra. Nothing is pretended: when no catalog supports
 * search, [searchableCatalogs] is empty and the UI says so.
 */
class SearchService(private val service: AddonService) {
    suspend fun searchableCatalogs(type: String? = null): List<CatalogRef> = RequestPlanner.searchCatalogs(service.handles(), type)

    /** One row per catalog as soon as that catalog answers; cancelling the collector abandons the requests (typing fast). */
    fun search(rawQuery: String, type: String? = null, perCatalogLimit: Int = 40): Flow<SearchUpdate> = callbackFlow {
        val query = normalisedQuery(rawQuery)
        if (query.isEmpty()) {
            close()
            return@callbackFlow
        }
        val job = launch {
            val refs = RequestPlanner.searchCatalogs(service.handles(), type)
            val total = refs.size
            var completed = 0
            val lock = Any()
            coroutineScope {
                for (ref in refs) {
                    launch {
                        val row = try {
                            val result = service.catalog(ref, listOf(ExtraValue("search", query)))
                            SearchRow(ref, result.items.take(perCatalogLimit), null, result.isStale)
                        } catch (error: Throwable) {
                            if (error is CancellationException) throw error
                            SearchRow(ref, emptyList(), AddonError.from(error), false)
                        }
                        val done = synchronized(lock) { ++completed }
                        trySend(SearchUpdate(row, done, total))
                    }
                }
            }
            close()
        }
        awaitClose { job.cancel() }
    }

    companion object {
        fun normalisedQuery(raw: String): String = raw.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
    }
}

/** Recognises the same title coming from different addons / id schemes. */
object MetaDeduper {
    /** Lowercase, diacritics stripped, punctuation removed, whitespace collapsed. */
    fun normalise(title: String): String {
        val folded = Normalizer.normalize(title, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase()
        val out = StringBuilder()
        var lastWasSpace = true
        for (c in folded) {
            if (c.isLetterOrDigit()) { out.append(c); lastWasSpace = false } else if (!lastWasSpace) { out.append(' '); lastWasSpace = true }
        }
        return out.toString().trim()
    }

    private fun titleKey(item: MetaItem): String {
        val title = normalise(item.name)
        return item.year?.let { "title:${item.type}|$title|$it" } ?: "title:${item.type}|$title"
    }

    /** Keeps the first occurrence, filling its empty fields from later duplicates (same IMDb id, or same type + title + year). */
    fun dedupe(items: List<MetaItem>): List<MetaItem> {
        val slots = ArrayList<MetaItem>()
        val imdbIndex = HashMap<String, Int>()
        val titleIndex = HashMap<String, Int>()
        for (item in items) {
            val imdb = item.imdbId
            val title = titleKey(item)
            var slot: Int? = imdb?.let { imdbIndex[it] }
            if (slot == null) {
                val found = titleIndex[title]
                if (found != null) {
                    val existing = slots[found].imdbId
                    if (existing == null || imdb == null || existing == imdb) slot = found
                }
            }
            if (slot != null) {
                slots[slot] = slots[slot].merging(item)
                if (imdb != null) imdbIndex.putIfAbsent(imdb, slot)
                titleIndex.putIfAbsent(title, slot)
            } else {
                slots.add(item)
                val index = slots.size - 1
                if (imdb != null) imdbIndex[imdb] = index
                titleIndex.putIfAbsent(title, index)
            }
        }
        return slots
    }

    /** Round-robin across rows so one chatty addon does not bury the others, then de-duplicated. */
    fun interleave(rows: List<List<MetaItem>>): List<MetaItem> {
        val merged = ArrayList<MetaItem>()
        var index = 0
        var added = true
        while (added) {
            added = false
            for (row in rows) if (index < row.size) { merged.add(row[index]); added = true }
            index++
        }
        return dedupe(merged)
    }
}
