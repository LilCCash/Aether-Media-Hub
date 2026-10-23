package app.aether.core

import app.aether.core.addons.AddonClient
import app.aether.core.addons.AddonRegistryState
import app.aether.core.addons.AddonService
import app.aether.core.addons.RequestPlanner
import app.aether.core.model.AddonStream
import app.aether.core.model.StreamSource
import app.aether.core.net.AddonError
import app.aether.core.support.FakeHttp
import app.aether.core.support.Samples
import app.aether.core.util.InMemorySecretStore
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking

class ServiceTest {
    private fun engine(http: FakeHttp, dir: File = createTempDirectory("aether").toFile()) = AetherEngine(dir, InMemorySecretStore(), http)

    private fun FakeHttp.cinemeta() = on("v3-cinemeta.strem.io/manifest.json", body = Samples.CINEMETA_MANIFEST)
        .on("v3-cinemeta.strem.io/catalog/movie/top", body = Samples.CATALOG)
        .on("v3-cinemeta.strem.io/catalog/series/top/search=", body = """{"metas":[{"id":"tt0944947","type":"series","name":"Il trono di spade"}]}""")
        .on("v3-cinemeta.strem.io/catalog/movie/search-only/search=", body = """{"metas":[{"id":"tt0111161","type":"movie","name":"Le ali della libertà","poster":"https://p"}]}""")
        .on("v3-cinemeta.strem.io/meta/movie/tt0111161", body = Samples.META_MOVIE)
        .on("v3-cinemeta.strem.io/meta/series/tt0944947", body = Samples.META_SERIES)

    private fun FakeHttp.streamAddon() = on("streams.example/manifest.json", body = Samples.STREAM_ADDON_MANIFEST)
        .on("streams.example/stream/movie/tt0111161", body = Samples.STREAMS)
        .on("streams.example/subtitles/movie/tt0111161", body = Samples.SUBTITLES)

    @Test fun installsAnAddonKeepsTheUrlOutOfTheStoredFileAndSurvivesARestart(): Unit = runBlocking {
        val http = FakeHttp().cinemeta()
        val dir = createTempDirectory("aether").toFile()
        val first = engine(http, dir)
        val installed = first.registry.install("https://v3-cinemeta.strem.io/manifest.json")
        assertTrue(installed.isOfficial)
        assertEquals(3, installed.manifest.catalogs.size)
        val stored = File(dir, "addons.json").readText()
        assertFalse(stored.contains("https://v3-cinemeta.strem.io/manifest.json"), "the address (which may hold a key) lives in the secret store only")

        val second = AetherEngine(dir, first.secrets, http)
        assertEquals(1, second.registry.handles().size, "installed addons are still there after a restart")
        assertEquals("https://v3-cinemeta.strem.io/manifest.json", second.registry.transportUrl(installed.id))

        val lost = AetherEngine(dir, InMemorySecretStore(), http)
        assertTrue(lost.registry.all().single().needsReinstall, "without the secret the addon must be added again")
        assertTrue(lost.registry.handles().isEmpty())
    }

    @Test fun installingTheSameAddonTwiceUpdatesIt(): Unit = runBlocking {
        val engine = engine(FakeHttp().cinemeta())
        engine.registry.install("https://v3-cinemeta.strem.io/manifest.json")
        engine.registry.install("v3-cinemeta.strem.io")
        assertEquals(1, engine.registry.all().size)
    }

    @Test fun refusesWhatIsNotAnAddon(): Unit = runBlocking {
        val http = FakeHttp().on("bad.example/manifest.json", body = "<html>hi</html>").on("empty.example/manifest.json", body = """{"id":"a","version":"1","name":"n","resources":[]}""")
        val engine = engine(http)
        assertFailsWith<AddonError.InvalidManifest> { engine.registry.install("https://bad.example/manifest.json") }
        assertFailsWith<AddonError.InvalidManifest> { engine.registry.install("https://empty.example/manifest.json") }
        assertFailsWith<AddonError.Blocked> { engine.registry.install("http://127.0.0.1:7000/manifest.json") }
        assertFailsWith<AddonError.Blocked> { engine.registry.install("http://192.168.1.4:7000/manifest.json") }
        assertTrue(engine.registry.all().isEmpty())
    }

    @Test fun enableDisableReorderRenameHideCatalogAndRemove(): Unit = runBlocking {
        val http = FakeHttp().cinemeta().streamAddon()
        val engine = engine(http)
        val a = engine.registry.install("https://v3-cinemeta.strem.io/manifest.json")
        val b = engine.registry.install("https://streams.example/manifest.json")
        engine.registry.move(b.id, -1)
        assertEquals(listOf(b.id, a.id), engine.registry.all().map { it.id })
        engine.registry.setEnabled(false, a.id)
        assertEquals(listOf(b.id), engine.registry.handles().map { it.id })
        engine.registry.setNameOverride("Il mio catalogo", a.id)
        assertEquals("Il mio catalogo", engine.registry.addon(a.id)?.displayName)
        engine.registry.setEnabled(true, a.id)
        engine.registry.setCatalogVisible(false, "movie/top", a.id)
        val feeds = RequestPlanner.feedCatalogs(engine.registry.handles())
        assertEquals(listOf("series/top"), feeds.map { it.catalog.key }, "hidden catalogs and search-only catalogs are not feeds")
        engine.registry.uninstall(b.id)
        assertNull(engine.registry.transportUrl(b.id))
        assertEquals(1, engine.registry.all().size)
    }

