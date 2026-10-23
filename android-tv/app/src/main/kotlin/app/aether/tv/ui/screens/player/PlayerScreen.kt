package app.aether.tv.ui.screens.player

import android.graphics.Color as AndroidColor
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import app.aether.tv.Session
import app.aether.tv.StreamRequest
import app.aether.tv.aether
import app.aether.tv.ui.components.ChoiceDialog
import app.aether.tv.ui.components.EmptyState
import app.aether.tv.ui.components.FocusSurface
import app.aether.tv.ui.components.RequestFocusOnce
import app.aether.tv.ui.components.TvButton
import app.aether.tv.ui.components.formatDuration
import app.aether.tv.ui.theme.AetherColors
import app.aether.tv.ui.theme.LocalAccent
import kotlinx.coroutines.delay

private enum class Panel { NONE, AUDIO, TEXT, SPEED, SOURCES }

/**
 * The player. The remote works the way people expect from a TV: OK pauses, Left/Right jump (and keep the bar on screen while the
 * button is held or tapped again), Up/Down bring up the controls, Back closes a panel, then the controls, then the player.
 */
@Composable
fun PlayerScreen(onExit: () -> Unit, onNextEpisode: (StreamRequest) -> Unit, modifier: Modifier = Modifier) {
    val request = Session.playback
    if (request == null) {
        EmptyState("Nessun video da riprodurre", "Torna alle sorgenti e scegline una.", modifier.fillMaxSize()) { TvButton("Indietro", onExit, primary = true) }
        return
    }
    val context = LocalContext.current
    val engine = context.aether
    val vm: PlayerViewModel = viewModel(key = "player/${request.stream.id}/${request.video?.id}") { PlayerViewModel(engine, context.applicationContext, request) }
    val state by vm.state.collectAsStateWithLifecycle()
    val settings by engine.settings.value.collectAsStateWithLifecycle()
    val lifecycleOwner = LocalLifecycleOwner.current

    var controlsVisible by remember { mutableStateOf(true) }
    var lastInteraction by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var panel by remember { mutableStateOf(Panel.NONE) }
    val root = remember { FocusRequester() }
    val playPause = remember { FocusRequester() }
    val seekBarRequester = remember { FocusRequester() }
    var startOnSeekBar by remember { mutableStateOf(false) }
    val skipRequester = remember { FocusRequester() }

    fun exit() { vm.onLeave(); onExit() }

    LaunchedEffect(Unit) { vm.goNext.collect { onNextEpisode(it) } }
    // A film (or the last episode) that has ended closes the player after a moment, back to where it was chosen.
    LaunchedEffect(state.ended, state.hasNext) {
        if (state.ended && !state.hasNext) { delay(1800); exit() }
    }
    LaunchedEffect(Unit) { runCatching { root.requestFocus() } }

    // Pause when the TV goes to the background and keep the point reached.
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) vm.onLeave() }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // The controls leave a few seconds after the last press, never while something is being chosen.
    LaunchedEffect(controlsVisible, lastInteraction, state.isPlaying, panel, state.error) {
        if (!controlsVisible || !state.isPlaying || panel != Panel.NONE || state.error != null) return@LaunchedEffect
        delay(settings.playback.controlsAutoHideSeconds * 1000L)
        controlsVisible = false
        runCatching { root.requestFocus() }
    }

    fun touch() { lastInteraction = System.currentTimeMillis(); controlsVisible = true }

    BackHandler {
        when {
            panel != Panel.NONE -> { panel = Panel.NONE; touch(); runCatching { playPause.requestFocus() } }
            controlsVisible && state.error == null -> { controlsVisible = false; runCatching { root.requestFocus() } }
            else -> exit()
        }
    }

    Box(
        modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(root)
            .focusable()
            .onPreviewKeyEvent { event ->
                if (event.type == KeyEventType.KeyDown) lastInteraction = System.currentTimeMillis()
                if (panel != Panel.NONE || state.error != null) return@onPreviewKeyEvent false
                // With the controls hidden the remote is a remote: every key does something useful without asking for the controls first.
                if (!controlsVisible) {
                    if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent event.key in handledWhenHidden
                    val repeat = event.nativeKeyEvent.repeatCount
                    val step = vm.stepFor(repeat, settings.playback.skipForwardSeconds)
                    when (event.key) {
                        Key.DirectionCenter, Key.Enter, Key.NumPadEnter, Key.MediaPlayPause -> { vm.togglePlay(); startOnSeekBar = false; touch(); true }
                        Key.MediaPlay -> { if (!state.isPlaying) vm.togglePlay(); startOnSeekBar = false; touch(); true }
                        Key.MediaPause -> { if (state.isPlaying) vm.togglePlay(); startOnSeekBar = false; touch(); true }
                        // The bar comes up and holds the focus, so the next presses keep seeking instead of walking over the buttons.
                        Key.DirectionRight, Key.MediaFastForward, Key.MediaStepForward -> { vm.seekBy(step * 1000L); startOnSeekBar = true; touch(); true }
                        Key.DirectionLeft, Key.MediaRewind, Key.MediaStepBackward -> { vm.seekBy(-step * 1000L); startOnSeekBar = true; touch(); true }
                        Key.DirectionUp, Key.DirectionDown -> { startOnSeekBar = false; touch(); true }
                        Key.MediaNext -> { vm.playNext(); true }
                        Key.MediaPrevious -> { vm.playPrevious(); true }
                        else -> false
                    }
                } else false
            },
    ) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                PlayerView(ctx).apply {
                    useController = false
                    isFocusable = false
                    isFocusableInTouchMode = false
                    keepScreenOn = true
                    setShutterBackgroundColor(AndroidColor.BLACK)
                    player = vm.player
                }
            },
            update = { view ->
                view.resizeMode = when (state.resizeMode) { 4 -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM; 3 -> AspectRatioFrameLayout.RESIZE_MODE_FILL; else -> AspectRatioFrameLayout.RESIZE_MODE_FIT }
                val style = settings.playback.subtitleStyle
                view.subtitleView?.apply {
                    setStyle(
                        CaptionStyleCompat(
                            style.textColor.toInt(),
                            AndroidColor.argb((style.backgroundOpacityPercent * 255 / 100).coerceIn(0, 255), 0, 0, 0),
                            AndroidColor.TRANSPARENT,
                            if (style.outline) CaptionStyleCompat.EDGE_TYPE_OUTLINE else CaptionStyleCompat.EDGE_TYPE_NONE,
                            AndroidColor.BLACK,
                            if (style.bold) android.graphics.Typeface.DEFAULT_BOLD else android.graphics.Typeface.DEFAULT,
                        ),
                    )
                    setFractionalTextSize(0.0533f * style.sizePercent / 100f)
                    setBottomPaddingFraction((style.bottomOffsetPercent / 100f).coerceIn(0f, 0.4f))
                }
            },
        )

        if (state.buffering && state.error == null) CircularProgressIndicator(Modifier.align(Alignment.Center).size(56.dp), color = LocalAccent.current, strokeWidth = 5.dp)

        // Seek in progress with the controls away: just the time and how far it jumps.
        state.pendingSeekMs?.let { target ->
            if (!controlsVisible) Text(formatDuration(target / 1000.0), Modifier.align(Alignment.Center).clip(RoundedCornerShape(10.dp)).background(Color(0xB00B0A12)).padding(horizontal = 18.dp, vertical = 8.dp), style = MaterialTheme.typography.headlineMedium, color = Color.White)
        }

        AnimatedVisibility(visible = controlsVisible && state.error == null, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.fillMaxSize()) {
            Controls(
                state = state,
                skipSeconds = settings.playback.skipForwardSeconds,
                backSeconds = settings.playback.skipBackSeconds,
                onTouch = ::touch,
                onPlayPause = { vm.togglePlay(); touch() },
                onSeekBy = { vm.seekBy(it); touch() },
                onSeekTo = { vm.seekTo(it); touch() },
                onNext = vm::playNext,
                onPrevious = vm::playPrevious,
                openPanel = { panel = it; touch() },
                onResize = { vm.cycleResize(); touch() },
                playPause = playPause,
                seekBarRequester = seekBarRequester,
                startOnSeekBar = startOnSeekBar,
                onToggle = { vm.togglePlay(); touch() },
                stepFor = vm::stepFor,
            )
        }

        // "Skip intro" is offered whatever the controls do.
        state.skip?.let { segment ->
            Box(Modifier.align(Alignment.BottomEnd).padding(end = 48.dp, bottom = if (controlsVisible) 190.dp else 56.dp)) {
                TvButton(if (segment.kind == app.aether.core.segments.SkipSegment.Kind.INTRO) "Salta intro" else "Salta riassunto", { vm.skipSegment() }, primary = true, focusRequester = skipRequester, testTag = "player.skip")
            }
        }

        state.audioWarning?.let {
            Text(it, Modifier.align(Alignment.TopCenter).padding(top = 24.dp).clip(RoundedCornerShape(10.dp)).background(Color(0xD00B0A12)).padding(horizontal = 18.dp, vertical = 10.dp), style = MaterialTheme.typography.bodyMedium, color = AetherColors.Warning)
        }

        state.nextCountdown?.let { seconds ->
            Column(Modifier.align(Alignment.BottomEnd).padding(48.dp).clip(RoundedCornerShape(16.dp)).background(Color(0xE60B0A12)).padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val ok = remember { FocusRequester() }
                Text("Prossimo episodio tra $seconds s", style = MaterialTheme.typography.titleLarge, color = Color.White)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvButton("Riproduci ora", vm::playNextNow, primary = true, focusRequester = ok, testTag = "player.nextNow")
                    TvButton("Annulla", vm::cancelCountdown)
                }
                RequestFocusOnce(ok)
            }
        }

        state.error?.let { message ->
            val retry = remember { FocusRequester() }
            Column(Modifier.align(Alignment.Center).width(620.dp).clip(RoundedCornerShape(20.dp)).background(Color(0xF0100E1A)).padding(28.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("Non riesco a riprodurre il video", style = MaterialTheme.typography.headlineMedium, color = Color.White)
                Text(message, style = MaterialTheme.typography.bodyLarge, color = AetherColors.OnSurfaceMuted)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TvButton("Riprova", vm::retry, primary = true, focusRequester = retry, testTag = "player.retry")
                    if (state.alternatives.isNotEmpty()) TvButton("Altra sorgente", { panel = Panel.SOURCES }, testTag = "player.alternative")
                    TvButton("Esci", ::exit)
                }
                RequestFocusOnce(retry, message)
            }
        }
    }

    when (panel) {
        Panel.AUDIO -> ChoiceDialog(
            "Audio", state.audio.map { it.id to (it.label + (it.detail?.let { d -> " · $d" } ?: "") + if (!it.supported) " (non supportato)" else "") },
            state.audio.firstOrNull { it.selected }?.id, { id -> state.audio.firstOrNull { it.id == id }?.let(vm::selectAudio) }, { panel = Panel.NONE; touch() },
        )
        Panel.TEXT -> ChoiceDialog(
            "Sottotitoli",
            listOf("off" to "Nessuno") + state.text.map { it.id to (it.label + (it.detail?.let { d -> " · $d" } ?: "")) },
            if (state.textOff) "off" else state.text.firstOrNull { it.selected }?.id,
            { id -> if (id == "off") vm.selectText(null) else vm.selectText(state.text.firstOrNull { it.id == id }) }, { panel = Panel.NONE; touch() },
        )
        Panel.SPEED -> ChoiceDialog(
            "Velocità", listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f).map { it to if (it == 1f) "Normale" else "${it}×" }, state.speed, vm::setSpeed, { panel = Panel.NONE; touch() },
        )
        Panel.SOURCES -> ChoiceDialog(
            "Altra sorgente",
            state.alternatives.map { it.id to ((it.stream.name ?: "Sorgente") + (it.stream.addonName?.let { a -> " · $a" } ?: "") + (it.info.badges.firstOrNull()?.let { b -> " · $b" } ?: "")) },
            null, { id -> state.alternatives.firstOrNull { it.id == id }?.let(vm::playAlternative) }, { panel = Panel.NONE; touch() },
        )
        Panel.NONE -> Unit
    }
}

