package app.aether.core

import app.aether.core.model.AddonStream
import app.aether.core.model.MetaItem
import app.aether.core.model.StreamBehaviorHints
import app.aether.core.model.StreamSource
import app.aether.core.model.Video
import app.aether.core.playback.NextEpisodeResolver
import app.aether.core.playback.PlaybackCapabilities
import app.aether.core.playback.PlaybackSupport
import app.aether.core.playback.StreamAnalyzer
import app.aether.core.playback.StreamKind
import app.aether.core.playback.StreamOrdering
import app.aether.core.playback.StreamPreferences
import app.aether.core.playback.StreamQuality
import app.aether.core.playback.StreamResolver
import app.aether.core.playback.StreamSelector
import app.aether.core.playback.VideoCodec
import app.aether.core.playback.VideoQualityCap
import app.aether.core.playback.Languages
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlaybackTest {
    private fun url(name: String, details: String? = null, url: String, addon: String? = null, hints: StreamBehaviorHints = StreamBehaviorHints()) =
        AddonStream(StreamSource.Url(url), name, details, behaviorHints = hints, addonId = addon, addonName = addon)

    @Test fun analyzerReadsQualityCodecLanguageSizeAndFormat() {
        val info = StreamAnalyzer.analyze(url("Server", "Film 2160p HEVC HDR10 ITA 12.5 GB DD+", "https://cdn/x.mkv"))
        assertEquals(StreamQuality.UHD, info.quality)
        assertEquals(VideoCodec.HEVC, info.codec)
        assertEquals(listOf("it"), info.languages)
        assertEquals("MKV", info.formatLabel)
        assertEquals("12.5 GB", info.sizeLabel)
        assertTrue(info.hdr.isNotEmpty())
        assertTrue(info.support is PlaybackSupport.Supported)
        assertTrue(info.badges.any { it.contains("nel nome") }, "HDR claims are marked as coming from the name")
    }

    @Test fun containersThePlayerCannotOpenAreExplained() {
        val avi = StreamAnalyzer.analyze(url("a", null, "https://cdn/film.avi"))
        assertTrue(avi.support is PlaybackSupport.Unsupported)
        assertFalse(avi.support.isPlayable)
        assertEquals(StreamKind.HLS, StreamAnalyzer.analyze(url("a", null, "https://cdn/p/master.m3u8?t=1")).kind)
        assertEquals(StreamKind.DASH, StreamAnalyzer.analyze(url("a", null, "https://cdn/p/stream.mpd")).kind)
        assertTrue(StreamAnalyzer.analyze(url("a", null, "https://cdn/p/stream")).support is PlaybackSupport.Unknown)
        assertFalse(StreamAnalyzer.analyze(url("a", null, "rtmp://cdn/live")).support.isPlayable)
        assertFalse(StreamAnalyzer.analyze(url("a", null, "http://127.0.0.1:11470/x")).support.isPlayable)
    }

    @Test fun torrentsNeedTorBoxOrAServer() {
        val torrent = AddonStream(StreamSource.Torrent("0123456789abcdef0123456789abcdef01234567", 1), "T")
        assertFalse(StreamAnalyzer.analyze(torrent).support.isPlayable)
        assertTrue(StreamAnalyzer.analyze(torrent, PlaybackCapabilities(debridAvailable = true)).support.isPlayable)
        assertTrue(StreamAnalyzer.analyze(torrent, PlaybackCapabilities(streamingServer = "http://nas:11470")).support.isPlayable)
        assertEquals("http://nas:11470/0123456789abcdef0123456789abcdef01234567/1", StreamResolver.playbackUrl(torrent, "http://nas:11470/"))
        assertNull(StreamResolver.playbackUrl(torrent, null))
    }

    @Test fun rankingPutsPlayableFirstAndHonoursTheQualityCapAndLanguage() {
        val streams = listOf(
            url("a", "1080p x264 ENG", "https://c/a.mp4", "A"),
            url("b", "2160p HEVC ITA", "https://c/b.mkv", "B"),
            url("c", "720p ITA", "https://c/c.avi", "C"),
            AddonStream(StreamSource.External("https://x"), "page", addonId = "A"),
        )
        val best = StreamSelector.rank(streams, StreamPreferences(preferredLanguage = "it"))
        assertEquals("b", best.first().stream.name, "preferred language wins over a lower quality")
        assertFalse(best.last().info.support.isPlayable)
        val capped = StreamSelector.rank(streams, StreamPreferences(qualityCap = VideoQualityCap.P1080))
        assertEquals("a", capped.first().stream.name, "above the cap ranks below everything within it")
    }

    @Test fun byAddonOrderingFollowsTheUsersAddonList() {
        val streams = listOf(
            url("low", "480p", "https://c/1.mp4", "second"),
            url("high", "2160p", "https://c/2.mp4", "second"),
            url("first-addon", "720p", "https://c/3.mp4", "first"),
        )
        val ranked = StreamSelector.rank(streams, StreamPreferences(ordering = StreamOrdering.BY_ADDON, addonOrder = listOf("first", "second")))
        assertEquals(listOf("first-addon", "high", "low"), ranked.map { it.stream.name })
        val auto = StreamSelector.autoSelect(ranked, ordering = StreamOrdering.BY_ADDON)
        assertEquals("first-addon", auto?.stream?.name)
    }

    @Test fun autoSelectKeepsTheBingeGroupOfThePreviousEpisode() {
        val streams = listOf(
            url("x", "1080p", "https://c/1.mp4", "A"),
            url("y", "720p", "https://c/2.mp4", "A", StreamBehaviorHints(bingeGroup = "grp")),
        )
        val ranked = StreamSelector.rank(streams, StreamPreferences())
        assertEquals("y", StreamSelector.autoSelect(ranked, "grp")?.stream?.name)
        assertEquals("x", StreamSelector.autoSelect(ranked, null)?.stream?.name)
    }

    @Test fun languagesAreNormalised() {
        assertEquals("it", Languages.normalise("ita"))
        assertEquals("pt", Languages.normalise("pt-BR"))
        assertEquals("pt", Languages.normalise("pob"))
        assertEquals("Italiano", Languages.displayName("ita"))
        assertTrue(Languages.matches("fre", "fra"))
    }

    private fun series(): MetaItem = MetaItem(
        "tt1", "series", "S", videos = listOf(
            Video("tt1:0:1", season = 0, episode = 1), Video("tt1:1:1", season = 1, episode = 1), Video("tt1:1:2", season = 1, episode = 2),
            Video("tt1:2:1", season = 2, episode = 1, releasedMillis = System.currentTimeMillis() + 86_400_000L),
        ),
    )

    @Test fun nextEpisodeSkipsSpecialsAndUnreleased() {
        val meta = series()
        assertEquals("tt1:1:2", NextEpisodeResolver.next("tt1:1:1", meta)?.id)
        assertNull(NextEpisodeResolver.next("tt1:1:2", meta), "season 2 is not released yet")
        assertNull(NextEpisodeResolver.next("tt1:0:1", meta)?.takeIf { it.season == 0 }, "no jump from a special into a regular season's special")
        assertEquals("tt1:1:1", NextEpisodeResolver.previous("tt1:1:2", meta)?.id)
    }

    @Test fun episodeToPlayResumesThenContinuesThenStartsFromTheFirstRegularEpisode() {
        val meta = series()
        assertEquals("tt1:1:2", NextEpisodeResolver.episodeToPlay(meta, emptySet(), null, "tt1:1:2")?.id)
        assertEquals("tt1:1:2", NextEpisodeResolver.episodeToPlay(meta, setOf("tt1:1:1"), "tt1:1:1", null)?.id)
        assertEquals("tt1:1:1", NextEpisodeResolver.episodeToPlay(meta, emptySet(), null, null)?.id)
        assertNotNull(NextEpisodeResolver.episodeToPlay(meta, setOf("tt1:1:1", "tt1:1:2"), "tt1:1:2", null))
    }
}

