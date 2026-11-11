package app.aether.core

import app.aether.core.library.BackupCodec
import app.aether.core.library.BackupError
import app.aether.core.library.LibraryMerge
import app.aether.core.library.LibraryPolicy
import app.aether.core.library.LibraryState
import app.aether.core.library.LibraryStore
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.core.util.JsonFileStore
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LibraryTest {
    private var clock = 1_000_000L
    private fun store(dir: File = createTempDirectory("lib").toFile(), policy: LibraryPolicy = LibraryPolicy()) =
        LibraryStore(JsonFileStore(File(dir, "library.json"), LibraryState.serializer()), policy) { clock }

    private val movie = MetaItem("tt1", "movie", "Film Uno", poster = "https://p/1")
    private val show = MetaItem("tt2", "series", "Serie Due", poster = "https://p/2")
    private val ep1 = Video("tt2:1:1", "Primo", season = 1, episode = 1)
    private val ep2 = Video("tt2:1:2", "Secondo", season = 1, episode = 2)

    @Test fun watchlistAndFavoritesAreIndependentAndRemovalLeavesATombstone() {
        val library = store()
        library.setWatchlist(true, movie)
        library.setFavorite(true, movie)
        assertEquals(listOf("tt1"), library.watchlist().map { it.id })
        library.setWatchlist(false, movie)
        assertTrue(library.watchlist().isEmpty())
        assertTrue(library.isFavorite("tt1"))
        library.setFavorite(false, movie)
        assertNull(library.entry("tt1"))
        assertTrue(library.snapshot().entries["tt1"]!!.isRemoved, "kept as a tombstone so a merge does not bring it back")
    }

    @Test fun progressBelowTheMinimumIsNotRecordedAndCompletionCrossesTheThreshold() {
        val library = store()
        assertFalse(library.recordProgress(movie, null, 3.0, 7200.0))
        assertNull(library.progress("tt1", "tt1"))
        assertFalse(library.recordProgress(movie, null, 120.0, 7200.0))
        assertEquals(120.0, library.resumePosition("tt1", "tt1"))
        assertTrue(library.recordProgress(movie, null, 6600.0, 7200.0), "crossing 90% is reported once")
        assertFalse(library.recordProgress(movie, null, 6700.0, 7200.0))
        assertNull(library.resumePosition("tt1", "tt1"), "a finished film is not resumed")
        clock += 10
        library.recordProgress(movie, null, 100.0, 7200.0)
        assertFalse(library.progress("tt1", "tt1")!!.isCompleted, "starting over clears the watched flag")
    }

    @Test fun continueWatchingShowsOneUnfinishedItemPerTitleNewestFirst() {
        val library = store()
        library.recordProgress(movie, null, 300.0, 7200.0)
        clock += 100
        library.recordProgress(show, ep1, 200.0, 2400.0)
        clock += 100
        library.recordProgress(show, ep2, 50.0, 2400.0)
        val items = library.continueWatching()
        assertEquals(listOf("tt2", "tt1"), items.map { it.metaId })
        assertEquals("tt2:1:2", items.first().videoId)
        library.dismissFromContinueWatching("tt2")
        assertEquals(listOf("tt1"), library.continueWatching().map { it.metaId })
    }

    @Test fun nextUpComesFromTheLatestCompletedEpisode() {
        val library = store()
        library.recordProgress(show, ep1, 2300.0, 2400.0)
        val seeds = library.nextUpSeeds()
        assertEquals("tt2:1:1", seeds.single().videoId)
        val meta = show.copy(videos = listOf(ep1, ep2))
        assertEquals("tt2:1:2", library.episodeToPlay(meta)?.id)
    }

    @Test fun markWatchedAndUnwatched() {
        val library = store()
        library.markWatched(true, show, listOf(ep1, ep2))
        assertEquals(setOf("tt2:1:1", "tt2:1:2"), library.watchedVideoIds("tt2"))
        library.markWatched(false, show, listOf(ep1))
        assertEquals(setOf("tt2:1:2"), library.watchedVideoIds("tt2"))
    }

    @Test fun privacySwitchStopsRecording() {
        val library = store(policy = LibraryPolicy(recordHistory = false))
        library.recordProgress(movie, null, 500.0, 7200.0)
        assertTrue(library.history().isEmpty())
        library.policy = library.policy.copy(recordHistory = true)
        library.recordProgress(movie, null, 500.0, 7200.0)
        assertEquals(1, library.history().size)
    }

    @Test fun searchHistoryIsUniqueNewestFirstAndCapped() {
        val library = store(policy = LibraryPolicy(maxSearchHistory = 3))
        for (query in listOf("uno", "due", "tre", "Uno", "quattro")) { clock += 1; library.addSearch(query) }
        assertEquals(listOf("quattro", "Uno", "tre"), library.searchHistory().map { it.query })
        library.removeSearch("tre")
        assertEquals(2, library.searchHistory().size)
        library.clearSearchHistory()
        assertTrue(library.searchHistory().isEmpty())
    }

    @Test fun localSearchFindsWhatTheViewerSavedOrWatchedWithoutTheNetwork() {
        val library = store()
        library.setWatchlist(true, movie)
        library.recordProgress(show, ep1, 100.0, 2400.0)
        assertEquals(listOf("tt1"), library.searchLocal("uno").map { it.id })
        assertEquals(listOf("tt2"), library.searchLocal("SERIE").map { it.id })
        assertTrue(library.searchLocal("zzz").isEmpty())
    }

    @Test fun everythingSurvivesARestart() {
        val dir = createTempDirectory("lib").toFile()
        val first = store(dir)
        first.setFavorite(true, movie)
        first.recordProgress(show, ep1, 400.0, 2400.0)
        first.addSearch("trono")
        val second = store(dir)
        assertTrue(second.isFavorite("tt1"))
        assertEquals(400.0, second.resumePosition("tt2", "tt2:1:1"))
        assertEquals("trono", second.searchHistory().single().query)
    }

    @Test fun aDamagedFileIsKeptAsideAndTheLibraryStartsEmpty() {
        val dir = createTempDirectory("lib").toFile()
        File(dir, "library.json").writeText("{ not json")
        val library = store(dir)
        assertTrue(library.watchlist().isEmpty())
        assertTrue(File(dir, "library.json.damaged").exists())
    }

    @Test fun mergeKeepsTheNewestSideAndTheTombstones() {
        val older = store(); val newer = store()
        older.setWatchlist(true, movie)
        clock += 500
        newer.setWatchlist(true, movie)
        newer.setWatchlist(false, movie)
        val merged = LibraryMerge.merge(older.snapshot(), newer.snapshot(), clock)
        assertTrue(merged.entries["tt1"]!!.isRemoved, "the later deletion wins over the older copy")
        val ancient = LibraryMerge.merge(older.snapshot(), LibraryState(), clock + LibraryMerge.TOMBSTONE_RETENTION_MS * 2)
        assertEquals(1, ancient.entries.size, "live entries are never pruned")
    }

    @Test fun backupRoundTripsAndUsesTheSharedFormat() {
        val library = store()
        library.setWatchlist(true, movie)
        library.recordProgress(show, ep1, 400.0, 2400.0)
        library.addSearch("trono")
        val text = BackupCodec.encode(library.snapshot(), listOf("https://a/manifest.json?k=secret"), includeAddonUrls = false, appVersion = "1.0")
        assertTrue(text.contains("\"app.aether.backup\""))
        assertFalse(text.contains("secret"), "addon addresses are left out unless the viewer asks for them")
        val decoded = BackupCodec.decode(text)
        assertEquals(library.snapshot().entries.keys, decoded.library.entries.keys)
        assertEquals(400.0, decoded.library.progress["tt2|tt2:1:1"]!!.position)
        assertEquals("trono", decoded.library.searchHistory.single().query)
        val withUrls = BackupCodec.decode(BackupCodec.encode(library.snapshot(), listOf("https://a/manifest.json"), true, "1.0"))
        assertEquals(listOf("https://a/manifest.json"), withUrls.addonUrls)
    }

    @Test fun readsABackupWrittenByTheIphoneApp() {
        val ios = """{"marker":"app.aether.backup","formatVersion":1,"createdAt":"2026-10-20T10:00:00Z","appVersion":"1.3.0","includesAddonURLs":false,"addons":[],
          "library":{"schemaVersion":1,"entries":{"tt1":{"id":"tt1","type":"movie","name":"Film","inWatchlist":true,"isFavorite":false,"posterShape":"poster",
            "addedAt":"2026-10-01T10:00:00Z","modifiedAt":"2026-10-02T10:00:00Z","isRemoved":false}},
          "progress":{"tt2|tt2:1:1":{"id":"tt2|tt2:1:1","metaID":"tt2","videoID":"tt2:1:1","type":"series","title":"Serie","season":1,"episode":1,"posterShape":"poster",
            "position":300,"duration":2400,"updatedAt":"2026-10-03T10:00:00Z","isCompleted":false,"isDismissed":false}},
          "searchHistory":[{"query":"dune","date":"2026-10-04T10:00:00Z"}]}}"""
        val decoded = BackupCodec.decode(ios)
        assertTrue(decoded.library.entries["tt1"]!!.inWatchlist)
        assertEquals("S01E01", decoded.library.progress.values.single().episodeLabel)
        assertEquals("dune", decoded.library.searchHistory.single().query)
    }

    @Test fun refusesFilesThatAreNotBackups() {
        assertFailsWith<BackupError.NotABackup> { BackupCodec.decode("""{"hello":"world"}""") }
        assertFailsWith<BackupError.Unreadable> { BackupCodec.decode("garbage") }
        assertFailsWith<BackupError.UnsupportedVersion> { BackupCodec.decode("""{"marker":"app.aether.backup","formatVersion":99}""") }
        assertNotNull(BackupCodec.decode("""{"marker":"app.aether.backup","formatVersion":1}"""))
    }
}
