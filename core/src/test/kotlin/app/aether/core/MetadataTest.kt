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

class MetadataExtrasTest {
    private fun engine(http: FakeHttp, tmdb: String = "0123456789abcdef0123456789abcdef") =
        MetadataEnrichment(http, InMemorySecretStore().also { it.put(MetadataEnrichment.TMDbKey, tmdb) }) { "en-US" }

    @Test fun personCreditsShowFilmAndCharacter() = runBlocking {
        val http = FakeHttp().on("/person/5/combined_credits", body = """{"cast":[
            {"id":1,"media_type":"movie","title":"Film A","character":"Bella","poster_path":"/a.jpg","release_date":"2023-01-01","popularity":50,"genre_ids":[18]},
            {"id":2,"media_type":"tv","name":"Talk","character":"Self","poster_path":"/t.jpg","popularity":90,"genre_ids":[10767]},
            {"id":3,"media_type":"movie","title":"Senza ruolo","character":"","poster_path":"/b.jpg","popularity":10,"genre_ids":[]}]}""")
        val credits = engine(http).personCredits(5)
        assertEquals(1, credits.size)
        assertEquals("Film A", credits[0].title)
        assertEquals("Bella", credits[0].character)
        assertTrue(http.requests.single().url.contains("language=en-US"))
    }

    @Test fun logoPrefersTheViewersLanguageThenLikes() = runBlocking {
        val http = FakeHttp().on("webservice.fanart.tv/v3/movies/tt1", body = """{"hdmovielogo":[
            {"url":"https://x/en.png","lang":"en","likes":"9"},{"url":"https://x/it.png","lang":"it","likes":"1"}]}""")
        val logo = MetadataEnrichment(http, InMemorySecretStore()) { "it-IT" }.titleLogo(MetaItem("tt1", "movie", "X"))
        assertEquals("https://x/it.png", logo)
        assertTrue("api_key=" in http.requests.single().url)
    }

    @Test fun tmdbTextBeatsTheAddonText() = runBlocking {
        val http = FakeHttp().on("/find/tt1", body = """{"movie_results":[{"id":1}]}""")
            .on("/movie/1", body = """{"overview":"Trama italiana","genres":[{"name":"Commedia"}]}""")
        val meta = engine(http).enrich(MetaItem("tt1", "movie", "X", description = "English plot", genres = listOf("Comedy")))
        assertEquals("Trama italiana", meta.description)
        assertEquals(listOf("Commedia"), meta.genres)
    }

    @Test fun backupCarriesKeys() {
        val text = app.aether.core.library.BackupCodec.encode(app.aether.core.library.LibraryState(), emptyList(), false, "1", keys = mapOf("tmdb" to "k1", "torbox" to "k2"))
        assertEquals(mapOf("tmdb" to "k1", "torbox" to "k2"), app.aether.core.library.BackupCodec.decode(text).keys)
        assertTrue(app.aether.core.library.BackupCodec.decode(app.aether.core.library.BackupCodec.encode(app.aether.core.library.LibraryState(), emptyList(), false, "1")).keys.isEmpty())
    }
}
