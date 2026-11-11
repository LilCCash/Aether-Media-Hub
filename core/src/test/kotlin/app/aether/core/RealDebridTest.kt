package app.aether.core

import app.aether.core.addons.AddonDebridRouting
import app.aether.core.addons.AddonDebridScope
import app.aether.core.addons.AddonHandle
import app.aether.core.addons.InstalledAddon
import app.aether.core.debrid.DebridError
import app.aether.core.debrid.DebridRequest
import app.aether.core.debrid.DebridResolver
import app.aether.core.debrid.DebridService
import app.aether.core.debrid.RealDebridClient
import app.aether.core.debrid.StreamDebridContext
import app.aether.core.metadata.MdbListClient
import app.aether.core.model.AddonManifest
import app.aether.core.model.AddonStream
import app.aether.core.model.StreamSource
import app.aether.core.support.FakeHttp
import app.aether.core.util.InMemorySecretStore
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class RealDebridTest {
    private val hash = "a".repeat(40)
    private val token = "RDTOKEN123"

    private fun client(http: FakeHttp) = RealDebridClient(http, InMemorySecretStore().also { it.put(RealDebridClient.KEY_SECRET, token) }, pollMillis = 1)

    @Test fun aTorrentAlreadyInTheAccountIsUnrestrictedAndTheTokenStaysInTheHeader() = runBlocking<Unit> {
        val http = FakeHttp()
            .on("/torrents/info/T1", body = """{"status":"downloaded","files":[{"id":1,"path":"/Film.2024.1080p.mkv","bytes":900,"selected":1},{"id":2,"path":"/sample.txt","bytes":1,"selected":0}],"links":["https://real-debrid.com/d/ABC"]}""")
            .on("/torrents?", body = """[{"id":"T1","hash":"$hash"}]""")
            .on("/unrestrict/link", body = """{"download":"https://cdn.example/Film.mkv"}""")
        val link = client(http).resolve(DebridRequest(hash, emptyList(), null, null, "tt1"), DebridResolver.Mode.CachedOnly)
        assertEquals("https://cdn.example/Film.mkv", link)
        assertTrue(http.requests.all { it.headers["Authorization"] == "Bearer $token" && token !in it.url })
        assertEquals("link=https%3A%2F%2Freal-debrid.com%2Fd%2FABC", http.requests.last().body)
    }

    @Test fun inCachedOnlyModeNothingIsAddedToTheAccount() = runBlocking<Unit> {
        val http = FakeHttp().on("/torrents?", body = "[]")
        try {
            client(http).resolve(DebridRequest(hash, emptyList(), null, null, "tt1"), DebridResolver.Mode.CachedOnly)
            fail()
        } catch (error: DebridError) {
            assertTrue(error is DebridError.RealDebridNotInAccount)
        }
        assertEquals(0, http.count("addMagnet"))
    }

    @Test fun aRejectedTokenIsReportedWithoutEchoingIt() = runBlocking<Unit> {
        val http = FakeHttp().on("/user", status = 401, body = """{"error":"bad_token"}""")
        try { client(http).fetchUser(); fail() } catch (error: DebridError) {
            assertTrue(error is DebridError.RealDebridInvalidKey)
            assertFalse(token in error.message)
        }
    }

    private fun handle(url: String, scope: AddonDebridScope = AddonDebridScope.BOTH) =
        AddonHandle(InstalledAddon("id", AddonManifest(id = "x", version = "1", name = "X"), "h", "f", debridScope = scope), url)

    @Test fun torrentioIsSwitchedToRealDebridAndOtherDebridsAreTakenOut() {
        val url = "https://torrentio.strem.fun/providers=yts|torbox=TBKEY|debridoptions=nocatalog/manifest.json"
        val decision = AddonDebridRouting.decide(handle(url), StreamDebridContext(DebridService.REAL_DEBRID, "RD"))
        val use = decision as AddonDebridRouting.Decision.Use
        assertEquals(AddonDebridRouting.Kind.TORRENTIO, use.switched)
        assertEquals("https://torrentio.strem.fun/providers=yts%7Cdebridoptions=nocatalog,nodownloadlinks%7Crealdebrid=RD/manifest.json", use.url)
        val bare = AddonDebridRouting.rewriteTorrentio("https://torrentio.strem.fun/manifest.json", "RD")
        assertEquals("https://torrentio.strem.fun/debridoptions=nodownloadlinks%7Crealdebrid=RD/manifest.json", bare)
    }

    @Test fun cometConfigCarriesTheRealDebridKeyAndCachedOnly() {
        val config = java.util.Base64.getEncoder().encodeToString("""{"debridService":"torbox","debridApiKey":"TB","maxResults":5}""".toByteArray())
        val rewritten = AddonDebridRouting.rewriteComet("https://comet.elfhosted.com/$config/manifest.json", "RD")!!
        val segment = rewritten.removePrefix("https://comet.elfhosted.com/").removeSuffix("/manifest.json")
        val decoded = AddonDebridRouting.decodeCometConfig(segment)!!
        assertEquals("realdebrid", decoded["debridService"]!!.jsonPrimitive.content)
        assertEquals("RD", decoded["debridApiKey"]!!.jsonPrimitive.content)
        assertEquals("true", decoded["cachedOnly"]!!.jsonPrimitive.content)
        assertEquals("5", decoded["maxResults"]!!.jsonPrimitive.content)
        assertFalse('/' in segment || '+' in segment)
    }

    @Test fun scopesDecideWhichAddonsAreAsked() {
        val tb = StreamDebridContext(DebridService.TORBOX, null)
        val rd = StreamDebridContext(DebridService.REAL_DEBRID, "RD")
        assertEquals(AddonDebridRouting.Decision.Skip, AddonDebridRouting.decide(handle("https://a.example/manifest.json", AddonDebridScope.REAL_DEBRID), tb))
        assertEquals(AddonDebridRouting.Decision.Skip, AddonDebridRouting.decide(handle("https://a.example/manifest.json", AddonDebridScope.TORBOX), rd))
        val other = AddonDebridRouting.decide(handle("https://a.example/manifest.json"), rd) as AddonDebridRouting.Decision.Use
        assertNull(other.switched)
        assertTrue(AddonDebridRouting.decide(handle("https://comet.example/notbase64!/manifest.json"), rd) is AddonDebridRouting.Decision.Unreadable)
    }

    @Test fun sourcesNotReadyOnRealDebridAreLeftOut() {
        assertFalse(AddonDebridRouting.isReadyOnRealDebrid(AddonStream(StreamSource.Url("https://x.example/v.mp4"), name = "[RD download] Torrentio"), AddonDebridRouting.Kind.TORRENTIO))
        assertTrue(AddonDebridRouting.isReadyOnRealDebrid(AddonStream(StreamSource.Url("https://x.example/v.mp4"), name = "[RD+] Torrentio"), AddonDebridRouting.Kind.TORRENTIO))
        assertFalse(AddonDebridRouting.isReadyOnRealDebrid(AddonStream(StreamSource.Url("https://x.example/v.mp4"), name = "[RD⬇️] Comet"), AddonDebridRouting.Kind.COMET))
    }

    @Test fun mdbListRatingsAreReadInEachServiceScale() {
        val ratings = MdbListClient.parse("""{"ratings":[{"source":"imdb","value":7.7,"score":77,"votes":1000},{"source":"tomatoes","value":92,"score":92},{"source":"metacritic","value":81},{"source":"letterboxd","value":null,"score":null}]}""")
        assertEquals(listOf("7.7", "92%", "81"), ratings.map { it.display })
        assertEquals("Rotten Tomatoes", ratings[1].title)
    }
}
