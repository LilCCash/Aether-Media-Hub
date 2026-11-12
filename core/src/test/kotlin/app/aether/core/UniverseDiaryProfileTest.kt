package app.aether.core

import app.aether.core.library.DiaryEntry
import app.aether.core.library.DiaryStats
import app.aether.core.library.RatingComparison
import app.aether.core.profile.ProfileGenre
import app.aether.core.profile.ProfileSettings
import app.aether.core.profile.TasteVerdict
import app.aether.core.profile.TasteVote
import app.aether.core.universe.UniverseCatalog
import app.aether.core.universe.UniverseOrder
import app.aether.core.universe.UniverseProgress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class UniverseDiaryProfileTest {
    @Test fun universesLoadFromTheIphoneData() {
        assertEquals(15, UniverseCatalog.all.size)
        val mcu = UniverseCatalog.universe("mcu")!!
        assertEquals("tt0371746", mcu.ordered(UniverseOrder.RELEASE).first().id)
        assertEquals("tt0458339", mcu.ordered(UniverseOrder.CHRONOLOGICAL).first().id)
        assertEquals(mcu.entries.size, mcu.ordered(UniverseOrder.CHRONOLOGICAL).size)
        assertTrue(UniverseCatalog.containing("tt0371746").any { it.id == "mcu" })
        assertTrue(UniverseCatalog.linked("alien").any { it.first.id == "predator" })
        assertEquals("starwars", UniverseCatalog.search("star wars").first().id)
        val got = UniverseCatalog.universe("got")!!
        val p = UniverseProgress.compute(got, UniverseOrder.CHRONOLOGICAL, setOf("tt11198330"))
        assertEquals(1, p.watched); assertEquals("tt0944947", p.next?.id)
    }

    @Test fun diaryStatsAndComparison() {
        val zone = java.time.ZoneOffset.UTC
        fun at(y: Int, m: Int) = java.time.LocalDate.of(y, m, 10).atStartOfDay(zone).toInstant().toEpochMilli()
        val entries = listOf(
            DiaryEntry(metaId = "a", type = "movie", name = "A", genres = listOf("Dramma"), watchedAt = at(2025, 3), runtimeMinutes = 120, rating = 8, publicRating = 6.0, people = listOf("X")),
            DiaryEntry(metaId = "b", type = "series", name = "B", genres = listOf("Dramma", "Crime"), watchedAt = at(2025, 3), runtimeMinutes = 60, people = listOf("X")),
            DiaryEntry(metaId = "c", type = "movie", name = "C", genres = listOf("Horror"), watchedAt = at(2024, 12), runtimeMinutes = 90, rating = 4, publicRating = 7.5, rewatch = true),
        )
        val s = DiaryStats.compute(entries, 2025, zone)
        assertEquals(1, s.films); assertEquals(1, s.episodes); assertEquals(3, s.hours)
        assertEquals("Dramma" to 2, s.topGenres.first()); assertEquals("X" to 2, s.topPeople.first())
        assertEquals(2, s.perMonth[2])
        assertEquals(listOf(2025, 2024), DiaryStats.years(entries, zone))
        assertEquals(3.0, DiaryStats.compute(entries, null, zone).averageRating)
        assertEquals(listOf("c", "a"), RatingComparison.compute(entries).map { it.entry.metaId })
    }

    @Test fun libraryKeepsDiaryCollectionsAndAbandoned() {
        var clock = 1_000_000_000_000L
        val dir = java.nio.file.Files.createTempDirectory("lib").toFile()
        val store = app.aether.core.library.LibraryStore(app.aether.core.util.JsonFileStore(java.io.File(dir, "l.json"), app.aether.core.library.LibraryState.serializer()), now = { clock })
        val meta = app.aether.core.model.MetaItem("tt1", "movie", "Film")
        store.saveDiary(DiaryEntry(metaId = "tt1", type = "movie", name = "Film"))
        store.saveDiary(DiaryEntry(metaId = "tt1", type = "movie", name = "Film"))
        assertEquals(2, store.diary().size); assertTrue(store.diary().any { it.rewatch })
        val c = store.createCollection("  Horror anni 80 ")!!
        assertEquals(c.id, store.createCollection("horror anni 80")!!.id)
        store.toggleInCollection(c.id, meta)
        assertEquals(1, store.collectionsContaining("tt1").size)
        store.toggleInCollection(c.id, meta)
        assertTrue(store.collectionsContaining("tt1").isEmpty())
        store.recordProgress(meta, null, 600.0, 6000.0)
        assertTrue(store.abandoned().isEmpty())
        clock += 40L * 86_400_000
        assertEquals(listOf("tt1"), store.abandoned().map { it.metaId })
    }

    @Test fun profileTaste() {
        var p = ProfileSettings().toggleGenre(ProfileGenre.HORROR)
        p = p.vote(TasteVote("1", "movie", "A", genres = listOf("Comedy"), verdict = TasteVerdict.LIKE))
        p = p.vote(TasteVote("2", "movie", "B", genres = listOf("Comedy", "Drama"), verdict = TasteVerdict.LIKE))
        p = p.vote(TasteVote("3", "movie", "C", genres = listOf("Drama"), verdict = TasteVerdict.DISLIKE))
        assertEquals(listOf(ProfileGenre.HORROR, ProfileGenre.COMEDY), p.topGenres())
        assertEquals(2, p.likes.size)
        p = p.skip("9").skip("9")
        assertEquals(listOf("9"), p.skipped)
    }
}
