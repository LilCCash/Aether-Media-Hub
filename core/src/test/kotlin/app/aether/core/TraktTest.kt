package app.aether.core

import app.aether.core.support.FakeHttp
import app.aether.core.trakt.TraktCatalogKind
import app.aether.core.trakt.TraktClient
import app.aether.core.trakt.TraktDeviceCode
import app.aether.core.trakt.TraktError
import app.aether.core.util.InMemorySecretStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class TraktTest {
    @Test fun deviceLoginStoresTheSessionAndAuthorizedCallsCarryIt() = runBlocking<Unit> {
        val secrets = InMemorySecretStore()
        val http = FakeHttp()
            .on("/oauth/device/code", body = """{"device_code":"D","user_code":"ABCD","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}""")
            .on("/oauth/device/token", body = """{"access_token":"AT","refresh_token":"RT","created_at":${System.currentTimeMillis() / 1000},"expires_in":7776000}""")
            .on("/sync/playback", body = """[{"progress":42.5,"movie":{"title":"Film","year":2020,"ids":{"imdb":"tt1","tmdb":5}}},{"progress":10,"show":{"title":"Serie","ids":{"imdb":"tt2"}},"episode":{"season":1,"number":3,"title":"Ep"}}]""")
        val client = TraktClient(http, secrets, "CID")
        val code = client.startDeviceLogin()
        assertEquals("ABCD", code.userCode)
        client.pollDeviceLogin(code)
        assertTrue(client.isConnected)
        assertTrue(TraktClient(http, secrets, "CID").isConnected)
        val items = client.titles(TraktCatalogKind.CONTINUE_WATCHING, 10)
        assertEquals(listOf("visto al 42%", "S1E3 · 10%"), items.map { it.note })
        val playback = http.requests.last()
        assertEquals("Bearer AT", playback.headers["Authorization"])
        assertEquals("CID", playback.headers["trakt-api-key"])
        assertFalse("AT" in playback.url)
    }

    @Test fun pendingAndExpiredCodesAreReported() = runBlocking<Unit> {
        val code = TraktDeviceCode("D", "U", "https://trakt.tv/activate", 600, 5)
        for ((status, expected) in listOf(400 to TraktError.Pending, 410 to TraktError.Expired, 418 to TraktError.Denied)) {
            val client = TraktClient(FakeHttp().on("/oauth/device/token", status = status, body = ""), InMemorySecretStore(), "CID")
            try { client.pollDeviceLogin(code); fail() } catch (e: TraktError) { assertEquals(expected, e) }
        }
    }

    @Test fun withoutAClientIdNothingIsSent() = runBlocking<Unit> {
        val http = FakeHttp()
        try { TraktClient(http, InMemorySecretStore(), "").startDeviceLogin(); fail() } catch (e: TraktError) { assertEquals(TraktError.NoClientId, e) }
        assertEquals(0, http.requests.size)
    }

    @Test fun historyGroupsEpisodesBySeriesAndSeason() = runBlocking<Unit> {
        val secrets = InMemorySecretStore()
        secrets.put(TraktClient.SESSION_SECRET, """{"accessToken":"AT","refreshToken":"RT","createdAt":${System.currentTimeMillis()},"expiresInSeconds":7776000}""")
        val http = FakeHttp().on("/sync/history", body = "{}")
        TraktClient(http, secrets, "CID").addToHistory(listOf("tt9"), listOf(Triple("tt2", 1, 1), Triple("tt2", 1, 2)))
        val body = http.requests.last().body!!
        assertTrue(body.contains("\"movies\":[{\"ids\":{\"imdb\":\"tt9\"}"))
        assertTrue(body.contains("\"seasons\":[{\"number\":1,\"episodes\":[{\"number\":1"))
    }
}
