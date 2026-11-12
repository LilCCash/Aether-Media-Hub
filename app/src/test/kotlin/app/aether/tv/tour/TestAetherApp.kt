package app.aether.tv.tour

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import app.aether.core.AetherEngine
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import app.aether.core.net.HttpResponse
import app.aether.core.util.InMemorySecretStore
import app.aether.tv.AetherApp
import java.io.File
import kotlinx.coroutines.runBlocking

/**
 * The app on fake data, for the tour tests: an addon with films and series (pictures drawn on the spot), details, sources and
 * subtitles. Nothing leaves the test.
 */
class TestAetherApp : AetherApp() {
    override val keyboardInputOnly: Boolean get() = true

    override fun createEngine(): AetherEngine {
        val dir = File(cacheDir, "tour-${System.nanoTime()}").apply { mkdirs() }
        val engine = AetherEngine(dir, InMemorySecretStore(), http = FakeAddonHttp(Pictures(File(dir, "pictures"))))
        runBlocking { engine.registry.install(FakeAddonHttp.MANIFEST_URL) }
        return engine
    }
}

/** Posters and backdrops drawn as gradients with the title on them. */
class Pictures(private val dir: File) {
    init { dir.mkdirs() }

    fun poster(seed: Int, title: String): String = draw("p$seed", 400, 600, seed, title)
    fun backdrop(seed: Int, title: String): String = draw("b$seed", 1280, 720, seed, title)

    private fun draw(name: String, w: Int, h: Int, seed: Int, title: String): String {
        val file = File(dir, "$name.png")
        if (!file.exists()) {
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val hue = (seed * 47 % 360).toFloat()
            val paint = Paint().apply {
                shader = LinearGradient(0f, 0f, w.toFloat(), h.toFloat(), Color.HSVToColor(floatArrayOf(hue, 0.6f, 0.75f)), Color.HSVToColor(floatArrayOf((hue + 60) % 360, 0.7f, 0.25f)), Shader.TileMode.CLAMP)
            }
            canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), paint)
            val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textSize = w / 9f; isFakeBoldText = true }
            canvas.drawText(title.take(14), w * 0.08f, h * 0.85f, text)
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 90, it) }
        }
        return file.toURI().toString()
    }
}

class FakeAddonHttp(private val pictures: Pictures) : HttpClient {
    companion object {
        const val MANIFEST_URL = "https://addon.tour.example/manifest.json"
        val FILMS = listOf(
            "Dune: Parte due", "Oppenheimer", "Il gladiatore II", "Interstellar", "Blade Runner 2049", "Arrival", "Povere creature!",
            "La zona d'interesse", "Anatomia di una caduta", "Past Lives", "Killers of the Flower Moon", "Napoleon", "Wonka", "Barbie",
        )
        val SERIES = listOf("Il trono di spade", "Severance", "The Bear", "Shōgun", "Fallout", "The Last of Us", "Dark", "Andor")
    }

    private fun film(i: Int) = """{"id":"tt10$i","type":"movie","name":"${FILMS[i]}","poster":"${pictures.poster(i, FILMS[i])}",
        "background":"${pictures.backdrop(i, FILMS[i])}","releaseInfo":"202${i % 5}","imdbRating":"${7 + i % 3}.${i % 10}",
        "description":"Una storia che attraversa deserti, città e destini: un titolo di prova con una trama abbastanza lunga da andare a capo più volte sullo schermo.",
        "genres":["Fantascienza","Avventura"],"runtime":"${100 + i * 3} min"}"""

    private fun show(i: Int) = """{"id":"tt20$i","type":"series","name":"${SERIES[i]}","poster":"${pictures.poster(100 + i, SERIES[i])}",
        "background":"${pictures.backdrop(100 + i, SERIES[i])}","releaseInfo":"201${i}–","imdbRating":"8.$i","genres":["Dramma"],
        "description":"Una serie di prova."}"""

    override suspend fun send(request: HttpRequest): HttpResponse {
        val url = request.url
        val body = when {
            url == MANIFEST_URL -> """{"id":"org.tour.addon","version":"1.0.0","name":"Catalogo di prova","types":["movie","series"],
                "resources":["catalog","meta","stream","subtitles"],"idPrefixes":["tt"],
                "catalogs":[{"type":"movie","id":"top","name":"Film popolari","extra":[{"name":"genre","options":["Azione","Dramma"]},{"name":"skip"}]},
                            {"type":"series","id":"top","name":"Serie del momento","extra":[{"name":"skip"}]},
                            {"type":"movie","id":"new","name":"Nuove uscite"}]}"""
            "/catalog/movie/" in url -> """{"metas":[${FILMS.indices.joinToString(",") { film(it) }}]}"""
            "/catalog/series/" in url -> """{"metas":[${SERIES.indices.joinToString(",") { show(it) }}]}"""
            "/meta/movie/" in url -> {
                val i = url.substringAfter("tt10").substringBefore(".json").toIntOrNull() ?: 0
                """{"meta":${film(i).dropLast(1)},"cast":["Timothée Chalamet","Zendaya","Rebecca Ferguson"],"director":["Denis Villeneuve"]}}"""
            }
            "/meta/series/" in url -> {
                val i = url.substringAfter("tt20").substringBefore(".json").toIntOrNull() ?: 0
                val videos = (1..2).flatMap { s -> (1..6).map { e -> """{"id":"tt20$i:$s:$e","title":"Episodio $e","season":$s,"episode":$e,"overview":"Trama dell'episodio $e.","released":"2024-0$s-1${e}T00:00:00.000Z"}""" } }
                """{"meta":${show(i).dropLast(1)},"videos":[${videos.joinToString(",")}]}}"""
            }
            "/stream/" in url -> """{"streams":[
                {"name":"Tour 4K","title":"Film.2160p.HDR.HEVC.DDP5.1.ITA.ENG.mkv\n💾 18.2 GB","url":"https://cdn.tour.example/f4k.mkv"},
                {"name":"Tour 1080p","title":"Film.1080p.WEB-DL.H264.AAC.ITA.mp4\n💾 3.1 GB","url":"https://cdn.tour.example/f1080.mp4"},
                {"name":"Tour 720p","title":"Film.720p.x264.ENG.mp4","url":"https://cdn.tour.example/f720.mp4"}]}"""
            "/subtitles/" in url -> """{"subtitles":[{"id":"s1","url":"https://subs.tour.example/it.srt","lang":"ita"}]}"""
            else -> return HttpResponse(404, "{}".toByteArray())
        }
        return HttpResponse(200, body.toByteArray())
    }
}
