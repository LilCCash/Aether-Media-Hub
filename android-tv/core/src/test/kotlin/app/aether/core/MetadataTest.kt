package app.aether.core

import app.aether.core.metadata.MetadataEnrichment
import app.aether.core.model.MetaItem
import app.aether.core.support.FakeHttp
import app.aether.core.util.InMemorySecretStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

class MetadataTest {
    private val detail = """{"overview":"Trama","poster_path":"/p.jpg","release_date":"2010-07-16","vote_average":8.4,"runtime":148,
        "genres":[{"name":"Azione"}],"budget":160000000,"revenue":800000000,"status":"Released",
        "credits":{"cast":[{"name":"Attore","character":"Cobb","profile_path":"/a.jpg"}],"crew":[{"job":"Director","name":"Regista"}]},
        "videos":{"results":[{"site":"YouTube","type":"Trailer","key":"abc_123"}]},
        "similar":{"results":[{"id":5,"title":"Simile","poster_path":"/s.jpg","release_date":"2011-01-01"}]},
        "external_ids":{"imdb_id":"tt1375666"}}"""

    private fun engine(key: String, http: FakeHttp) = MetadataEnrichment(http, InMemorySecretStore().also { it.put(MetadataEnrichment.TMDbKey, key) })

    @Test fun v3KeyGoesInQueryAndRichDetailsAreBuilt() = runBlocking {
        val http = FakeHttp().on("/find/tt1375666", body = """{"movie_results":[{"id":27205}]}""").on("/movie/27205", body = detail)
        val meta = MetaItem("tt1375666", "movie", "Inception")
        val enriched = engine("0123456789abcdef0123456789abcdef", http).enrich(meta)
        assertEquals("Trama", enriched.description)
        assertEquals("8.4", enriched.imdbRating)
        assertTrue(http.requests.all { "api_key=0123456789abcdef0123456789abcdef" in it.url && "Authorization" !in it.headers })
        val rich = assertNotNull(engine("0123456789abcdef0123456789abcdef", http).rich(meta))
        assertEquals("Cobb", rich.cast.first().role)
        assertEquals(160000000L, rich.budget)
        assertEquals("abc_123", rich.trailers.first().youtubeId)
        assertEquals("Simile", rich.similar.first().title)
    }

    @Test fun v4TokenIsSentAsBearer() = runBlocking {
        val http = FakeHttp().on("/find/", body = """{"movie_results":[{"id":1}]}""").on("/movie/1", body = detail)
        val token = "eyJhbGciOi.eyJzdWIiOi.sig"
        engine(token, http).enrich(MetaItem("tt1", "movie", "X"))
        assertTrue(http.requests.all { it.headers["Authorization"] == "Bearer $token" && "api_key" !in it.url })
    }

    @Test fun rejectedKeyGivesAReadableReason() = runBlocking {
        val http = FakeHttp().on("/configuration", status = 401, body = """{"status_code":7}""")
        val reason = engine("badkey", http).checkTmdb()
        assertTrue(reason!!.contains("non accetta la chiave"))
    }

    @Test fun tvdbLoginThenFillsMissingFieldsAndEpisodes() = runBlocking {
        val http = FakeHttp()
            .on("/v4/login", method = "POST", body = """{"data":{"token":"T"}}""")
            .on("/search/remoteid/tt9", body = """{"data":[{"series":{"id":77}}]}""")
            .on("/series/77/extended", body = """{"data":{"overview":"Sinossi","image":"https://img/p.jpg","firstAired":"2020-01-01","genres":[{"name":"Dramma"}]}}""")
            .on("/series/77/episodes/default", body = """{"data":{"episodes":[{"seasonNumber":1,"number":1,"name":"Pilot","overview":"Ep","image":"https://img/e.jpg"}]},"links":{"next":null}}""")
        val secrets = InMemorySecretStore().also { it.put(MetadataEnrichment.TVDbKey, "key") }
        val meta = MetaItem("tt9", "series", "S", videos = listOf(app.aether.core.model.Video("tt9:1:1", season = 1, episode = 1)))
        val enriched = MetadataEnrichment(http, secrets).enrich(meta)
        assertEquals("Sinossi", enriched.description)
        assertEquals("https://img/e.jpg", enriched.videos.first().thumbnail)
        assertNull(MetadataEnrichment(http, secrets).checkTvdb())
    }
}
