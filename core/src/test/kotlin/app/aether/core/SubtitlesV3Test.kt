package app.aether.core

import app.aether.core.diagnostics.DiagnosticLog
import app.aether.core.diagnostics.Redactor
import app.aether.core.playback.OpenSubtitlesCatalog
import app.aether.core.playback.SubtitleParser
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SubtitlesV3Test {
    @Test fun srtWithSpacesOnTheBlankLinesStillSplits() {
        val srt = "1\n00:00:01,000 --> 00:00:02,500\nPrima\n \n2\n00:00:03,000 --> 00:00:04,000\nSeconda\nriga\n\t\n3\n00:00:05,000 --> 00:00:06,000\nTerza"
        val cues = SubtitleParser.parse(srt)
        assertEquals(listOf("Prima", "Seconda\nriga", "Terza"), cues.map { it.text })
        assertEquals(1000L, cues[0].startMs)
        assertEquals(2500L, cues[0].endMs)
    }

    @Test fun srtWithoutBlankLinesBetweenCues() {
        val srt = "1\n00:00:01,000 --> 00:00:02,000\nUno\n2\n00:00:03,000 --> 00:00:04,000\nDue"
        assertEquals(listOf("Uno", "Due"), SubtitleParser.parse(srt).map { it.text })
    }

    @Test fun assDialogues() {
        val ass = "[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" +
            "Dialogue: 0,0:00:01.50,0:00:04.00,Default,,0,0,0,,{\\i1}Ciao{\\i0}, come stai?\\NBene\n" +
            "Dialogue: 0,0:01:00.00,0:01:02.25,Default,,0,0,0,,Una virgola, qui"
        val cues = SubtitleParser.parse(ass)
        assertEquals(2, cues.size)
        assertEquals("Ciao, come stai?\nBene", cues[0].text)
        assertEquals(1500L, cues[0].startMs)
        assertEquals("Una virgola, qui", cues[1].text)
        assertEquals(62250L, cues[1].endMs)
    }

    @Test fun microDvd() {
        val sub = "{1}{1}25\n{25}{50}Uno|Due"
        val cues = SubtitleParser.parse(sub)
        assertEquals(1, cues.size)
        assertEquals(1000L, cues[0].startMs)
        assertEquals("Uno\nDue", cues[0].text)
    }

    @Test fun gzipAndZipAreOpened() {
        val srt = "1\n00:00:01,000 --> 00:00:02,000\nCompresso è\n"
        val gz = java.io.ByteArrayOutputStream().also { out -> java.util.zip.GZIPOutputStream(out).use { it.write(srt.toByteArray()) } }.toByteArray()
        assertEquals("Compresso è", SubtitleParser.parse(SubtitleParser.decode(gz)).single().text)
        val zip = java.io.ByteArrayOutputStream().also { out ->
            java.util.zip.ZipOutputStream(out).use { z ->
                z.putNextEntry(java.util.zip.ZipEntry("leggimi.nfo")); z.write("x".toByteArray()); z.closeEntry()
                z.putNextEntry(java.util.zip.ZipEntry("film.srt")); z.write(srt.toByteArray()); z.closeEntry()
            }
        }.toByteArray()
        assertEquals("Compresso è", SubtitleParser.parse(SubtitleParser.decode(zip)).single().text)
    }

    @Test fun utf16() {
        val srt = "1\n00:00:01,000 --> 00:00:02,000\nCittà\n"
        val bytes = byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + srt.toByteArray(Charsets.UTF_16LE)
        assertEquals("Città", SubtitleParser.parse(SubtitleParser.decode(bytes)).single().text)
    }

    @Test fun catalogueUrlsAndLanguages() {
        assertEquals("ita", OpenSubtitlesCatalog.catalogLanguage("it"))
        assertEquals("ita", OpenSubtitlesCatalog.catalogLanguage("ita"))
        assertEquals("pob", OpenSubtitlesCatalog.catalogLanguage("pt-BR"))
        assertNull(OpenSubtitlesCatalog.catalogLanguage("off"))
        assertEquals("https://rest.opensubtitles.org/search/imdbid-0111161/sublanguageid-ita", OpenSubtitlesCatalog.searchUrl("tt0111161", "ita"))
        assertEquals("https://rest.opensubtitles.org/search/episode-3/imdbid-0944947/season-1/sublanguageid-eng", OpenSubtitlesCatalog.searchUrl("tt0944947:1:3", "eng"))
        assertNull(OpenSubtitlesCatalog.searchUrl("tmdb:123", "ita"))
    }

    @Test fun catalogueAnswerIsRankedByDownloads() {
        val body = """[
          {"SubDownloadLink":"https://dl.opensubtitles.org/a.gz","SubLanguageID":"ita","SubFormat":"srt","IDSubtitleFile":"1","MovieReleaseName":"Film.2020.1080p","SubDownloadsCnt":"10"},
          {"SubDownloadLink":"https://dl.opensubtitles.org/b.gz","SubLanguageID":"ita","SubFormat":"srt","IDSubtitleFile":"2","SubFileName":"b.srt","SubDownloadsCnt":"500","SubHearingImpaired":"1"},
          {"SubDownloadLink":"https://dl.opensubtitles.org/c.gz","SubLanguageID":"ita","SubFormat":"idx","IDSubtitleFile":"3"},
          {"SubDownloadLink":"http://insecure/d.gz","SubLanguageID":"ita","SubFormat":"srt","IDSubtitleFile":"4"},
          {"SubDownloadLink":"https://dl.opensubtitles.org/a.gz","SubLanguageID":"ita","SubFormat":"srt","IDSubtitleFile":"1"}
        ]"""
        val subs = OpenSubtitlesCatalog.parse(body)
        assertEquals(listOf("osorg-2", "osorg-1"), subs.map { it.id })
        assertEquals("b.srt · non udenti", subs[0].label)
        assertEquals(OpenSubtitlesCatalog.NAME, subs[0].addonName)
        assertTrue(OpenSubtitlesCatalog.parse("non json").isEmpty())
    }

    @Test fun redactorRemovesSecrets() {
        val text = Redactor.redact("GET https://torrentio.strem.fun/realdebrid=ABCDEF123/stream/movie/tt1.json apikey=supersecret Bearer abc.def mail me@example.com")
        assertFalse("ABCDEF123" in text)
        assertFalse("supersecret" in text)
        assertFalse("abc.def" in text)
        assertFalse("me@example.com" in text)
        assertTrue("torrentio.strem.fun" in text)
    }

    @Test fun diagnosticLogKeepsRedactedLinesAndSurvivesRestart() {
        val file = java.io.File.createTempFile("diag", ".log").apply { delete() }
        val log = DiagnosticLog(file, capacity = 3)
        log.info("rete", "token=abc123 chiesto")
        log.debug("rete", "non tenuto")
        repeat(4) { log.warn("player", "riga $it") }
        assertEquals(3, log.entries().size)
        assertTrue(log.exportText().contains("riga 3"))
        log.error("player", "errore", IllegalStateException("boom"))
        Thread.sleep(2600)
        val again = DiagnosticLog(file, capacity = 3)
        assertTrue(again.entries().any { "boom" in it.message })
        log.clear()
        assertTrue(log.entries().isEmpty())
    }
}
