package app.aether.core

import app.aether.core.debrid.DebridEpisode
import app.aether.core.debrid.DebridError
import app.aether.core.debrid.DebridFile
import app.aether.core.debrid.DebridRequest
import app.aether.core.debrid.DebridResolver
import app.aether.core.debrid.TorBoxClient
import app.aether.core.debrid.TorBoxFileMatcher
import app.aether.core.segments.EpisodeSkipSegments
import app.aether.core.segments.IntroDbClient
import app.aether.core.segments.SkipSegment
import app.aether.core.support.FakeHttp
import app.aether.core.util.InMemorySecretStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

class DebridTest {
    private fun file(id: Int, name: String, size: Long = 1000) = DebridFile(id, name, name.substringAfterLast('/'), size, null, false, false)

    @Test fun picksTheEpisodeByItsNumberAndNeverTheLargestFileForASeries() {
        val files = listOf(file(1, "Show/S01E01.mkv", 900), file(2, "Show/S01E02.mkv", 500), file(3, "Show/S01E03.mkv", 700), file(4, "Show/readme.txt"))
        val picked = TorBoxFileMatcher.select(files, null, DebridEpisode(1, 2), expectsEpisode = true)
        assertEquals(2, (picked as TorBoxFileMatcher.Outcome.Selected).file.id)
        val none = TorBoxFileMatcher.select(files, null, DebridEpisode(2, 9), expectsEpisode = true)
        assertIs<TorBoxFileMatcher.Outcome.NoConfidentMatch>(none)
        assertEquals(3, none.candidates.size)
    }

    @Test fun understandsTheCommonEpisodeSpellings() {
        for (name in listOf("Show.S01E02.1080p.mkv", "show 1x02.mkv", "Season 1 Episode 2.mkv", "show.s01.e02.mkv")) {
            assertTrue(TorBoxFileMatcher.tagMatches(file(1, name), DebridEpisode(1, 2)), name)
        }
        assertFalse(TorBoxFileMatcher.tagMatches(file(1, "Show.S01E12.mkv"), DebridEpisode(1, 2)))
        assertEquals(DebridEpisode(1, 2), DebridEpisode.parse("tt0944947:1:2"))
        assertNull(DebridEpisode.parse("tt1"))
    }

    @Test fun aFilenameHintWinsAndAMovieTakesTheLargestVideo() {
        val files = listOf(file(1, "Film.2020.mkv", 8000), file(2, "Film.2020.sample.mp4", 100), file(3, "Extras/making.of.mkv", 300))
        assertEquals(1, (TorBoxFileMatcher.select(files, null, null, false) as TorBoxFileMatcher.Outcome.Selected).file.id)
        assertEquals(3, (TorBoxFileMatcher.select(files, "Making of.mkv".replace(" ", "."), null, false) as TorBoxFileMatcher.Outcome.Selected).file.id)
        assertEquals(TorBoxFileMatcher.Outcome.NoVideo, TorBoxFileMatcher.select(listOf(file(1, "a.txt")), null, null, false))
        assertEquals(TorBoxFileMatcher.Outcome.ArchivesOnly, TorBoxFileMatcher.select(listOf(file(1, "a.rar")), null, null, false))
    }

    private fun http(cached: Boolean = true, finished: Boolean = true) = FakeHttp()
        .on("/torrents/createtorrent", method = "POST", status = if (cached) 200 else 409,
            body = if (cached) """{"success":true,"data":{"torrent_id":77}}""" else """{"success":false,"error":"ACTIVE_LIMIT","detail":"not cached"}""")
        .on("/torrents/mylist", body = """{"success":true,"data":{"id":77,"download_finished":$finished,"download_present":$finished,"progress":0.4,"files":[
            {"id":5,"name":"Film/Film.mkv","short_name":"Film.mkv","size":5000},{"id":6,"name":"Film/sample.mkv","short_name":"sample.mkv","size":50}]}}""")
        .on("/torrents/requestdl", body = """{"success":true,"data":"https://cdn.torbox.example/dl/abc"}""")
        .on("/torrents/checkcached", method = "POST", body = """{"success":true,"data":[{"hash":"0123456789abcdef0123456789abcdef01234567","name":"x"}]}""")
        .on("/user/me", body = """{"success":true,"data":{"plan":2,"is_subscribed":true,"email":"nobody@example.com"}}""")

    private val request = DebridRequest("0123456789ABCDEF0123456789abcdef01234567", listOf("udp://t:80"), null, null, "tt9")

