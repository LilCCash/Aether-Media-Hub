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
        server.start(PhoneConfigServer.SOCKET_TIMEOUT_MS, true)
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

    /** A file sent by the phone page, as Safari sends it (multipart), on a raw socket; returns the status line. */
    private fun upload(token: String, fileBody: ByteArray, origin: String? = null): String {
        val boundary = "----AetherTest"
        val head = "--$boundary\r\nContent-Disposition: form-data; name=\"backup\"; filename=\"Aether-Backup.json\"\r\nContent-Type: application/json\r\n\r\n"
        val tail = "\r\n--$boundary\r\nContent-Disposition: form-data; name=\"mode\"\r\n\r\nmerge\r\n--$boundary--\r\n"
        val body = head.toByteArray() + fileBody + tail.toByteArray()
        java.net.Socket("127.0.0.1", server.listeningPort).use { socket ->
            socket.soTimeout = 60_000
            val out = socket.getOutputStream()
            out.write(("POST /s/$token/restore HTTP/1.1\r\nHost: 127.0.0.1:${server.listeningPort}\r\nOrigin: ${origin ?: "http://127.0.0.1:${server.listeningPort}"}\r\n" +
                "Content-Type: multipart/form-data; boundary=$boundary\r\nContent-Length: ${body.size}\r\nConnection: keep-alive\r\n\r\n").toByteArray())
            out.write(body)
            out.flush()
            return socket.getInputStream().bufferedReader().readLine() ?: "connection closed"
        }
    }

    @Test fun aBackupFromThePhoneIsRestoredEvenWhenItIsLarge() {
        val token = server.session.token
        request("/s/$token/"); server.answer(true)
        val history = (0 until 40_000).associate { i ->
            "tt$i|tt$i" to app.aether.core.library.PlaybackProgress("tt$i", "tt$i", "movie", "Titolo di prova numero $i con un nome lungo", position = 100.0, duration = 6000.0)
        }
        val text = app.aether.core.library.BackupCodec.encode(app.aether.core.library.LibraryState(progress = history), emptyList(), false, "test")
        assertTrue("backup of ${text.length} bytes", text.length > 6_000_000)
        val status = upload(token, text.toByteArray())
        assertTrue(status, status.contains(" 303 "))
    }

    @Test fun everyAnswerClosesItsConnectionSoSafariNeverReusesAStaleOne() {
        val token = server.session.token
        request("/s/$token/"); server.answer(true)
        java.net.Socket("127.0.0.1", server.listeningPort).use { socket ->
            socket.getOutputStream().write("GET /s/$token/ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n".toByteArray())
            val head = socket.getInputStream().bufferedReader().lineSequence().takeWhile { it.isNotEmpty() }.toList()
            assertTrue(head.toString(), head.any { it.equals("connection: close", ignoreCase = true) })
        }
    }

    @Test fun aSmallBackupChosenSlowlyIsRestored() {
        val token = server.session.token
        request("/s/$token/"); server.answer(true)
        val text = app.aether.core.library.BackupCodec.encode(app.aether.core.library.LibraryState(), emptyList(), false, "test")
        Thread.sleep(1500)
        assertTrue(upload(token, text.toByteArray()).contains(" 303 "))
    }

    /** Safari sends «Origin: null» for a form when the page asks for no referrer: it was refused and the upload cut («connessione persa»). */
    @Test fun safarisNullOriginIsAcceptedForTheBackupForm() {
        val token = server.session.token
        request("/s/$token/"); server.answer(true)
        val text = app.aether.core.library.BackupCodec.encode(app.aether.core.library.LibraryState(), emptyList(), false, "test")
        val status = upload(token, text.toByteArray() + ByteArray(200_000) { ' '.code.toByte() }, origin = "null")
        assertTrue(status, status.contains(" 303 "))
    }

    @Test fun aRefusedUploadIsStillReadSoTheBrowserGetsThePage() {
        val token = server.session.token
        request("/s/$token/"); server.answer(true)
        val status = upload(token, ByteArray(300_000) { 'x'.code.toByte() }, origin = "http://evil.example")
        assertTrue(status, status.contains(" 403 "))
    }
}
