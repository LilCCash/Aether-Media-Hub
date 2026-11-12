package app.aether.core

import app.aether.core.metadata.PersonFilter
import app.aether.core.metadata.PersonProfile
import app.aether.core.metadata.PersonRole
import app.aether.core.metadata.WikidataAwards
import app.aether.core.search.IntentGenre
import app.aether.core.search.IntentKind
import app.aether.core.search.IntentSort
import app.aether.core.search.NaturalQueryParser
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PeopleAndQueryTest {
    private val parser = NaturalQueryParser(currentYear = 2026)

    @Test fun comedyOfRecentYears() {
        val out = parser.parse("commedie demenziali degli ultimi anni")
        assertEquals(listOf(IntentGenre.COMEDY), out.intent.genres)
        assertEquals(2021, out.intent.yearFrom)
        assertTrue("slapstick" in out.intent.keywords)
    }

    @Test fun decadesCountriesAndKind() {
        val out = parser.parse("film horror coreani anni 80")
        assertEquals(IntentKind.MOVIE, out.intent.kind)
        assertEquals(listOf(IntentGenre.HORROR), out.intent.genres)
        assertEquals(1980, out.intent.yearFrom); assertEquals(1989, out.intent.yearTo)
        assertEquals(listOf("KR"), out.intent.countries)
        val words = parser.parse("migliori serie di fantascienza degli anni novanta")
        assertEquals(IntentKind.SERIES, words.intent.kind)
        assertEquals(IntentSort.RATING, words.intent.sort)
        assertEquals(1990, words.intent.yearFrom)
    }

    @Test fun similarTo() {
        val out = parser.parse("film simili a Toy Story")
        assertEquals("Toy Story", out.intent.similarTo)
        assertEquals(IntentKind.MOVIE, out.intent.kind)
        assertEquals("Lost", parser.parse("serie come Lost").intent.similarTo)
        assertNull(parser.parse("come Lost").intent.similarTo)
    }

    @Test fun plainTitlesAreNotNatural() {
        assertFalse(NaturalQueryParser.looksNatural("Interstellar"))
        assertFalse(NaturalQueryParser.looksNatural("Il trono di spade"))
        assertTrue(NaturalQueryParser.looksNatural("thriller italiani del 2019"))
    }

    @Test fun personProfileFromTmdb() {
        val json = Json.parseToJsonElement("""{"name":"Denis Villeneuve","biography":" Regista ","birthday":"1967-10-03","known_for_department":"Directing",
          "profile_path":"/p.jpg","external_ids":{"wikidata_id":"Q105"},
          "combined_credits":{"cast":[{"id":1,"title":"Cameo","character":"","poster_path":"/a.jpg"},{"id":9,"name":"Talk","character":"Self","poster_path":"/t.jpg","genre_ids":[10767],"media_type":"tv"},
            {"id":5,"name":"Serie","character":"A","poster_path":"/s.jpg","media_type":"tv"},{"id":5,"name":"Serie","character":"B","poster_path":"/s.jpg","media_type":"tv"}],
          "crew":[{"id":2,"title":"Dune","job":"Director","poster_path":"/d.jpg","release_date":"2021-09-15","genre_ids":[878],"popularity":90,"vote_average":8.0},
                  {"id":2,"title":"Dune","job":"Screenplay","poster_path":"/d.jpg","release_date":"2021-09-15","genre_ids":[878],"popularity":90},
                  {"id":3,"title":"Prisoners","job":"Director","poster_path":"/x.jpg","release_date":"2013-01-01","genre_ids":[53],"popularity":20},
                  {"id":4,"title":"Catering","job":"Catering","poster_path":"/c.jpg"}]}}""") as JsonObject
        val p = PersonProfile.fromTmdb(7, json, "x", "https://img")
        assertEquals("Regista", p.biography)
        assertEquals("Regista", p.profession)
        assertEquals("Q105", p.wikidataId)
        assertEquals(listOf("Dune", "Prisoners", "Serie"), p.filmography.map { it.title })
        // The same title twice in TMDB's credits (two roles) stays one entry: the list of the page needs unique keys.
        assertEquals(p.filmography.size, p.filmography.map { it.key }.toSet().size)
        assertEquals(listOf(PersonRole.DIRECTOR, PersonRole.WRITER), p.filmography[0].roles)
        assertEquals(listOf("Fantascienza"), p.filmography[0].genres)
        assertTrue(p.lifeLine(java.time.LocalDate.of(2026, 1, 1))!!.startsWith("3 ottobre 1967 (58 anni)"))
        assertEquals(listOf("Prisoners"), PersonFilter(decade = 2010).apply(p.filmography).map { it.title })
        assertEquals(listOf(2020, 2010), PersonFilter.decades(p.filmography))
    }

    @Test fun wikidataAwards() {
        val w = WikidataAwards(app.aether.core.net.HttpClient { throw IllegalStateException() })
        val claims = w.awardClaims("""{"entities":{"Q1":{"claims":{"P166":[
            {"mainsnak":{"datavalue":{"value":{"id":"Q10"}}},"qualifiers":{"P585":[{"datavalue":{"value":{"time":"+2016-02-28T00:00:00Z"}}}]}},
            {"mainsnak":{"datavalue":{"value":{"id":"Q11"}}}},
            {"mainsnak":{"datavalue":{"value":{"id":"bad"}}}}]}}}}""", "Q1")
        assertEquals(listOf("Q10" to 2016, "Q11" to null), claims)
        val awards = w.awards(claims, """{"entities":{"Q10":{"labels":{"en":{"value":"Oscar"},"it":{"value":"Premio Oscar"}}},"Q11":{"labels":{"en":{"value":"BAFTA"}}}}}""", listOf("it", "en"), 10)
        assertEquals(listOf("Premio Oscar (2016)", "BAFTA"), awards.map { it.line })
    }
}
