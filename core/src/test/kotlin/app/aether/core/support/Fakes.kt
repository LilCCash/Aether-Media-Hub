package app.aether.core.support

import app.aether.core.net.AddonError
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import app.aether.core.net.HttpResponse
import kotlinx.coroutines.delay

/** A transport that answers from a table and records what was asked. Routes are matched by "the URL contains …", first match wins. */
class FakeHttp : HttpClient {
    class Route(val contains: String, val method: String? = null, val handler: suspend (HttpRequest) -> HttpResponse)

    val routes = ArrayList<Route>()
    val requests = ArrayList<HttpRequest>()

    fun on(contains: String, status: Int = 200, body: String, delayMillis: Long = 0, method: String? = null): FakeHttp {
        routes.add(Route(contains, method) { if (delayMillis > 0) delay(delayMillis); HttpResponse(status, body.toByteArray()) })
        return this
    }

    fun fail(contains: String, error: AddonError): FakeHttp {
        routes.add(Route(contains) { throw error })
        return this
    }

    @Synchronized
    private fun record(request: HttpRequest) { requests.add(request) }

    override suspend fun send(request: HttpRequest): HttpResponse {
        record(request)
        val route = routes.firstOrNull { request.url.contains(it.contains) && (it.method == null || it.method == request.method) }
            ?: return HttpResponse(404, "{}".toByteArray())
        return route.handler(request)
    }

    fun count(contains: String) = synchronized(this) { requests.count { it.url.contains(contains) } }
}

object Samples {
    const val CINEMETA_MANIFEST = """{"id":"com.linvo.cinemeta","version":"3.0.0","name":"Cinemeta","description":"x",
      "types":["movie","series"],"resources":["catalog","meta",{"name":"stream","types":["movie"],"idPrefixes":["tt"]}],
      "idPrefixes":["tt"],
      "catalogs":[{"type":"movie","id":"top","name":"Popolari","extra":[{"name":"genre","options":["Azione","Dramma"]},{"name":"skip"}]},
                  {"type":"series","id":"top","name":"Serie popolari","extra":[{"name":"search","isRequired":false},{"name":"skip"}]},
                  {"type":"movie","id":"search-only","name":"Cerca","extra":[{"name":"search","isRequired":true}]}]}"""

    const val STREAM_ADDON_MANIFEST = """{"id":"org.test.streams","version":"1.0.0","name":"Sorgenti","types":["movie","series"],
      "resources":[{"name":"stream","types":["movie","series"],"idPrefixes":["tt"]},{"name":"subtitles","types":["movie","series"],"idPrefixes":["tt"]}],"catalogs":[]}"""

    const val CATALOG = """{"metas":[{"id":"tt0111161","type":"movie","name":"Le ali della libertà","poster":"https://img/p1.jpg","releaseInfo":"1994","imdbRating":"9.3"},
      {"id":"tt0068646","type":"movie","name":"Il padrino","poster":"https://img/p2.jpg","releaseInfo":"1972"},{"nope":true}],"cacheMaxAge":600}"""

    const val META_MOVIE = """{"meta":{"id":"tt0111161","type":"movie","name":"Le ali della libertà","description":"Due uomini in prigione.","genres":["Dramma"],
      "background":"https://img/bg.jpg","runtime":"142 min","cast":["Tim Robbins","Morgan Freeman"],"trailers":[{"source":"abc123","type":"Trailer"}]}}"""

    const val META_SERIES = """{"meta":{"id":"tt0944947","type":"series","name":"Il trono di spade","videos":[
      {"id":"tt0944947:1:2","title":"La strada dei re","season":1,"episode":2,"released":"2011-04-24T00:00:00.000Z"},
      {"id":"tt0944947:1:1","title":"L'inverno sta arrivando","season":1,"episode":1,"released":"2011-04-17T00:00:00.000Z"},
      {"id":"tt0944947:0:1","title":"Speciale","season":0,"episode":1},
      {"id":"tt0944947:2:1","title":"Il Nord ricorda","season":2,"episode":1,"released":"2012-04-01T00:00:00.000Z"}]}}"""

    const val STREAMS = """{"streams":[
      {"name":"Server A","description":"Film 1080p H264 ITA","url":"https://cdn.example/film.1080p.mp4"},
      {"name":"Server B","title":"Film 2160p HEVC HDR10 ENG 12.5 GB","url":"https://cdn.example/film.2160p.mkv"},
      {"name":"Torrent","description":"Film 720p","infoHash":"0123456789abcdef0123456789abcdef01234567","fileIdx":1},
      {"name":"Pagina","externalUrl":"https://example.org/watch"},
      {"description":"senza sorgente"}]}"""

    const val SUBTITLES = """{"subtitles":[{"id":"1","url":"https://subs/it.srt","lang":"ita"},{"id":"2","url":"https://subs/en.srt","lang":"eng"},{"id":"3","url":"https://subs/it.srt","lang":"ita"}]}"""
}
