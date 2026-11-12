package app.aether.core.universe

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** A title that belongs to an universe: its IMDb id (the id the addons use), name, year, film or series. */
@Serializable
data class UniverseEntry(val id: String, val name: String, val year: Int, val series: Boolean) {
    val type: String get() = if (series) "series" else "movie"
    val poster: String get() = "https://images.metahub.space/poster/medium/$id/img"
    val background: String get() = "https://images.metahub.space/background/medium/$id/img"
}

enum class UniverseOrder(val title: String) { RELEASE("Ordine di uscita"), CHRONOLOGICAL("Ordine della storia") }

@Serializable
data class UniverseDefinition(
    val id: String,
    val name: String,
    val summary: String,
    /** The title whose artwork opens the universe page. */
    val hero: String,
    /** In order of release. */
    val entries: List<UniverseEntry>,
    /** Ids in the order of the story; titles not listed follow in order of release. Null = the same as release. */
    val chronological: List<String>? = null,
    val chronologicalNote: String? = null,
) {
    val films: List<UniverseEntry> get() = entries.filter { !it.series }
    val shows: List<UniverseEntry> get() = entries.filter { it.series }
    val years: IntRange? get() = entries.minOfOrNull { it.year }?.let { lo -> lo..entries.maxOf { it.year } }
    val heroBackground: String get() = "https://images.metahub.space/background/medium/$hero/img"

    fun ordered(order: UniverseOrder): List<UniverseEntry> {
        if (order == UniverseOrder.RELEASE || chronological == null) return entries.sortedWith(compareBy({ it.year }, { entries.indexOf(it) }))
        val byId = entries.associateBy { it.id }
        val seen = HashSet<String>()
        val result = chronological.mapNotNull { id -> byId[id]?.takeIf { seen.add(id) } }.toMutableList()
        entries.filter { seen.add(it.id) }.forEach { result += it }
        return result
    }
}

/** How far the viewer is in an universe, and what comes next in the chosen order. */
data class UniverseProgress(val watched: Int, val total: Int, val next: UniverseEntry?, val missing: List<UniverseEntry>) {
    val fraction: Double get() = if (total == 0) 0.0 else watched.toDouble() / total
    val percent: Int get() = Math.round(fraction * 100).toInt()
    val isComplete: Boolean get() = total > 0 && watched == total

    companion object {
        fun compute(universe: UniverseDefinition, order: UniverseOrder, watchedIds: Set<String>): UniverseProgress {
            val ordered = universe.ordered(order)
            val missing = ordered.filter { it.id !in watchedIds }
            return UniverseProgress(ordered.size - missing.size, ordered.size, missing.firstOrNull(), missing)
        }
    }
}

@Serializable
data class UniverseLink(val first: String, val second: String, val note: String)

@Serializable
private data class UniverseData(val universes: List<UniverseDefinition>, val links: List<UniverseLink>)

/** The universes of the iPhone app (the same editorial data, titles matched against Cinemeta). */
object UniverseCatalog {
    private val data: UniverseData by lazy {
        val text = UniverseCatalog::class.java.getResourceAsStream("/app/aether/core/universes.json")?.bufferedReader()?.use { it.readText() }
        if (text == null) UniverseData(emptyList(), emptyList()) else Json { ignoreUnknownKeys = true }.decodeFromString(UniverseData.serializer(), text)
    }

    val all: List<UniverseDefinition> get() = data.universes

    fun universe(id: String): UniverseDefinition? = all.firstOrNull { it.id == id }

    /** The universes an IMDb id belongs to. */
    fun containing(imdbId: String): List<UniverseDefinition> = all.filter { u -> u.entries.any { it.id == imdbId } }

    /** The universes linked to [id] (crossovers), with the reason. */
    fun linked(id: String): List<Pair<UniverseDefinition, String>> = data.links.mapNotNull { link ->
        val other = when (id) { link.first -> link.second; link.second -> link.first; else -> null } ?: return@mapNotNull null
        universe(other)?.let { it to link.note }
    }

    /** Universes whose name or one of whose titles contains the words (case and accents ignored), name matches first. */
    fun search(text: String): List<UniverseDefinition> {
        fun fold(s: String) = java.text.Normalizer.normalize(s.lowercase(), java.text.Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")
        val needle = fold(text).trim()
        if (needle.length < 2) return emptyList()
        val byName = all.filter { fold(it.name).contains(needle) || it.id == needle }
        return byName + all.filter { u -> u !in byName && u.entries.any { fold(it.name).contains(needle) } }
    }
}
