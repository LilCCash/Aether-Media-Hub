package app.aether.core

import app.aether.core.net.HttpRequest
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Against the real OpenSubtitles v3 addon (only with -Daether.live=true): the whole chain the player uses. */
class LiveSubtitlesProbe {
    @Test fun realAddonSubtitlesAreListedDownloadedAndParsed() = runBlocking {
        assumeTrue(System.getProperty("aether.live") == "true")
        val engine = AetherEngine(java.nio.file.Files.createTempDirectory("live").toFile(), app.aether.core.util.InMemorySecretStore())
        engine.registry.install("https://opensubtitles-v3.strem.io/manifest.json")
        val subs = engine.addons.subtitles("movie", "tt0111161", null)
        println("PROBE subs=${subs.size} first=${subs.firstOrNull()}")
        val sub = subs.first()
        val response = engine.http.send(HttpRequest(sub.url, timeoutSeconds = 15, maxBytes = 3 * 1024 * 1024))
        println("PROBE status=${response.status} bytes=${response.body.size}")
        val cues = app.aether.core.playback.SubtitleParser.parse(app.aether.core.playback.SubtitleParser.decode(response.body))
        println("PROBE cues=${cues.size} first=${cues.firstOrNull()}")
    }
}