    @Test fun catalogsAreFetchedWithTheRightUrlAndCached(): Unit = runBlocking {
        val http = FakeHttp().cinemeta()
        val engine = engine(http)
        engine.registry.install("https://v3-cinemeta.strem.io/manifest.json")
        val ref = RequestPlanner.feedCatalogs(engine.registry.handles(), "movie").single()
        val first = engine.addons.catalog(ref)
        assertEquals(2, first.items.size)
        engine.addons.catalog(ref)
        assertEquals(1, http.count("catalog/movie/top.json"), "the second read is served from the cache")
        engine.addons.catalog(ref, mode = AddonClient.LoadMode.RELOAD)
        assertEquals(2, http.count("catalog/movie/top.json"))
    }

    @Test fun staleCacheIsUsedWhenTheAddonIsDown(): Unit = runBlocking {
        val http = FakeHttp().cinemeta()
        val engine = engine(http)
        engine.registry.install("https://v3-cinemeta.strem.io/manifest.json")
        val ref = RequestPlanner.feedCatalogs(engine.registry.handles(), "movie").single()
        engine.addons.catalog(ref)
        http.routes.add(0, FakeHttp.Route("catalog/movie/top") { throw AddonError.Offline })
        val reloaded = engine.addons.catalog(ref, mode = AddonClient.LoadMode.RELOAD)
        assertTrue(reloaded.isStale)
        assertEquals(2, reloaded.items.size)
    }

    @Test fun searchAsksEverySearchableCatalogAndReportsFailures(): Unit = runBlocking {
        val http = FakeHttp().cinemeta()
        val engine = engine(http)
        engine.registry.install("https://v3-cinemeta.strem.io/manifest.json")
        val updates = engine.search.search("  il   padrino ").toList()
        assertEquals(2, updates.size, "the series catalog and the search-only movie catalog both answer")
        assertEquals(2, updates.last().total)
        assertTrue(updates.all { it.row.error == null })
        assertTrue(http.requests.any { it.url.contains("search=il%20padrino") })
        assertTrue(engine.search.search("   ").toList().isEmpty())
    }

    @Test fun metaTakesTheFirstAddonInUserOrderThatAnswersAndFillsTheGaps(): Unit = runBlocking {
        val http = FakeHttp()
            .on("first.example/manifest.json", body = """{"id":"f","version":"1","name":"F","types":["movie"],"resources":["meta"],"idPrefixes":["tt"]}""")
            .on("first.example/meta/movie/tt1.json", status = 500, body = "{}")
            .on("second.example/manifest.json", body = """{"id":"s","version":"1","name":"S","types":["movie"],"resources":["meta"],"idPrefixes":["tt"]}""")
            .on("second.example/meta/movie/tt1.json", body = """{"meta":{"id":"tt1","type":"movie","name":"Titolo","description":"dal secondo"}}""")
        val engine = engine(http)
        engine.registry.install("https://first.example/manifest.json")
        engine.registry.install("https://second.example/manifest.json")
        val preview = app.aether.core.model.MetaItem("tt1", "movie", "Anteprima", poster = "https://p")
        val resolution = engine.addons.meta("movie", "tt1", preview)
        assertEquals("S", resolution.providerName)
        assertEquals("dal secondo", resolution.meta.description)
        assertEquals("https://p", resolution.meta.poster, "the catalog preview fills what the addon left empty")
        assertEquals(1, resolution.failures.size)
        assertTrue(resolution.hadDetailProvider)
        val none = engine.addons.meta("series", "tt9", null)
        assertFalse(none.hadDetailProvider)
    }

    @Test fun streamsArriveFromEveryAddonAndAreTagged(): Unit = runBlocking {
        val http = FakeHttp().cinemeta().streamAddon()
        val engine = engine(http)
        engine.registry.install("https://v3-cinemeta.strem.io/manifest.json")
        engine.registry.install("https://streams.example/manifest.json")
        val batches = engine.addons.streams("movie", "tt0111161").toList()
        val batch = batches.single { it.addonName == "Sorgenti" }
        assertEquals(5, batch.streams.size)
        assertTrue(batch.streams.all { it.addonName == "Sorgenti" && it.addonId != null })
        assertTrue(batches.any { it.addonName == "Cinemeta" && it.error == null }, "a 404 means no streams, not an error")
    }

    @Test fun subtitlesOnlyFromAddonsThatDeclareTheIdPrefixAndDeduplicatedByUrl(): Unit = runBlocking {
        val http = FakeHttp().cinemeta().streamAddon()
        val engine = engine(http)
        engine.registry.install("https://streams.example/manifest.json")
        val subs = engine.addons.subtitles("movie", "tt0111161", AddonStream(StreamSource.Url("https://x/a.mp4"), behaviorHints = app.aether.core.model.StreamBehaviorHints(videoHash = "abc", videoSize = 10, filename = "a b.mp4")))
        assertEquals(2, subs.size)
        assertEquals("Sorgenti", subs[0].addonName)
        assertTrue(http.requests.any { it.url.contains("videoHash=abc") && it.url.contains("filename=a%20b.mp4") })
        assertTrue(engine.addons.subtitles("movie", "kitsu:1", null).isEmpty())
    }

    @Test fun anAddonThatTimesOutDoesNotBlockTheOthers(): Unit = runBlocking {
        val http = FakeHttp().cinemeta()
            .on("slow.example/manifest.json", body = """{"id":"slow","version":"1","name":"Slow","types":["movie"],"resources":["stream"],"idPrefixes":["tt"]}""")
            .fail("slow.example/stream", AddonError.Timeout)
        val engine = engine(http)
        engine.registry.install("https://v3-cinemeta.strem.io/manifest.json")
        engine.registry.install("https://slow.example/manifest.json")
        val batches = engine.addons.streams("movie", "tt0111161").toList()
        assertEquals(AddonError.Timeout, batches.single { it.addonName == "Slow" }.error)
        assertNotNull(engine.registry.addon(engine.registry.all().last().id)?.lastError, "the addon's health is remembered")
    }
}
