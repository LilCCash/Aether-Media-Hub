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
data class TrackOption(val id: String, val label: String, val detail: String?, val selected: Boolean, val supported: Boolean = true, val fromAddon: Boolean = false)

/** The playback engine of the app (Media3 ExoPlayer) and everything around it: tracks, subtitles from the addons, progress, skip, next episode. */
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
    )

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

    private val http: HttpDataSource.Factory = OkHttpDataSource.Factory(OkHttpClient()).setUserAgent("Aether-AndroidTV/1.0").apply {
        if (request.headers.isNotEmpty()) setDefaultRequestProperties(request.headers)
    }

    val player: ExoPlayer = ExoPlayer.Builder(context, DefaultRenderersFactory(context).setEnableDecoderFallback(true))
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

    private val _state = MutableStateFlow(
        UiState(
            title = request.meta.name,
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
            _state.update { it.copy(buffering = playbackState == Player.STATE_BUFFERING, ended = playbackState == Player.STATE_ENDED, durationMs = player.duration.coerceAtLeast(0)) }
            if (playbackState == Player.STATE_ENDED) onEnded()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            _state.update { it.copy(isPlaying = isPlaying) }
            if (!isPlaying) saveProgress(force = true)
        }

        override fun onTracksChanged(tracks: Tracks) = publishTracks(tracks)

        override fun onPlayerError(error: PlaybackException) {
            _state.update { it.copy(error = describe(error), buffering = false) }
            saveProgress(force = true)
        }
    }

    init {
        player.addListener(listener)
        player.playWhenReady = true
        load(request, startAt = startPosition(request))
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
        selectedAddonSubtitle?.let { builder.setSubtitleConfigurations(listOf(subtitleConfiguration(it))) }
        player.setMediaItem(builder.build(), ((startAt ?: 0.0) * 1000).toLong())
        player.prepare()
        player.playWhenReady = true
        _state.update { it.copy(error = null, ended = false, buffering = true, sourceLabel = r.stream.name.orEmpty()) }
    }

    private fun subtitleConfiguration(sub: AddonSubtitle): MediaItem.SubtitleConfiguration {
        val path = sub.url.substringBefore('?').lowercase()
        val mime = when {
            path.endsWith(".vtt") -> MimeTypes.TEXT_VTT
            path.endsWith(".ass") || path.endsWith(".ssa") -> MimeTypes.TEXT_SSA
            path.endsWith(".ttml") || path.endsWith(".xml") -> MimeTypes.APPLICATION_TTML
            else -> MimeTypes.APPLICATION_SUBRIP
        }
        return MediaItem.SubtitleConfiguration.Builder(Uri.parse(sub.url)).setMimeType(mime).setLanguage(Languages.normalise(sub.lang))
            .setLabel(sub.label ?: Languages.displayName(sub.lang)).setSelectionFlags(C.SELECTION_FLAG_DEFAULT).build()
    }

    /** Subtitles from the addons and the skip data of the episode, fetched while the video starts. */
    private suspend fun fetchExtras(r: PlaybackRequest) {
        val videoId = r.video?.id ?: r.meta.id
        try {
            addonSubtitles = engine.addons.subtitles(r.meta.type, videoId, r.stream)
            publishTracks(player.currentTracks)
            // The viewer's language is applied by itself when the file has no subtitle track in it.
            val wanted = languageSetting(settings.preferredSubtitleLanguage)
            if (wanted != null && selectedAddonSubtitle == null && player.currentTracks.groups.none { it.type == C.TRACK_TYPE_TEXT && Languages.matches(it.getTrackFormat(0).language, wanted) }) {
                addonSubtitles.firstOrNull { Languages.matches(it.lang, wanted) }?.let { chooseAddonSubtitle(it) }
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
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
                        TrackOption(id, format.label ?: format.language?.let { Languages.displayName(it) } ?: "Sottotitoli ${text.size + 1}", "nel file", group.isTrackSelected(trackIndex), group.isTrackSupported(trackIndex)),
                    )
                }
            }
        }
        val embeddedSelected = text.any { it.selected }
        for (sub in addonSubtitles) {
            val label = sub.label?.takeIf { it.isNotBlank() } ?: Languages.displayName(sub.lang)
            text.add(TrackOption("addon:${sub.id}", label, sub.addonName?.let { "da $it" }, selected = selectedAddonSubtitle?.id == sub.id && embeddedSelected, fromAddon = true))
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
            selectedAddonSubtitle = null
            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
            publishTracks(player.currentTracks)
            return
        }
        if (option.fromAddon) {
            addonSubtitles.firstOrNull { "addon:${it.id}" == option.id }?.let { chooseAddonSubtitle(it) }
        } else {
            selectedAddonSubtitle = null
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

    /** A subtitle of an addon joins the video as an extra track: the item is set again at the same point. */
    private fun chooseAddonSubtitle(sub: AddonSubtitle) {
        selectedAddonSubtitle = sub
        val position = player.currentPosition
        val wasPlaying = player.playWhenReady
        val item = MediaItem.Builder().setUri(Uri.parse(current.url)).setMediaId(current.stream.id).setSubtitleConfigurations(listOf(subtitleConfiguration(sub))).build()
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).clearOverridesOfType(C.TRACK_TYPE_TEXT).build()
        player.setMediaItem(item, position)
        player.prepare()
        player.playWhenReady = wasPlaying
    }

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

    fun retry() {
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
        engine.library.recordProgress(current.meta, current.video, position / 1000.0, duration / 1000.0)
    }

    /** Called when the screen is left: the point reached is saved and the player stopped. */
    fun onLeave() { saveProgress(force = true); player.pause() }

    override fun onCleared() {
        saveProgress(force = true)
        tickJob?.cancel(); seekJob?.cancel(); countdownJob?.cancel()
        player.removeListener(listener)
        player.release()
        Session.playback = null
    }
}
