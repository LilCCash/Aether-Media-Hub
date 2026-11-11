package app.aether.core

import app.aether.core.addons.AddonPayload
import app.aether.core.addons.ResponseDecoder
import app.aether.core.addons.ResponseDecodingError
import app.aether.core.model.ResourceName
import app.aether.core.model.StreamSource
import app.aether.core.support.Samples
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ResponseDecoderTest {
    @Test fun catalogDropsBadEntriesAndReadsCacheHints() {
        val response = ResponseDecoder.decode(Samples.CATALOG, ResourceName.CATALOG)
        val items = (response.payload as AddonPayload.Metas).items
        assertEquals(listOf("tt0111161", "tt0068646"), items.map { it.id })
        assertEquals(1994, items[0].year)
        assertEquals(9.3, items[0].ratingValue)
        assertEquals(600, response.cache.maxAge)
    }

    @Test fun emptyObjectIsMalformedButEmptyArrayIsFine() {
        assertFailsWith<ResponseDecodingError.MissingKey> { ResponseDecoder.decode("{}", ResourceName.CATALOG) }
        assertTrue((ResponseDecoder.decode("""{"metas":[]}""", ResourceName.CATALOG).payload as AddonPayload.Metas).items.isEmpty())
        assertFailsWith<ResponseDecodingError.NotJson> { ResponseDecoder.decode("<html>", ResourceName.CATALOG) }
        assertFailsWith<ResponseDecodingError.NotAnObject> { ResponseDecoder.decode("[1,2]", ResourceName.META) }
    }

    @Test fun movieMetaKeepsWhatTheAddonSent() {
        val meta = (ResponseDecoder.decode(Samples.META_MOVIE, ResourceName.META).payload as AddonPayload.Meta).item
        assertEquals("142 min", meta.runtime)
        assertEquals(listOf("Tim Robbins", "Morgan Freeman"), meta.cast)
        assertEquals("abc123", meta.trailers.single().youtubeId)
        assertEquals("tt0111161", meta.externalIds.imdb)
        assertTrue(meta.videos.isEmpty())
    }

    @Test fun seriesEpisodesAreSortedAndSeasonsListed() {
        val meta = (ResponseDecoder.decode(Samples.META_SERIES, ResourceName.META).payload as AddonPayload.Meta).item
        assertEquals(listOf("tt0944947:0:1", "tt0944947:1:1", "tt0944947:1:2", "tt0944947:2:1"), meta.videos.map { it.id })
        assertEquals(listOf(0, 1, 2), meta.seasons)
        assertEquals("S01E02", meta.videos[2].episodeLabel)
        assertEquals(2, meta.videos(inSeason = 1).size)
    }

    @Test fun streamsAreClassifiedBySourceKind() {
        val streams = (ResponseDecoder.decode(Samples.STREAMS, ResourceName.STREAM).payload as AddonPayload.Streams).items
        assertEquals(5, streams.size)
        assertIs<StreamSource.Url>(streams[0].source)
        val torrent = streams[2].source
        assertIs<StreamSource.Torrent>(torrent)
        assertEquals(1, torrent.fileIndex)
        assertIs<StreamSource.External>(streams[3].source)
        assertIs<StreamSource.Unknown>(streams[4].source)
    }

    @Test fun streamHintsAcceptNumbersAsStringsAndProxyHeaders() {
        val text = """{"streams":[{"url":"https://a/b.mp4","behaviorHints":{"videoSize":"1234","bingeGroup":"g1","notWebReady":"true",
            "proxyHeaders":{"request":{"Referer":"https://x","N":5}}}}]}"""
        val stream = (ResponseDecoder.decode(text, ResourceName.STREAM).payload as AddonPayload.Streams).items.single()
        assertEquals(1234L, stream.behaviorHints.videoSize)
        assertEquals("g1", stream.behaviorHints.bingeGroup)
        assertTrue(stream.behaviorHints.notWebReady)
        assertEquals("https://x", stream.behaviorHints.proxyRequestHeaders["Referer"])
        assertEquals("5", stream.behaviorHints.proxyRequestHeaders["N"])
    }

    @Test fun subtitles() {
        val subs = (ResponseDecoder.decode(Samples.SUBTITLES, ResourceName.SUBTITLES).payload as AddonPayload.Subtitles).items
        assertEquals(3, subs.size)
        assertEquals("ita", subs[0].lang)
    }

    @Test fun manifestOfAnAddonCatalog() {
        val text = """{"addons":[{"transportName":"http","transportUrl":"https://a/manifest.json","manifest":{"id":"x","version":"1","name":"X","resources":["stream"],"types":["movie"]}},{"bad":1}]}"""
        val addons = (ResponseDecoder.decode(text, ResourceName.ADDON_CATALOG).payload as AddonPayload.Addons).items
        assertEquals(1, addons.size)
        assertNull(null)
        assertEquals("X", addons[0].manifest.name)
    }
}
