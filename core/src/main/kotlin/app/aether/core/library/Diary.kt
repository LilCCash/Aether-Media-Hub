package app.aether.core.library

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneId

/** One viewing in the diary: when, how it went, what the viewer thought. Written by the viewer or by the player at the end. */
@Serializable
data class DiaryEntry(
    val id: String = java.util.UUID.randomUUID().toString(),
    val metaId: String,
    val type: String,
    val name: String,
    val poster: String? = null,
    val year: String? = null,
    val genres: List<String> = emptyList(),
    val watchedAt: Long = System.currentTimeMillis(),
    /** Half stars, 1…10 (0.5 to 5 stars); null = not rated. */
    val rating: Int? = null,
    val note: String = "",
    val rewatch: Boolean = false,
    val runtimeMinutes: Int? = null,
    /** Directors and main cast, to count who appears most. */
    val people: List<String> = emptyList(),
    /** «S01E02 · Title» for an episode. */
    val episodeLabel: String? = null,
    /** The public's rating (IMDb, 0–10), to compare with the viewer's. */
    val publicRating: Double? = null,
)

/** A list the viewer made («Da vedere con Marta», «Horror anni 80»…). */
@Serializable
data class LibraryCollection(
    val id: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    val items: List<CollectionItem> = emptyList(),
    val createdAt: Long = System.currentTimeMillis(),
)

@Serializable
data class CollectionItem(val id: String, val type: String, val name: String, val poster: String? = null)

/** The numbers of a year of viewing (or of all of them). */
data class DiaryStats(
    val films: Int,
    val episodes: Int,
    val minutes: Int,
    val rewatches: Int,
    val averageRating: Double?,
    val topGenres: List<Pair<String, Int>>,
    val topPeople: List<Pair<String, Int>>,
    val perMonth: List<Int>,
    val titles: Int,
) {
    val hours: Int get() = minutes / 60

    companion object {
        fun yearOf(millis: Long, zone: ZoneId = ZoneId.systemDefault()) = Instant.ofEpochMilli(millis).atZone(zone).year
        private fun monthOf(millis: Long, zone: ZoneId) = Instant.ofEpochMilli(millis).atZone(zone).monthValue

        fun compute(entries: List<DiaryEntry>, year: Int? = null, zone: ZoneId = ZoneId.systemDefault()): DiaryStats {
            val used = entries.filter { year == null || yearOf(it.watchedAt, zone) == year }
            fun top(lists: List<List<String>>) = lists.flatten().filter { it.isNotBlank() }.groupingBy { it }.eachCount().entries
                .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key }).take(5).map { it.key to it.value }
            val months = MutableList(12) { 0 }
            used.forEach { months[monthOf(it.watchedAt, zone) - 1]++ }
            val rated = used.mapNotNull { it.rating }
            return DiaryStats(
                films = used.count { it.type == "movie" }, episodes = used.count { it.type != "movie" },
                minutes = used.mapNotNull { it.runtimeMinutes }.sum(), rewatches = used.count { it.rewatch },
                averageRating = if (rated.isEmpty()) null else rated.average() / 2, topGenres = top(used.map { it.genres }),
                topPeople = top(used.map { it.people }), perMonth = months, titles = used.map { it.metaId }.distinct().size,
            )
        }

        fun years(entries: List<DiaryEntry>, zone: ZoneId = ZoneId.systemDefault()): List<Int> = entries.map { yearOf(it.watchedAt, zone) }.distinct().sortedDescending()
    }
}

/** The viewer's rating against the public's: how far apart, title by title, the biggest differences first. */
data class RatingComparison(val entry: DiaryEntry, val mine: Double, val public: Double) {
    val difference: Double get() = mine - public

    companion object {
        fun compute(entries: List<DiaryEntry>): List<RatingComparison> = entries
            .filter { it.rating != null && it.publicRating != null }
            .groupBy { it.metaId }.values.map { it.maxBy { e -> e.watchedAt } }
            .map { RatingComparison(it, it.rating!!.toDouble(), it.publicRating!!) }
            .sortedByDescending { kotlin.math.abs(it.difference) }
    }
}