private val handledWhenHidden = setOf(
    Key.DirectionCenter, Key.Enter, Key.NumPadEnter, Key.MediaPlayPause, Key.MediaPlay, Key.MediaPause, Key.DirectionRight, Key.DirectionLeft,
    Key.MediaFastForward, Key.MediaRewind, Key.MediaStepForward, Key.MediaStepBackward, Key.DirectionUp, Key.DirectionDown, Key.MediaNext, Key.MediaPrevious,
)

@Composable
private fun Controls(
    state: PlayerViewModel.UiState,
    skipSeconds: Int,
    backSeconds: Int,
    onTouch: () -> Unit,
    onPlayPause: () -> Unit,
    onSeekBy: (Long) -> Unit,
    onSeekTo: (Long) -> Unit,
    onNext: () -> Unit,
    onPrevious: () -> Unit,
    openPanel: (Panel) -> Unit,
    onResize: () -> Unit,
    playPause: FocusRequester,
    seekBarRequester: FocusRequester,
    startOnSeekBar: Boolean,
    onToggle: () -> Unit,
    stepFor: (Int, Int) -> Int,
) {
    val position = state.pendingSeekMs ?: state.positionMs
    LaunchedEffect(Unit) { delay(60); runCatching { (if (startOnSeekBar) seekBarRequester else playPause).requestFocus() } }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxWidth().height(150.dp).background(Brush.verticalGradient(listOf(Color(0xDD000000), Color.Transparent))))
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(260.dp).background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xF0000000)))))
        Column(Modifier.align(Alignment.TopStart).padding(start = 48.dp, top = 28.dp, end = 48.dp)) {
            Text(state.title, style = MaterialTheme.typography.headlineLarge, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
            state.subtitle?.let { Text(it, style = MaterialTheme.typography.titleMedium, color = AetherColors.OnSurfaceMuted, maxLines = 1) }
        }
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 48.dp, vertical = 28.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(formatDuration(position / 1000.0), style = MaterialTheme.typography.labelLarge, color = Color.White, modifier = Modifier.width(72.dp))
                SeekBar(position, state.durationMs, state.bufferedMs, onSeekBy, onToggle, skipSeconds, stepFor, seekBarRequester, Modifier.weight(1f))
                Text(if (state.durationMs > 0) "-" + formatDuration((state.durationMs - position).coerceAtLeast(0) / 1000.0) else "--:--", style = MaterialTheme.typography.labelLarge, color = Color.White, modifier = Modifier.width(80.dp))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                if (state.hasPrevious) RoundControl(Icons.Filled.SkipPrevious, "Episodio precedente", onPrevious)
                RoundControl(Icons.Filled.FastRewind, "Indietro di $backSeconds secondi", { onSeekBy(-backSeconds * 1000L) })
                RoundControl(if (state.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (state.isPlaying) "Pausa" else "Riproduci", onPlayPause, requester = playPause, big = true, tag = "player.playPause")
                RoundControl(Icons.Filled.FastForward, "Avanti di $skipSeconds secondi", { onSeekBy(skipSeconds * 1000L) })
                if (state.hasNext) RoundControl(Icons.Filled.SkipNext, "Episodio successivo", onNext, tag = "player.next")
                Box(Modifier.width(24.dp))
                PanelButton(Icons.Filled.Audiotrack, "Audio", { openPanel(Panel.AUDIO) }, "player.audio")
                PanelButton(Icons.Filled.Subtitles, "Sottotitoli", { openPanel(Panel.TEXT) }, "player.subtitles")
                PanelButton(Icons.Filled.Speed, if (state.speed == 1f) "Velocità" else "${state.speed}×", { openPanel(Panel.SPEED) }, "player.speed")
                PanelButton(Icons.Filled.AspectRatio, when (state.resizeMode) { 4 -> "Riempi"; 3 -> "Allunga"; else -> "Adatta" }, onResize, "player.resize")
                if (state.alternatives.isNotEmpty()) PanelButton(Icons.Filled.SwapHoriz, "Sorgenti", { openPanel(Panel.SOURCES) }, "player.sources")
            }
        }
    }
}

