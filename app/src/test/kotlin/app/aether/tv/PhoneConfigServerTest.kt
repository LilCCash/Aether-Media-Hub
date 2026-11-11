package app.aether.tv

import app.aether.core.AetherEngine
import app.aether.core.debrid.TorBoxClient
import app.aether.core.util.InMemorySecretStore
import app.aether.tv.remote.PhoneConfigServer
import fi.iki.elonen.NanoHTTPD
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PhoneConfigServerTest {
    private lateinit var server: PhoneConfigServer
    private lateinit var secrets: InMemorySecretStore
    private val base get() = "http://127.0.0.1:${server.listeningPort}"

    @Before fun start() {
        secrets = InMemorySecretStore()
        val engine = AetherEngine(Files.createTempDirectory("aether").toFile(), secrets)
        server = PhoneConfigServer(engine)
        server.start(NanoHTTPD.SOCKET_READ_TIMEOUT, true)
    }

    @After fun stop() = server.stop()

    private fun request(path: String, body: String? = null): Pair<Int, String> {
        val connection = URL(base + path).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = false
        if (body != null) {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            connection.outputStream.use { it.write(body.toByteArray()) }
        }
        val code = connection.responseCode
        val text = (if (code < 400) connection.inputStream else connection.errorStream)?.bufferedReader()?.readText().orEmpty()
        return code to text
    }

    @Test fun thePhoneWaitsForTheTvThenSavesKeysWithoutEverShowingThem() {
        val token = server.session.token
        val (code, waiting) = request("/s/$token/")
        assertEquals(200, code)
        assertTrue(waiting.contains("Conferma sulla TV"))
        assertEquals("127.0.0.1", server.pending.value)
        server.answer(true)
        val (_, home) = request("/s/$token/")
        assertTrue(home.contains("Configura la TV"))
        val key = "TBKEY-123456"
        val (saved, _) = request("/s/$token/keys", "torbox=$key")
        assertEquals(303, saved)
        assertEquals(key, secrets.get(TorBoxClient.KEY_SECRET))
        val (_, after) = request("/s/$token/")
        assertFalse(after.contains(key))
        assertTrue(after.contains("impostata"))
    }

    @Test fun aWrongTokenOrAForeignSiteIsRefused() {
        assertEquals(403, request("/s/wrong/").first)
        val token = server.session.token
        request("/s/$token/"); server.answer(true)
        // HttpURLConnection does not let a caller set Origin: the request is written by hand, as a browser on another site would.
        java.net.Socket("127.0.0.1", server.listeningPort).use { socket ->
            val body = "torbox=x"
            socket.getOutputStream().write(("POST /s/$token/keys HTTP/1.1\r\nHost: 127.0.0.1:${server.listeningPort}\r\nOrigin: http://evil.example\r\n" +
                "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body").toByteArray())
            val status = socket.getInputStream().bufferedReader().readLine()
            assertTrue(status, status.contains(" 403 "))
        }
        assertEquals(null, secrets.get(TorBoxClient.KEY_SECRET))
        assertEquals(404, request("/").first)
    }
}
