package app.aether.core

import app.aether.core.livetv.LiveChannelList
import app.aether.core.livetv.LiveTvSettings
import app.aether.core.livetv.M3uParser
import app.aether.core.livetv.TvGuide
import app.aether.core.livetv.TvGuideMatcher
import app.aether.core.livetv.XmltvParser
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class LiveTvTest {
    private val sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE tv SYSTEM "xmltv.dtd">
        <tv generator-info-name="test">
          <channel id="Rai.1.HD..101.it"><display-name lang="it">Rai 1 HD  101</display-name></channel>
          <channel id="27.Twentyseven.it"><display-name lang="it">27 Twentyseven</display-name></channel>
          <channel id="Empty.it"><display-name>Senza programmi</display-name></channel>
          <programme start="20261109200000 +0100" stop="20261109203000 +0100" channel="Rai.1.HD..101.it">
            <title lang="it">Tg1</title><desc lang="it">Il telegiornale.</desc><category>News</category>
          </programme>
          <programme start="20261109203000 +0100" stop="20261109220000 +0100" channel="Rai.1.HD..101.it">
            <title lang="it">Film &amp; Serata</title><sub-title>Prima parte</sub-title>
          </programme>
          <programme start="20261101200000 +0100" stop="20261101210000 +0100" channel="Rai.1.HD..101.it"><title>Troppo vecchio</title></programme>
          <programme start="20261109190000 +0000" stop="20261109200000 +0000" channel="27.Twentyseven.it"><title>Telefilm</title></programme>
        </tv>
    """.trimIndent()

    private val now = XmltvParser.date("20261109201500 +0100")!!

    @Test fun datesReadTheOffset() {
        assertEquals(XmltvParser.date("20261109190000 +0000"), XmltvParser.date("20261109200000 +0100"))
        assertEquals(XmltvParser.date("202611091900"), XmltvParser.date("20261109190000 +0000"))
        assertNull(XmltvParser.date("ieri"))
    }

    @Test fun parsesProgrammesInTheWindowPlainAndGzip() {
        val gz = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(sample.toByteArray()) } }.toByteArray()
        for (bytes in listOf(sample.toByteArray(), gz)) {
            val guide = XmltvParser.parse(bytes, now)
            val rai = guide.programmes["Rai.1.HD..101.it"].orEmpty()
            assertEquals(listOf("Tg1", "Film & Serata"), rai.map { it.title })
            assertEquals("Il telegiornale.", rai.first().summary)
            assertEquals("News", rai.first().category)
            assertEquals("Prima parte", rai.last().subtitle)
            assertEquals("Tg1", guide.now("Rai.1.HD..101.it", now)?.title)
            assertEquals(0.5, guide.now("Rai.1.HD..101.it", now)!!.progress(now), 0.01)
            assertEquals(3, guide.channels.size)
        }
    }

    @Test fun matchesPlaylistIdsToGuideNames() {
        val matcher = TvGuideMatcher(XmltvParser.parse(sample.toByteArray(), now))
        assertEquals("Rai.1.HD..101.it", matcher.channelId("Rai1.it", "Rai 1"))
        assertEquals("Rai.1.HD..101.it", matcher.channelId(null, "Rai 1 HD"))
        assertEquals("27.Twentyseven.it", matcher.channelId("TwentySeven.it", "27"))
        assertNull(matcher.channelId("Empty.it", "Senza programmi"))
        assertNull(matcher.channelId("Rai2.it", "Rai 2"))
        assertEquals("homeandgarden", TvGuideMatcher.normalise("Home&GardenTV.it"))
        assertEquals("tv8", TvGuideMatcher.normalise("TV8.HD.it"))
    }

    @Test fun playlistsAreParsedWithHeadersGroupsAndGuides() {
        val text = """
            #EXTM3U url-tvg="https://example.org/guide.xml.gz,https://example.org/two.xml" x-tvg-url="ftp://nope"
            #EXTINF:-1 tvg-id="Rai1.it" tvg-logo="https://l.example/a,b.png" group-title="Generalisti",Rai 1
            #EXTVLCOPT:http-user-agent=VLC
            https://example.org/rai1.m3u8
            #EXTINF:-1,Rai 1
            https://example.org/rai1.m3u8
            #EXTINF:-1,Locale
            rtmp://example.org/x
        """.trimIndent()
        val result = M3uParser.parse(text)
        assertEquals(listOf("https://example.org/guide.xml.gz", "https://example.org/two.xml"), result.guides)
        assertEquals(1, result.channels.size)
        assertEquals(1, result.skipped)
        val rai = result.channels.first()
        assertEquals("Rai1.it", rai.tvgId)
        assertEquals("https://l.example/a,b.png", rai.logo)
        assertEquals(mapOf("User-Agent" to "VLC"), rai.requestHeaders)
        assertEquals(listOf("Generalisti" to 1), LiveChannelList.groups(result.channels))
        assertEquals(1, LiveChannelList.filter(result.channels, "rai generalisti", null).size)
        assertEquals(M3uParser.stableId("x"), M3uParser.stableId("x"))
        assertEquals("af63dc4c8601ec8c", M3uParser.stableId("a"))
    }

    @Test fun guideAddressFollowsTheSettings() {
        var settings = LiveTvSettings()
        assertEquals(TvGuide.DEFAULT_ITALIAN_URL, settings.guideAddress(emptyList()))
        assertEquals("https://example.org/g.xml", settings.guideAddress(listOf("https://example.org/g.xml")))
        settings = settings.copy(guideUrl = " https://mine.example/epg.xml ")
        assertEquals("https://mine.example/epg.xml", settings.guideAddress(listOf("https://example.org/g.xml")))
        assertNull(settings.copy(guideEnabled = false).guideAddress(emptyList()))
        val decoded = Json { ignoreUnknownKeys = true }.decodeFromString(LiveTvSettings.serializer(), """{"showTab":true}""")
        assertEquals(true, decoded.guideEnabled)
        assertNotNull(decoded.guideStyle)
    }
}
