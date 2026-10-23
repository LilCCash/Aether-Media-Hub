package app.aether.core

import app.aether.core.addons.AddonUrl
import app.aether.core.addons.ResourceUrlBuilder
import app.aether.core.model.ExtraValue
import app.aether.core.model.ResourcePath
import app.aether.core.net.AddonError
import app.aether.core.net.NetworkPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AddonUrlTest {
    @Test fun acceptsTheUsualSpellings() {
        assertEquals("https://v3-cinemeta.strem.io/manifest.json", AddonUrl.parseInstallInput("https://v3-cinemeta.strem.io/manifest.json"))
        assertEquals("https://host.tld/a/b/manifest.json", AddonUrl.parseInstallInput("stremio://host.tld/a/b/manifest.json"))
        assertEquals("https://host.tld/x/manifest.json", AddonUrl.parseInstallInput("https://host.tld/x/configure"))
        assertEquals("https://host.tld/manifest.json", AddonUrl.parseInstallInput("  host.tld  "))
        assertEquals("https://192.168.1.5:7000/manifest.json", AddonUrl.parseInstallInput("192.168.1.5:7000"))
        assertEquals("http://192.168.1.5:7000/manifest.json", AddonUrl.parseInstallInput("http://192.168.1.5:7000"))
        assertEquals("https://host.tld/m/manifest.json?key=abc", AddonUrl.parseInstallInput("<https://HOST.tld/m?key=abc#frag>"))
    }

    @Test fun refusesWhatIsNotAnAddonAddress() {
        for (bad in listOf("", "javascript:alert(1)", "file:///etc/passwd", "ftp://host/manifest.json", "https://user:pw@host/manifest.json", "stremio:///detail/movie/tt1", "https://host/x.json")) {
            assertFailsWith<AddonError>("should refuse «$bad»") { AddonUrl.parseInstallInput(bad) }
        }
    }

    @Test fun canonicalKeyIgnoresCaseDefaultPortAndFragment() {
        assertEquals(AddonUrl.canonicalKey("https://Host.tld:443/a/manifest.json#x"), AddonUrl.canonicalKey("https://host.tld/a/manifest.json"))
    }

    @Test fun displayHostHidesPathAndQuery() {
        assertEquals("host.tld:7000", AddonUrl.displayHost("https://host.tld:7000/SECRETKEY/manifest.json?token=1"))
    }

    @Test fun deepLinks() {
        assertEquals("https://h.tld/manifest.json", AddonUrl.installUrlFromDeepLink("stremio://h.tld/manifest.json"))
        assertEquals("https://h.tld/manifest.json", AddonUrl.installUrlFromDeepLink("aether://addon?url=https%3A%2F%2Fh.tld%2Fmanifest.json"))
        assertNull(AddonUrl.installUrlFromDeepLink("https://example.org"))
    }

    @Test fun buildsResourceUrlsLikeStremioCore() {
        val transport = "https://h.tld/cfg/manifest.json?k=v"
        val url = ResourceUrlBuilder.url(transport, ResourcePath("catalog", "movie", "top", listOf(ExtraValue("search", "il padrino"), ExtraValue("skip", "20"))))
        assertEquals("https://h.tld/cfg/catalog/movie/top/search=il%20padrino&skip=20.json?k=v", url)
        assertEquals("https://h.tld/cfg/stream/series/tt0944947%3A1%3A2.json?k=v", ResourceUrlBuilder.url(transport, ResourcePath("stream", "series", "tt0944947:1:2")))
        assertNull(ResourceUrlBuilder.url("https://h.tld/other.json", ResourcePath("meta", "movie", "tt1")))
    }

    @Test fun networkPolicyRefusesLoopbackAndGuardsPrivateAddresses() {
        val strict = NetworkPolicy(allowLocalNetwork = false)
        val open = NetworkPolicy(allowLocalNetwork = true)
        assertNotNull(strict.check("http://127.0.0.1:11470/x"))
        assertNotNull(open.check("http://127.0.0.1:11470/x"))
        assertNotNull(open.check("http://localhost/x"))
        assertNotNull(strict.check("http://192.168.1.10/manifest.json"))
        assertNull(open.check("http://192.168.1.10/manifest.json"))
        assertNotNull(strict.check("http://nas.local/manifest.json"))
        assertNull(strict.check("https://v3-cinemeta.strem.io/manifest.json"))
        assertTrue(strict.check("ftp://x/y") is AddonError.BlockReason)
        assertNotNull(strict.check("https://user:pw@host.tld/x"))
    }
}