class SubtitleCleanerTest {
    @kotlin.test.Test fun removesNotesForTheHardOfHearing() {
        val strip = app.aether.core.playback.SubtitleCleaner::strip
        kotlin.test.assertEquals("Chi è?", strip("[bussano alla porta]\nChi è?"))
        kotlin.test.assertEquals("Ciao", strip("MARCO: Ciao"))
        kotlin.test.assertEquals("", strip("♪ musica ♪"))
        kotlin.test.assertEquals("Vieni !", strip("Vieni (subito) !"))
    }
}

class SubtitleParserTest {
    private val srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Ciao</i>\r\nmondo\r\n\r\n2\r\n00:00:10,000 --> 00:00:12,000\r\n{\\an8}Dopo\r\n"
    private val vtt = "WEBVTT\n\n00:05.000 --> 00:07.250 align:start\nSolo VTT\n"

    @kotlin.test.Test fun readsSrtAndVtt() {
        val a = app.aether.core.playback.SubtitleParser.parse(srt)
        kotlin.test.assertEquals(2, a.size)
        kotlin.test.assertEquals("Ciao\nmondo", a[0].text)
        kotlin.test.assertEquals(3500L, a[0].endMs)
        kotlin.test.assertEquals("Dopo", a[1].text)
        val b = app.aether.core.playback.SubtitleParser.parse(vtt)
        kotlin.test.assertEquals(5000L, b[0].startMs)
        kotlin.test.assertEquals(7250L, b[0].endMs)
    }

    @kotlin.test.Test fun delayAndAnticipation() {
        val cues = app.aether.core.playback.SubtitleParser.parse(srt)
        val active = app.aether.core.playback.SubtitleParser::active
        kotlin.test.assertEquals(0, active(cues, 500, 0).size)
        kotlin.test.assertEquals(1, active(cues, 500, -1000).size)   // anticipated by 1 s: shows at 0 s
        kotlin.test.assertEquals(0, active(cues, 1500, 2000).size)   // delayed by 2 s: not yet
        kotlin.test.assertEquals(1, active(cues, 3500, 2000).size)
    }

    @kotlin.test.Test fun fallsBackToWindows1252() {
        val bytes = "caffè".toByteArray(charset("windows-1252"))
        kotlin.test.assertEquals("caffè", app.aether.core.playback.SubtitleParser.decode(bytes))
    }
}