@Composable
private fun RoundControl(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit, requester: FocusRequester? = null, big: Boolean = false, tag: String? = null) {
    val size = if (big) 62.dp else 50.dp
    FocusSurface(onClick, Modifier.size(size), shape = androidx.compose.foundation.shape.CircleShape, focusScale = 1.12f, containerColor = Color(0x66FFFFFF).copy(alpha = 0.16f), focusRequester = requester, testTag = tag) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Icon(icon, label, Modifier.size(size * 0.55f), tint = Color.White) }
    }
}

@Composable
private fun PanelButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit, tag: String) {
    FocusSurface(onClick, Modifier.height(46.dp), shape = RoundedCornerShape(23.dp), focusScale = 1.06f, containerColor = Color(0x66FFFFFF).copy(alpha = 0.16f), testTag = tag) {
        Row(Modifier.padding(horizontal = 16.dp).fillMaxHeight(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon, null, Modifier.size(22.dp), tint = Color.White)
            Text(label, style = MaterialTheme.typography.labelLarge, color = Color.White, maxLines = 1)
        }
    }
}

/** The progress bar. When the remote is on it, Left/Right move it (longer holds move it further) and OK pauses. */
@Composable
private fun SeekBar(
    positionMs: Long,
    durationMs: Long,
    bufferedMs: Long,
    onSeekBy: (Long) -> Unit,
    onToggle: () -> Unit,
    baseSeconds: Int,
    stepFor: (Int, Int) -> Int,
    requester: FocusRequester,
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }
    val accent = LocalAccent.current
    val fraction = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
    val buffered = if (durationMs > 0) (bufferedMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
    Box(
        modifier
            .height(28.dp)
            .focusRequester(requester)
            .onFocusChanged { focused = it.isFocused }
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                val step = stepFor(event.nativeKeyEvent.repeatCount, baseSeconds) * 1000L
                when (event.key) {
                    Key.DirectionRight -> { onSeekBy(step); true }
                    Key.DirectionLeft -> { onSeekBy(-step); true }
                    Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> { onToggle(); true }
                    else -> false
                }
            }
            .focusable(),
        contentAlignment = Alignment.CenterStart,
    ) {
        val barHeight = if (focused) 10.dp else 6.dp
        Box(Modifier.fillMaxWidth().height(barHeight).clip(RoundedCornerShape(5.dp)).background(Color(0x55FFFFFF)))
        Box(Modifier.fillMaxWidth(buffered).height(barHeight).clip(RoundedCornerShape(5.dp)).background(Color(0x77FFFFFF)))
        Box(Modifier.fillMaxWidth(fraction).height(barHeight).clip(RoundedCornerShape(5.dp)).background(accent))
        if (focused) Box(Modifier.fillMaxWidth(fraction), contentAlignment = Alignment.CenterEnd) {
            Box(Modifier.size(18.dp).clip(androidx.compose.foundation.shape.CircleShape).background(Color.White))
        }
    }
}