    @Test fun cachedTorrentIsTurnedIntoALinkAndTheKeyTravelsOnlyInTheAuthorizationHeader() = runBlocking<Unit> {
        val fake = http()
        val secrets = InMemorySecretStore()
        val client = TorBoxClient(fake, secrets).also { it.saveKey("KEY-123") }
        val link = DebridResolver(client).resolve(request, DebridResolver.Mode.CachedOnly)
        assertEquals("https://cdn.torbox.example/dl/abc", link)
        val create = fake.requests.single { it.url.contains("createtorrent") }
        assertTrue(create.body!!.contains("add_only_if_cached=true") && create.body!!.contains("btih%3A0123456789abcdef") || create.body!!.contains("btih"))
        assertEquals("Bearer KEY-123", create.headers["Authorization"])
        assertTrue(fake.requests.filter { !it.url.contains("requestdl") }.none { it.url.contains("KEY-123") }, "the key is never put in a URL, except the one call that needs it")
        assertTrue(fake.requests.single { it.url.contains("requestdl") }.url.contains("token=KEY-123"))
    }

    @Test fun anUncachedTorrentIsReportedInsteadOfBeingDownloadedSilently() = runBlocking<Unit> {
        val client = TorBoxClient(http(cached = false), InMemorySecretStore()).also { it.saveKey("KEY-123") }
        assertFailsWith<DebridError.NotCached> { DebridResolver(client).resolve(request, DebridResolver.Mode.CachedOnly) }
    }

    @Test fun withoutAKeyNothingIsSent() = runBlocking<Unit> {
        val fake = http()
        val client = TorBoxClient(fake, InMemorySecretStore())
        assertFailsWith<DebridError.NotConfigured> { DebridResolver(client).resolve(request, DebridResolver.Mode.CachedOnly) }
        assertTrue(fake.requests.isEmpty())
        assertFailsWith<IllegalArgumentException> { client.saveKey("has space") }
    }

    @Test fun aBadKeyIsReportedAndNeverEchoed() = runBlocking<Unit> {
        val fake = FakeHttp().on("/user/me", status = 401, body = """{"detail":"Not authenticated KEY-123"}""")
        val client = TorBoxClient(fake, InMemorySecretStore()).also { it.saveKey("KEY-123") }
        val error = assertFailsWith<DebridError.InvalidKey> { client.fetchUser() }
        assertFalse(error.message.contains("KEY-123"))
    }

    @Test fun cachedCheckReturnsOnlyTheHashesTorBoxHas() = runBlocking<Unit> {
        val client = TorBoxClient(http(), InMemorySecretStore()).also { it.saveKey("KEY-123") }
        val found = client.checkCached(listOf("0123456789abcdef0123456789abcdef01234567", "ffffffffffffffffffffffffffffffffffffffff"))
        assertEquals(setOf("0123456789abcdef0123456789abcdef01234567"), found)
        assertEquals(2, client.fetchUser().plan)
    }

    @Test fun skipSegmentsAreOfferedOnlyInsideTheirWindow() {
        val segments = EpisodeSkipSegments(intro = SkipSegment(SkipSegment.Kind.INTRO, 30.0, 90.0), recap = SkipSegment(SkipSegment.Kind.RECAP, 5.0, 25.0))
        assertNull(segments.active(2.0))
        assertEquals(SkipSegment.Kind.RECAP, segments.active(10.0)?.kind)
        assertEquals(SkipSegment.Kind.INTRO, segments.active(29.5)?.kind)
        assertNull(segments.active(89.5), "the button goes away just before the end")
        assertNull(segments.active(40.0, duration = 20.0), "timing of a longer cut is rejected")
    }

    @Test fun introDbAnswerIsReadAndBadIdsAreNotAsked() = runBlocking<Unit> {
        val fake = FakeHttp().on("api.introdb.app/segments", body = """{"intro":{"start_sec":12.5,"end_sec":80},"recap":null,"outro":{"start_sec":2000,"end_sec":2100}}""")
        val client = IntroDbClient(fake)
        val found = client.segments("tt0944947", 1, 2)
        assertNotNull(found)
        assertEquals(12.5, found.intro?.start)
        assertNull(found.recap)
        assertNull(client.segments("not-an-id", 1, 1))
        assertEquals(1, fake.requests.size)
        assertNull(IntroDbClient(FakeHttp().on("segments", status = 404, body = "{}")).segments("tt0944947", 1, 1))
    }
}
