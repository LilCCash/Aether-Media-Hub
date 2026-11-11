package app.aether.core.search

import app.aether.core.model.MetaItem
import kotlin.math.abs

/**
 * "Consigliami": from the titles the viewer picked, builds a taste profile (genres, rating, years) and ranks a pool of other
 * titles against it. [boosted] holds `name|year` keys of titles an outside source (TMDB "similar") also suggests.
 */
object Recommender {
    fun key(meta: MetaItem) = "${meta.name.trim().lowercase()}|${meta.year ?: ""}"

    fun recommend(selected: List<MetaItem>, pool: List<MetaItem>, boosted: Set<String> = emptySet(), count: Int = 5): List<MetaItem> {
        if (selected.isEmpty()) return emptyList()
        val genreWeight = HashMap<String, Double>()
        for (m in selected) for (g in m.genres.map { it.lowercase() }) genreWeight[g] = (genreWeight[g] ?: 0.0) + 1.0 / selected.size
        val years = selected.mapNotNull { it.year }.sorted()
        val medianYear = years.getOrNull(years.size / 2)
        val taken = selected.map { it.id }.toSet() + selected.map { key(it) }
        return pool.asSequence()
            .filter { it.id !in taken && key(it) !in taken && !it.poster.isNullOrBlank() }
            .distinctBy { it.id }
            .map { c ->
                val genres = c.genres.map { it.lowercase() }
                val overlap = genres.sumOf { genreWeight[it] ?: 0.0 }
                var score = if (genres.isEmpty()) 0.0 else overlap / Math.sqrt(genres.size.toDouble())
                c.ratingValue?.let { score += 0.35 * (it / 10.0) }
                if (medianYear != null) c.year?.let { score += 0.15 * (1.0 - minOf(abs(it - medianYear), 40) / 40.0) }
                if (key(c) in boosted) score += 0.6
                c to score
            }
            .sortedByDescending { it.second }
            .take(count)
            .map { it.first }
            .toList()
    }
}
