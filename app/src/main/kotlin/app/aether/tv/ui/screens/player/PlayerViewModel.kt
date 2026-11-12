package app.aether.tv.ui.screens.player

import android.content.Context
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import app.aether.core.AetherEngine
import app.aether.core.debrid.DebridFile
import app.aether.core.model.AddonSubtitle
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.core.playback.Languages
import app.aether.core.playback.NextEpisodeResolver
import app.aether.core.playback.RankedStream
import app.aether.core.model.StreamSource
import app.aether.core.segments.EpisodeSkipSegments
import app.aether.core.segments.SkipSegment
import app.aether.tv.PlaybackRequest
import app.aether.tv.Session
import app.aether.tv.StreamRequest
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/** One audio or subtitle choice shown in the player's panels. */
data class TrackOption(val id: String, val label: String, val detail: String?, val selected: Boolean, val supported: Boolean = true, val fromAddon: Boolean = false, val lang: String? = null, val addonName: String? = null)

/** The playback engine of the app (Media3 ExoPlayer) and everything around it: tracks, subtitles from the addons, progress, skip, next episode. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlayerViewModel(private val engine: AetherEngine, context: Context, private val request: PlaybackRequest) : ViewModel() {
    data class UiState(
        val title: String,
        val subtitle: String?,
        val isPlaying: Boolean = false,
        val buffering: Boolean = true,
        val positionMs: Long = 0,
        val durationMs: Long = 0,
        val bufferedMs: Long = 0,
        /** Where a seek in progress is heading (the bar shows it at once; the player jumps when the remote pauses). */
        val pendingSeekMs: Long? = null,
        val error: String? = null,
        val audioWarning: String? = null,
        val ended: Boolean = false,
        val audio: List<TrackOption> = emptyList(),
        val text: List<TrackOption> = emptyList(),
        val textOff: Boolean = true,
        val speed: Float = 1f,
        val resizeMode: Int = 0,
        val skip: SkipSegment? = null,
        val hasNext: Boolean = false,
        val hasPrevious: Boolean = false,
        val nextCountdown: Int? = null,
        val alternatives: List<RankedStream> = emptyList(),
        val sourceLabel: String = "",
        /** Wall-clock time (ms) at which the sleep timer pauses the video, or null. */
        val sleepEndsAtMs: Long? = null,
        /** Subtitle lines on screen, already cleaned and delayed according to the settings. */
        val cues: List<androidx.media3.common.text.Cue> = emptyList(),
        val subtitleNote: String? = null,
        /** While TorBox prepares the link: what is going on. The player shows the film's logo meanwhile. */
        val preparing: Preparing? = null,
        /** «TorBox» or «Real-Debrid», for the texts about the torrent. */
        val debridName: String = "TorBox",
        val logoUrl: String? = null,
        /** True once the first picture is ready; until then the logo screen covers the player. */
        val started: Boolean = false,
        val askDownload: Boolean = false,
        val fileChoice: List<DebridFile>? = null,
        /** The start screen is up: the video waits (ready but paused) for «Guarda». */
        val intro: Boolean = false,
    )

    data class Preparing(val message: String, val fraction: Double?, val detail: String?)

    private val settings get() = engine.settings.value.value.playback
    private val trackSelector = DefaultTrackSelector(context).apply {
        parameters = buildUponParameters()
            .setPreferredAudioLanguage(languageSetting(settings.preferredAudioLanguage))
            .apply {
                val subtitleLanguage = languageSetting(settings.preferredSubtitleLanguage)
                if (subtitleLanguage == null) setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true) else setPreferredTextLanguage(subtitleLanguage)
            }
            .setSelectUndeterminedTextLanguage(true)
            .build()
    }

    private val http: HttpDataSource.Factory = OkHttpDataSource.Factory(app.aether.core.net.AetherDns.client()).setUserAgent("Aether-AndroidTV/1.0").apply {
        if (request.headers.isNotEmpty()) setDefaultRequestProperties(request.headers)
    }

    private val gainProcessor = GainAudioProcessor().also { it.setGainDb(settings.audioGainDb) }

    // The volume boost works on decoded audio, so with a boost set the device is not allowed to pass Dolby/DTS through untouched.
    private val renderers = object : DefaultRenderersFactory(context) {
        override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioTrackPlaybackParams: Boolean): androidx.media3.exoplayer.audio.AudioSink =
            androidx.media3.exoplayer.audio.DefaultAudioSink.Builder(context)
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                .setAudioProcessors(arrayOf(gainProcessor))
                .apply { if (settings.audioGainDb > 0) setAudioCapabilities(androidx.media3.exoplayer.audio.AudioCapabilities.DEFAULT_AUDIO_CAPABILITIES) }
                .build()
    }.also { it.setEnableDecoderFallback(true) }

    val player: ExoPlayer = ExoPlayer.Builder(context, renderers)
        .setTrackSelector(trackSelector)
        .setMediaSourceFactory(DefaultMediaSourceFactory(http))
        .setLoadControl(DefaultLoadControl.Builder().setBufferDurationsMs(30_000, 90_000, 2_500, 5_000).build())
        .setHandleAudioBecomingNoisy(true)
        .setAudioAttributes(androidx.media3.common.AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
        .build()

    private var current = request
    private var skipSegments: EpisodeSkipSegments = EpisodeSkipSegments.NONE
    private var addonSubtitles: List<AddonSubtitle> = emptyList()
    private var selectedAddonSubtitle: AddonSubtitle? = null
    private var tickJob: Job? = null
    private var seekJob: Job? = null
    private var countdownJob: Job? = null
    private var savedAt = 0L
    private var gainNoteJob: Job? = null

    private fun applyAudioGain(gainDb: Int) {
        gainProcessor.setGainDb(gainDb)
        val passthroughKind = player.audioFormat?.sampleMimeType in setOf(MimeTypes.AUDIO_AC3, MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC, MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_TRUEHD)
        if (gainDb > 0 && passthroughKind && settings.audioGainDb != gainAtStart) {
            val note = "Per amplificare l'audio Dolby/DTS chiudi e riapri il video: il guadagno è già impostato."
            _state.update { it.copy(audioWarning = note) }
            gainNoteJob?.cancel()
            gainNoteJob = viewModelScope.launch { delay(5000); _state.update { s -> if (s.audioWarning == note) s.copy(audioWarning = null) else s } }
        }
    }

    private val gainAtStart = settings.audioGainDb

    private val _state = MutableStateFlow(
        UiState(
            title = request.meta.name,
            debridName = engine.debrid.service.title,
            subtitle = request.video?.let { listOfNotNull(it.episodeLabel, it.title.takeIf { t -> t.isNotBlank() }).joinToString(" · ") }?.takeIf { it.isNotEmpty() },
            hasNext = nextOf(request) != null,
            hasPrevious = previousOf(request) != null,
            alternatives = request.alternatives.filter { it.stream.source is StreamSource.Url },
            sourceLabel = request.stream.name.orEmpty(),
        ),
    )
    val state: StateFlow<UiState> get() = _state

    /** Asks the screen to leave the player and open the sources of the next episode. */
    private val _goNext = MutableSharedFlow<StreamRequest>(extraBufferCapacity = 1)
    val goNext: SharedFlow<StreamRequest> get() = _goNext

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            _state.update { it.copy(buffering = playbackState == Player.STATE_BUFFERING, ended = playbackState == Player.STATE_ENDED, started = it.started || playbackState == Player.STATE_READY, durationMs = player.duration.coerceAtLeast(0)) }
            if (playbackState == Player.STATE_ENDED) onEnded()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            _state.update { it.copy(isPlaying = isPlaying) }
            if (!isPlaying) saveProgress(force = true)
            scrobble(if (isPlaying) app.aether.core.trakt.TraktClient.ScrobbleAction.START else if (player.playbackState == Player.STATE_ENDED) app.aether.core.trakt.TraktClient.ScrobbleAction.STOP else app.aether.core.trakt.TraktClient.ScrobbleAction.PAUSE)
        }

        override fun onTracksChanged(tracks: Tracks) = publishTracks(tracks)


        override fun onCues(cueGroup: androidx.media3.common.text.CueGroup) = showCues(cueGroup.cues)

        override fun onPlayerError(error: PlaybackException) {
            _state.update { it.copy(error = describe(error), buffering = false) }
            saveProgress(force = true)
        }
    }

    init {
        player.addListener(listener)
        viewModelScope.launch { engine.settings.value.collect { current -> applyAudioGain(current.playback.audioGainDb) } }
        val wantsIntro = if (request.meta.type == "movie") settings.introMovies else settings.introSeries
        _state.update { it.copy(intro = wantsIntro) }
        player.playWhenReady = !wantsIntro
        if (request.pending == null) load(request, startAt = startPosition(request)) else resolvePending(allowDownload = false)
        if (settings.showTitleLogos) viewModelScope.launch { _state.update { it.copy(logoUrl = engine.metadata.titleLogo(request.meta)) } }
        if (settings.defaultSleepTimerMinutes > 0) setSleepTimer(settings.defaultSleepTimerMinutes)
        tickJob = viewModelScope.launch {
            while (isActive) {
                val position = player.currentPosition.coerceAtLeast(0)
                val active = skipSegments.active(position / 1000.0, player.duration.takeIf { it > 0 }?.let { it / 1000.0 })
                _state.update { it.copy(positionMs = position, bufferedMs = player.bufferedPosition.coerceAtLeast(0), durationMs = player.duration.coerceAtLeast(0), skip = if (settings.skipSegmentsEnabled) active else null) }
                if (player.isPlaying) saveProgress(force = false)
                delay(400)
            }
        }
        viewModelScope.launch { fetchExtras(request) }
    }

    private fun languageSetting(value: String): String? = when (value) {
        "off" -> null
        "system" -> java.util.Locale.getDefault().language
        else -> value
    }

    private fun startPosition(r: PlaybackRequest): Double? {
        r.startPositionSeconds?.let { return it }
        if (!settings.autoResume) return null
        return engine.library.resumePosition(r.meta.id, r.video?.id ?: r.meta.id)?.let { maxOf(0.0, it - settings.resumeRewindSeconds) }
    }

    private fun load(r: PlaybackRequest, startAt: Double?) {
        current = r
        val builder = MediaItem.Builder().setUri(Uri.parse(r.url)).setMediaId(r.stream.id)
        player.setMediaItem(builder.build(), ((startAt ?: 0.0) * 1000).toLong())
        player.prepare()
        player.playWhenReady = !_state.value.intro
        _state.update { it.copy(error = null, ended = false, buffering = true, sourceLabel = r.stream.name.orEmpty()) }
    }

    /** Subtitles from the addons and the skip data of the episode, fetched while the video starts. */
    private suspend fun fetchExtras(r: PlaybackRequest) {
        val videoId = r.video?.id ?: r.meta.id
        try {
            val imdbVideoId = imdbVideoId(r)
            // Each subtitle gets its own id in the list: addons often number theirs from 1, and two addons would clash.
            addonSubtitles = engine.subtitlesFor(r.meta.type, videoId, imdbVideoId, r.stream, java.util.Locale.getDefault().language)
                .mapIndexed { i, sub -> sub.copy(id = "$i") }
            engine.log.info("player", "sottotitoli trovati: ${addonSubtitles.size} (${addonSubtitles.groupBy { it.addonName }.map { "${it.key}: ${it.value.size}" }.joinToString()})")
            publishTracks(player.currentTracks)
            // The viewer's language is applied by itself when the file has no subtitle track in it.
            val wanted = languageSetting(settings.preferredSubtitleLanguage)
            if (wanted != null && selectedAddonSubtitle == null && player.currentTracks.groups.none { it.type == C.TRACK_TYPE_TEXT && Languages.matches(it.getTrackFormat(0).language, wanted) }) {
                addonSubtitles.firstOrNull { Languages.matches(it.lang, wanted) }?.let { chooseAddonSubtitle(it) }
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            engine.log.error("player", "ricerca dei sottotitoli non riuscita", error)
        }
        if (settings.skipSegmentsEnabled && r.video?.isEpisode == true) {
            val imdb = r.meta.imdbId ?: r.meta.externalIds.imdb
            val video = r.video
            if (imdb != null && video?.season != null && video.episode != null) {
                skipSegments = engine.introDb.segments(imdb, video.season!!, video.episode!!) ?: EpisodeSkipSegments.NONE
            }
        }
    }

    // MARK: Tracks

    private fun publishTracks(tracks: Tracks) {
        val audio = ArrayList<TrackOption>()
        val text = ArrayList<TrackOption>()
        tracks.groups.forEachIndexed { groupIndex, group ->
            for (trackIndex in 0 until group.length) {
                val format = group.getTrackFormat(trackIndex)
                val id = "$groupIndex:$trackIndex"
                when (group.type) {
                    C.TRACK_TYPE_AUDIO -> audio.add(
                        TrackOption(
                            id,
                            (format.label ?: format.language?.let { Languages.displayName(it) } ?: "Traccia ${audio.size + 1}"),
                            listOfNotNull(codecName(format.sampleMimeType), channelName(format.channelCount)).joinToString(" · ").ifEmpty { null },
                            group.isTrackSelected(trackIndex), group.isTrackSupported(trackIndex),
                        ),
                    )
                    C.TRACK_TYPE_TEXT -> text.add(
                        TrackOption(id, format.label ?: format.language?.let { Languages.displayName(it) } ?: "Sottotitoli ${text.size + 1}", "nel file", group.isTrackSelected(trackIndex) && selectedAddonSubtitle == null, group.isTrackSupported(trackIndex), lang = format.language),
                    )
                }
            }
        }
        for (sub in addonSubtitles) {
            val label = sub.label?.takeIf { it.isNotBlank() } ?: Languages.displayName(sub.lang)
            text.add(TrackOption("addon:${sub.id}", label, null, selected = selectedAddonSubtitle?.id == sub.id, fromAddon = true, lang = sub.lang, addonName = sub.addonName ?: "Addon"))
        }
        val anySupportedAudio = audio.any { it.supported }
        _state.update {
            it.copy(
                audio = audio, text = text, textOff = text.none { o -> o.selected },
                audioWarning = if (audio.isNotEmpty() && !anySupportedAudio) "Questa TV non riesce a decodificare l'audio di questa sorgente (per esempio DTS): scegline un'altra." else null,
            )
        }
    }

    private fun codecName(mime: String?): String? = when (mime) {
        MimeTypes.AUDIO_AC3 -> "Dolby Digital"
        MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "Dolby Digital+"
        MimeTypes.AUDIO_AAC -> "AAC"
        MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD -> "DTS"
        MimeTypes.AUDIO_TRUEHD -> "TrueHD"
        MimeTypes.AUDIO_OPUS -> "Opus"
        MimeTypes.AUDIO_FLAC -> "FLAC"
        MimeTypes.AUDIO_MPEG -> "MP3"
        else -> null
    }

    private fun channelName(channels: Int): String? = when (channels) { 1 -> "mono"; 2 -> "stereo"; 6 -> "5.1"; 8 -> "7.1"; else -> if (channels > 0) "$channels canali" else null }

    fun selectAudio(option: TrackOption) = selectTrack(C.TRACK_TYPE_AUDIO, option.id)

    fun selectText(option: TrackOption?) {
        if (option == null) {
            stopAddonSubtitle()
            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
            publishTracks(player.currentTracks)
            return
        }
        if (option.fromAddon) {
            addonSubtitles.firstOrNull { "addon:${it.id}" == option.id }?.let { chooseAddonSubtitle(it) }
        } else {
            stopAddonSubtitle()
            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).build()
            selectTrack(C.TRACK_TYPE_TEXT, option.id)
        }
    }

    private fun selectTrack(type: Int, id: String) {
        val (g, t) = id.split(':').map { it.toIntOrNull() ?: return }
        val group = player.currentTracks.groups.getOrNull(g) ?: return
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(type, false)
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, t))
            .build()
    }

    private var addonCues: List<app.aether.core.playback.TimedCue> = emptyList()
    private var addonCueJob: Job? = null

    private fun stopAddonSubtitle() {
        addonCueJob?.cancel()
        selectedAddonSubtitle = null
        addonCues = emptyList()
        _state.update { it.copy(cues = emptyList(), subtitleNote = null) }
    }

    /** A subtitle of an addon is downloaded and read by the app itself, so it can be shifted both later and earlier. */
    private fun chooseAddonSubtitle(sub: AddonSubtitle) {
        addonCueJob?.cancel()
        selectedAddonSubtitle = sub
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
        _state.update { it.copy(cues = emptyList(), subtitleNote = "Scarico i sottotitoli…") }
        publishTracks(player.currentTracks)
        addonCueJob = viewModelScope.launch {
            val cues = try {
                val response = engine.http.send(app.aether.core.net.HttpRequest(sub.url, timeoutSeconds = 15, maxBytes = 3 * 1024 * 1024))
                if (!response.isSuccess) null else app.aether.core.playback.SubtitleParser.parse(app.aether.core.playback.SubtitleParser.decode(response.body))
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                null
            }
            if (cues.isNullOrEmpty()) {
                engine.log.warn("player", "sottotitoli illeggibili da ${sub.addonName}: ${sub.url}")
                _state.update { it.copy(subtitleNote = "Impossibile leggere questi sottotitoli (formato non supportato o addon non raggiungibile): provane altri.") }
                return@launch
            }
            addonCues = cues
            _state.update { it.copy(subtitleNote = null) }
            var shown: List<String> = emptyList()
            while (isActive) {
                val strip = settings.stripHearingImpairedTags
                val active = app.aether.core.playback.SubtitleParser.active(cues, player.currentPosition, settings.subtitleDelayMillis)
                    .map { if (strip) app.aether.core.playback.SubtitleCleaner.strip(it.text) else it.text }.filter { it.isNotEmpty() }
                if (active != shown) {
                    shown = active
                    _state.update { it.copy(cues = active.map { text -> androidx.media3.common.text.Cue.Builder().setText(text).build() }) }
                }
                delay(100)
            }
        }
    }

    private fun imdbVideoId(r: PlaybackRequest): String? {
        val imdb = r.meta.imdbId ?: r.meta.externalIds.imdb ?: r.meta.id.substringBefore(':').takeIf { it.startsWith("tt") }
        val v = r.video
        return imdb?.let { if (v?.season != null && v.episode != null) "$it:${v.season}:${v.episode}" else it }
    }

    /** The OpenSubtitles.org catalogue asked on purpose, in a language the viewer picks: what it finds joins the list. */
    fun searchCatalogue(language: String, onDone: () -> Unit) {
        val r = current
        val id = r?.let { imdbVideoId(it) }
        if (id == null) { _state.update { it.copy(subtitleNote = "Per questo titolo manca l'identificativo IMDb: OpenSubtitles.org non si può interrogare.") }; return }
        _state.update { it.copy(subtitleNote = "Cerco su OpenSubtitles.org…") }
        viewModelScope.launch {
            val found = app.aether.core.playback.OpenSubtitlesCatalog.search(engine.http, id, listOf(language), limitPerLanguage = 30)
            val known = addonSubtitles.map { it.url }.toSet()
            val fresh = found.filter { it.url !in known }
            val base = addonSubtitles.size
            addonSubtitles = addonSubtitles + fresh.mapIndexed { i, sub -> sub.copy(id = "${base + i}") }
            engine.log.info("player", "OpenSubtitles.org ($language): ${found.size} trovati")
            _state.update { it.copy(subtitleNote = if (found.isEmpty()) "Nessun sottotitolo in ${Languages.displayName(language)} su OpenSubtitles.org." else null) }
            publishTracks(player.currentTracks)
            if (found.isNotEmpty()) onDone()
        }
    }

    /** «Guarda» on the start screen. */
    fun watchFromIntro() {
        _state.update { it.copy(intro = false) }
        player.play()
    }

    /** What is playing now (the next episode changes it). */
    val meta: MetaItem get() = current?.meta ?: request.meta
    val video: app.aether.core.model.Video? get() = current?.video ?: request.video

    /** Cast and crew for the pause screen and the credits, loaded once in the background. */
    private val _rich = kotlinx.coroutines.flow.MutableStateFlow<app.aether.core.metadata.RichDetails?>(null)
    val rich: kotlinx.coroutines.flow.StateFlow<app.aether.core.metadata.RichDetails?> get() = _rich
    private var richAsked = false
    fun loadRich() {
        if (richAsked) return
        richAsked = true
        viewModelScope.launch { _rich.value = engine.metadata.rich(meta) }
    }

    /** Embedded tracks cannot be anticipated, only delayed; addon subtitles can do both. */
    val canAnticipate: Boolean get() = selectedAddonSubtitle != null

    // MARK: Transport

    fun togglePlay() { if (player.isPlaying) player.pause() else { if (player.playbackState == Player.STATE_ENDED) player.seekTo(0); player.play() } }

    /** Adds to a seek in progress: many presses in a row become one jump, committed when the remote pauses. */
    fun seekBy(deltaMs: Long) {
        val base = _state.value.pendingSeekMs ?: player.currentPosition
        val target = app.aether.core.playback.SeekSteps.target(base, deltaMs, player.duration)
        _state.update { it.copy(pendingSeekMs = target) }
        seekJob?.cancel()
        seekJob = viewModelScope.launch {
            delay(450)
            commitSeek()
        }
    }

    fun stepFor(repeatCount: Int, baseSeconds: Int): Int = app.aether.core.playback.SeekSteps.stepSeconds(repeatCount, baseSeconds)

    fun seekTo(ms: Long) {
        _state.update { it.copy(pendingSeekMs = ms.coerceAtLeast(0)) }
        seekJob?.cancel()
        seekJob = viewModelScope.launch { delay(250); commitSeek() }
    }

    private fun commitSeek() {
        val target = _state.value.pendingSeekMs ?: return
        player.seekTo(target)
        _state.update { it.copy(pendingSeekMs = null, positionMs = target, ended = false) }
    }

    fun skipSegment() {
        val segment = _state.value.skip ?: return
        player.seekTo((segment.end * 1000).toLong())
    }

    private var sleepJob: Job? = null
    private var cueJob: Job? = null

    /** Strips hearing-impaired notes and applies the subtitle delay (a delay can only postpone, never anticipate). */
    private fun showCues(raw: List<androidx.media3.common.text.Cue>) {
        if (selectedAddonSubtitle != null) return
        val strip = settings.stripHearingImpairedTags
        val cues = raw.mapNotNull { cue ->
            val text = cue.text
            if (!strip || text == null) cue else {
                val cleaned = app.aether.core.playback.SubtitleCleaner.strip(text.toString())
                if (cleaned.isEmpty()) null else cue.buildUpon().setText(cleaned).build()
            }
        }
        cueJob?.cancel()
        val delayMs = settings.subtitleDelayMillis
        if (delayMs <= 0 || cues.isEmpty() && raw.isEmpty()) { _state.update { it.copy(cues = cues) }; return }
        cueJob = viewModelScope.launch { delay(delayMs); _state.update { it.copy(cues = cues) } }
    }

    /** Pauses the video after [minutes] (0 turns the timer off). */
    fun setSleepTimer(minutes: Int) {
        sleepJob?.cancel()
        if (minutes <= 0) { _state.update { it.copy(sleepEndsAtMs = null) }; return }
        val endsAt = System.currentTimeMillis() + minutes * 60_000L
        _state.update { it.copy(sleepEndsAtMs = endsAt) }
        sleepJob = viewModelScope.launch {
            delay(minutes * 60_000L)
            player.pause()
            saveProgress(force = true)
            _state.update { it.copy(sleepEndsAtMs = null) }
        }
    }

    fun setSpeed(speed: Float) {
        player.playbackParameters = PlaybackParameters(speed)
        _state.update { it.copy(speed = speed) }
    }

    fun cycleResize(): Int {
        val next = when (_state.value.resizeMode) { 0 -> 4; 4 -> 3; else -> 0 }  // fit, zoom, fill
        _state.update { it.copy(resizeMode = next) }
        return next
    }

    // MARK: Errors and alternatives

    private var resolveJob: Job? = null
    private var fileReply: kotlinx.coroutines.CompletableDeferred<DebridFile?>? = null

    /** Asks TorBox for the link while the player is already open. */
    private fun resolvePending(allowDownload: Boolean) {
        val p = request.pending ?: return
        resolveJob?.cancel()
        _state.update { it.copy(preparing = Preparing("Controllo ${engine.debrid.service.title}…", null, null), error = null, askDownload = false) }
        resolveJob = viewModelScope.launch {
            try {
                val link = engine.debrid.resolve(
                    app.aether.core.debrid.DebridRequest(p.infoHash, p.trackers, p.fileIndex, p.filename, p.stremioId),
                    if (allowDownload) app.aether.core.debrid.DebridResolver.Mode.AllowDownload else app.aether.core.debrid.DebridResolver.Mode.CachedOnly,
                    onProgress = { pr -> _state.update { it.copy(preparing = Preparing(pr.message, pr.fraction, pr.detail)) } },
                    chooseFile = { candidates ->
                        val reply = kotlinx.coroutines.CompletableDeferred<DebridFile?>()
                        fileReply = reply
                        _state.update { it.copy(fileChoice = candidates) }
                        reply.await()
                    },
                )
                _state.update { it.copy(preparing = null) }
                load(request.copy(url = link, pending = null), startAt = startPosition(request))
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                _state.update { it.copy(preparing = null) }
                val debrid = error as? app.aether.core.debrid.DebridError
                if (debrid is app.aether.core.debrid.DebridError.NotCached || debrid is app.aether.core.debrid.DebridError.RealDebridNotInAccount) _state.update { it.copy(askDownload = true) }
                else _state.update { it.copy(error = debrid?.message ?: app.aether.core.net.AddonError.from(error).message) }
            }
        }
    }

    fun confirmDownload() = resolvePending(allowDownload = true)
    fun declineDownload() = _state.update { it.copy(askDownload = false, error = "Il torrent non è pronto su ${engine.debrid.service.title}: scegli un'altra sorgente.") }
    fun chooseFile(file: DebridFile?) { _state.update { it.copy(fileChoice = null) }; fileReply?.complete(file); fileReply = null }

    fun retry() {
        if (current.pending != null) { resolvePending(allowDownload = false); return }
        val position = player.currentPosition
        _state.update { it.copy(error = null, buffering = true) }
        player.setMediaItem(player.currentMediaItem ?: return, position)
        player.prepare()
        player.play()
    }

    fun playAlternative(option: RankedStream) {
        val url = option.stream.directUrl?.trim() ?: return
        saveProgress(force = true)
        val position = player.currentPosition / 1000.0
        val rest = _state.value.alternatives.filter { it.id != option.id }
        load(current.copy(stream = option.stream, url = url, headers = option.stream.behaviorHints.proxyRequestHeaders), startAt = position.takeIf { it > 5 })
        _state.update { it.copy(alternatives = rest) }
    }

    private fun describe(error: PlaybackException): String {
        val cause = error.cause
        if (cause is HttpDataSource.InvalidResponseCodeException) {
            return when (cause.responseCode) {
                401, 403 -> "Il server ha rifiutato l'accesso al video (errore ${cause.responseCode}): il link potrebbe essere scaduto."
                404, 410 -> "Il video non c'è più su questo server (errore ${cause.responseCode})."
                in 500..599 -> "Il server del video ha un problema (errore ${cause.responseCode}). Riprova più tardi."
                else -> "Il server ha risposto con l'errore ${cause.responseCode}."
            }
        }
        return when (error.errorCode) {
            PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED, PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT ->
                "La connessione è caduta o il server non risponde. Controlla la rete e riprova."
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED, PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
            PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED, PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED ->
                "Il file non è in un formato che questa TV sa leggere."
            PlaybackException.ERROR_CODE_DECODER_INIT_FAILED, PlaybackException.ERROR_CODE_DECODING_FAILED,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES, PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ->
                "La TV non riesce a decodificare questo video (codec o risoluzione non supportati). Prova una sorgente diversa."
            else -> "Riproduzione non riuscita (${error.errorCodeName})."
        }
    }

    // MARK: Episodes

    private fun nextOf(r: PlaybackRequest): Video? = r.video?.let { NextEpisodeResolver.next(it.id, r.meta) }
    private fun previousOf(r: PlaybackRequest): Video? = r.video?.let { NextEpisodeResolver.previous(it.id, r.meta) }

    fun playNext() { nextOf(current)?.let { goTo(it) } }
    fun playPrevious() { previousOf(current)?.let { goTo(it) } }

    private fun goTo(video: Video) {
        saveProgress(force = true)
        player.pause()
        _goNext.tryEmit(StreamRequest(current.meta, video, null, autoSelect = true))
    }

    private fun onEnded() {
        saveProgress(force = true)
        val next = nextOf(current) ?: return
        if (!settings.autoplayNextEpisode) return
        countdownJob?.cancel()
        countdownJob = viewModelScope.launch {
            for (second in settings.nextEpisodeCountdownSeconds downTo 1) {
                _state.update { it.copy(nextCountdown = second) }
                delay(1000)
            }
            _state.update { it.copy(nextCountdown = null) }
            goTo(next)
        }
    }

    fun cancelCountdown() { countdownJob?.cancel(); _state.update { it.copy(nextCountdown = null) } }
    fun playNextNow() { countdownJob?.cancel(); _state.update { it.copy(nextCountdown = null) }; playNext() }

    // MARK: Progress

    private fun saveProgress(force: Boolean) {
        val now = System.currentTimeMillis()
        if (!force && now - savedAt < 10_000) return
        val duration = player.duration
        val position = player.currentPosition
        if (duration <= 0 || position < 0) return
        savedAt = now
        val finished = engine.library.recordProgress(current.meta, current.video, position / 1000.0, duration / 1000.0)
        // A title watched to the end goes into the diary by itself (the viewer can rate it later).
        if (finished) {
            val m = current.meta
            val v = current.video
            engine.library.saveDiary(
                app.aether.core.library.DiaryEntry(
                    metaId = m.id, type = m.type, name = m.name, poster = m.poster, year = m.releaseInfo, genres = m.genres,
                    runtimeMinutes = (duration / 60_000).toInt().takeIf { it > 0 }, people = (m.directors + m.cast.take(4)),
                    episodeLabel = v?.episodeLabel?.let { label -> listOfNotNull(label, v.title.takeIf { it.isNotBlank() }).joinToString(" · ") },
                    publicRating = m.imdbRating?.replace(',', '.')?.toDoubleOrNull(),
                ),
            )
            engine.log.info("diario", "visto fino alla fine: ${m.name}")
        }
    }

    /** Tells Trakt (when linked and enabled) what the player is doing. */
    private fun scrobble(action: app.aether.core.trakt.TraktClient.ScrobbleAction) {
        val duration = player.duration
        if (duration <= 0) return
        engine.trakt.scrobble(action, current.meta, current.video, player.currentPosition / 1000.0, duration / 1000.0)
    }

    /** Called when the screen is left: the point reached is saved and the player stopped. */
    fun onLeave() { saveProgress(force = true); scrobble(app.aether.core.trakt.TraktClient.ScrobbleAction.STOP); player.pause() }

    override fun onCleared() {
        saveProgress(force = true)
        tickJob?.cancel(); seekJob?.cancel(); countdownJob?.cancel(); sleepJob?.cancel(); cueJob?.cancel(); addonCueJob?.cancel(); resolveJob?.cancel()
        player.removeListener(listener)
        player.release()
        Session.playback = null
    }
}
