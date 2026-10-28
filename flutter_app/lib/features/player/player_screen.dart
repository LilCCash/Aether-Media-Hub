import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/orientation.dart';
import '../../app/providers.dart';
import '../../data/prefs_ext.dart';
import '../../core/segments/skip_segments.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../core/casting/upnp.dart';
import 'cast_sheet.dart';
import 'media_kit_engine.dart';
import 'playback_engine.dart';
import 'player_panels.dart';
import 'player_session.dart';

/// Picture in Picture exists only where the platform engine can really keep playing in a floating window: Android (the activity
/// enters PiP; the video keeps decoding). On iOS libmpv cannot feed AVPictureInPictureController, so no button is shown there.
const _pipChannel = MethodChannel('app.aether/pip');

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.args, this.engine});
  final PlayerArgs args;

  /// Tests (and the offline check) can inject an engine; normally a media_kit one is created.
  final PlaybackEngine? engine;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  late final PlaybackEngine _engine = widget.engine ?? MediaKitEngine();
  late final PlayerSession _session;
  Timer? _hideTimer;
  Timer? _nextTimer;
  bool _controls = true;
  bool _inPip = false;
  int _nextCountdown = 0;
  String? _seekHint;
  Timer? _hintTimer;
  double _dragSeekStartMs = 0;
  double? _dragSeekMs;
  EpisodeSkipSegments? _segments;
  double _speedBefore = 1;
  Timer? _sleepTimer;
  bool _downloadCleaned = false;
  double _brightness = 0.5;
  double _volume = 1.0;
  int _verticalKind = 0; // 1 brightness, 2 volume

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _keepAwake(true);
    final services = ref.read(servicesProvider);
    _session = PlayerSession(
      engine: _engine,
      args: widget.args,
      library: services.library,
      settings: ref.read(settingsProvider),
      subtitleLoader: services.subtitleLoader,
    );
    _session.addListener(_onSession);
    _session.start();
    _loadSegments();
    if (Platform.isAndroid) {
      _pipChannel
          .invokeMethod<void>('setAuto', {
            'on': ref.read(settingsProvider).autoPip,
          })
          .catchError((Object _) {});
    }
    final sleep = ref.read(settingsProvider).sleepTimerMin;
    if (sleep > 0) {
      _sleepTimer = Timer(Duration(minutes: sleep), () {
        if (!mounted) return;
        _engine.pause();
        _hint('Timer di spegnimento: in pausa');
        setState(() => _controls = true);
      });
    }
    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged' && mounted)
        setState(() => _inPip = call.arguments == true);
    });
    _scheduleHide();
  }

  /// IntroDB segments of this episode (needs an IMDb id and a series episode); nothing is shown when they are unknown.
  Future<void> _loadSegments() async {
    final a = widget.args;
    final imdb = a.metaId.split(':').first;
    if (!ref.read(settingsProvider).skipIntro ||
        !a.isEpisode ||
        !IntroDbClient.isValidImdb(imdb)) {
      return;
    }
    final found = await ref
        .read(servicesProvider)
        .skipSegments
        .segments(imdb, a.season!, a.episode!);
    if (mounted && found != null) setState(() => _segments = found);
  }

  /// Brightness control may be missing (tests, some devices): a failure must never reach the player.
  Future<void> _brightnessCall(
    Future<void> Function(ScreenBrightness) call,
  ) async {
    try {
      await call(ScreenBrightness());
    } on Object {
      // no brightness control here
    }
  }

  Future<void> _verticalStart(double x, double width) async {
    _verticalKind = x < width / 2 ? 1 : 2;
    if (_verticalKind == 1) {
      try {
        _brightness = await ScreenBrightness().application;
      } on Object {
        _brightness = 0.5;
      }
    }
  }

  void _verticalUpdate(double dy, double height) {
    final delta = -dy / (height * 0.7);
    if (_verticalKind == 1) {
      _brightness = (_brightness + delta).clamp(0.02, 1.0);
      _brightnessCall((b) => b.setApplicationScreenBrightness(_brightness));
      _hint('Luminosità ${(_brightness * 100).round()}%');
    } else if (_verticalKind == 2) {
      _volume = (_volume + delta).clamp(0.0, 1.0);
      _engine.setVolume(_volume);
      _hint('Volume ${(_volume * 100).round()}%');
    }
  }

  /// Keeps the screen on while watching; a device without the feature must not break playback.
  Future<void> _keepAwake(bool on) async {
    try {
      await (on ? WakelockPlus.enable() : WakelockPlus.disable());
    } on Object {
      // not available on this platform / in tests
    }
  }

  /// Only http(s) links can be handed to a television; a downloaded file or an engine-only source cannot.
  bool get _canCast {
    final src = widget.args.source;
    return UpnpDiscovery.supported &&
        !src.isLocalFile &&
        (Uri.tryParse(src.uri)?.hasScheme ?? false) &&
        Uri.parse(src.uri).scheme.startsWith('http');
  }

  Future<void> _openCast() async {
    final src = widget.args.source;
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => CastSheet(
        url: Uri.parse(src.uri),
        title: widget.args.title,
        artwork: widget.args.poster,
        hasHeaders: src.headers.isNotEmpty,
        onCasting: () => _engine.pause(),
      ),
    );
    _scheduleHide();
  }

  void _onSession() {
    if (!mounted) return;
    if (_session.completedReached &&
        !_downloadCleaned &&
        ref.read(settingsProvider).deleteAfterWatching) {
      _downloadCleaned = true;
      ref.read(servicesProvider).downloads.removeIfDone(_session.args.videoId);
    }
    if (_session.nextRequested && _nextTimer == null) _startNextCountdown();
    setState(() {});
  }

  void _startNextCountdown() {
    _nextCountdown = ref.read(settingsProvider).nextCountdownSec;
    _nextTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _nextCountdown--);
      if (_nextCountdown <= 0) {
        t.cancel();
        _goNext();
      }
    });
  }

  Future<void> _goNext() async {
    _nextTimer?.cancel();
    final next = await widget.args.onNext?.call();
    if (!mounted) return;
    if (next == null) {
      setState(() => _nextCountdown = 0);
      return;
    }
    context.pushReplacement('/player', extra: next);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _session.saveProgressNow();
    }
    if (state == AppLifecycleState.paused &&
        !ref.read(settingsProvider).backgroundAudio) {
      // Give the activity a moment to report Picture in Picture before deciding the video must stop.
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (mounted && !_inPip) _engine.pause();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      _pipChannel
          .invokeMethod<void>('setAuto', {'on': false})
          .catchError((Object _) {});
    }
    _hideTimer?.cancel();
    _sleepTimer?.cancel();
    _nextTimer?.cancel();
    _hintTimer?.cancel();
    _pipChannel.setMethodCallHandler(null);
    _session.removeListener(_onSession);
    _session.dispose();
    _engine.dispose();
    _keepAwake(false);
    _brightnessCall((b) => b.resetApplicationScreenBrightness());
    AppOrientation.restore();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(
      Duration(seconds: ref.read(settingsProvider).controlsHideSec),
      () {
        if (mounted && _session.playing && !_panelOpen)
          setState(() => _controls = false);
      },
    );
  }

  bool _panelOpen = false;

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _scheduleHide();
  }

  void _hint(String text) {
    setState(() => _seekHint = text);
    _hintTimer?.cancel();
    _hintTimer = Timer(
      const Duration(milliseconds: 700),
      () => mounted ? setState(() => _seekHint = null) : null,
    );
  }

  Future<void> _exit() async {
    await _session.saveProgressNow();
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  Future<void> _enterPip() async {
    try {
      await _pipChannel.invokeMethod<void>('enter', {'width': 16, 'height': 9});
    } on PlatformException {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Questo dispositivo non permette il Picture in Picture.',
            ),
          ),
        );
    }
  }

  Future<void> _openPanel(Widget Function(BuildContext) builder) async {
    _panelOpen = true;
    _hideTimer?.cancel();
    await showSidePanel(context, builder);
    _panelOpen = false;
    if (mounted) _scheduleHide();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '${d.inMinutes}:$s';
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final settings = ref.watch(settingsProvider);
    final look = AetherLook.of(context);
    final canPip = Platform.isAndroid;
    // While the first picture is being prepared the logo/title is on screen: the controls wait.
    final starting =
        s.buffering && s.position == Duration.zero && s.error == null;
    final showControls = _controls && !_inPip && !s.locked && !starting;
    final skip = _segments?.active(
      s.position.inMilliseconds / 1000,
      duration: s.duration.inMilliseconds / 1000,
    );
    final total = s.duration.inMilliseconds.toDouble();
    final pos = (_dragSeekMs ?? s.position.inMilliseconds.toDouble())
        .clamp(0, total <= 0 ? 1 : total)
        .toDouble();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _engine.buildVideo(context, fit: s.aspect.boxFit),
            if (s.externalLine != null && !_inPip)
              Positioned(
                left: 40,
                right: 40,
                bottom: showControls ? 96 : 20 + settings.subBottom * 4,
                child: IgnorePointer(
                  child: _SubtitleText(
                    text: s.externalLine!,
                    scale: settings.subtitleScale,
                    color: colorFromHex(settings.subColor),
                    bold: settings.subBold,
                    outline: settings.subOutline,
                    outlineColor: colorFromHex(settings.subOutlineColor),
                    background: colorFromHex(settings.subBgColor)
                        .withValues(alpha: settings.subBgOpacity),
                  ),
                ),
              ),
            // Gestures: tap shows / hides the controls, double tap on a side seeks 10 s, a horizontal drag scrubs.
            if (!_inPip)
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, c) => GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _toggleControls,
                    onDoubleTapDown: (s.locked || !settings.gestures)
                        ? null
                        : (d) {
                            final left = d.localPosition.dx < c.maxWidth / 2;
                            final secs = left
                                ? -settings.skipBackSec
                                : settings.skipForwardSec;
                            s.seekBy(Duration(seconds: secs));
                            _hint('${secs > 0 ? '+' : '−'}${secs.abs()} s');
                          },
                    onDoubleTap: () {},
                    onLongPressStart: (s.locked || !settings.holdToSpeed)
                        ? null
                        : (_) {
                            _speedBefore = s.speed;
                            s.setSpeed(settings.holdSpeed);
                            _hint('${settings.holdSpeed.toStringAsFixed(2)}×');
                          },
                    onLongPressEnd: (s.locked || !settings.holdToSpeed)
                        ? null
                        : (_) => s.setSpeed(_speedBefore),
                    onVerticalDragStart: (s.locked || !settings.gestures)
                        ? null
                        : (d) => _verticalStart(d.localPosition.dx, c.maxWidth),
                    onVerticalDragUpdate: (s.locked || !settings.gestures)
                        ? null
                        : (d) => _verticalUpdate(d.delta.dy, c.maxHeight),
                    onHorizontalDragStart: s.locked
                        ? null
                        : (_) => _dragSeekStartMs = s.position.inMilliseconds
                              .toDouble(),
                    onHorizontalDragUpdate: s.locked
                        ? null
                        : (d) => setState(() {
                            _dragSeekMs =
                                ((_dragSeekMs ?? _dragSeekStartMs) +
                                        d.delta.dx * 120)
                                    .clamp(0, total <= 0 ? 0 : total)
                                    .toDouble();
                            _controls = true;
                          }),
                    onHorizontalDragEnd: s.locked
                        ? null
                        : (_) {
                            final target = _dragSeekMs;
                            setState(() => _dragSeekMs = null);
                            if (target != null)
                              s.seekTo(Duration(milliseconds: target.round()));
                            _scheduleHide();
                          },
                  ),
                ),
              ),
            if (_seekHint != null)
              Center(
                child: GlassSurface(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  radius: 20,
                  child: Text(
                    _seekHint!,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            if (s.buffering && s.error == null && !_inPip)
              Center(
                child: s.position == Duration.zero
                    ? _StartingCard(args: s.args)
                    : const CircularProgressIndicator(),
              ),
            if (starting && !_inPip)
              Positioned(
                left: 16,
                top: 12,
                child: SafeArea(
                  child: GlassButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    tooltip: 'Chiudi il player',
                    onPressed: _exit,
                  ),
                ),
              ),
            if (skip != null && !_inPip && !s.locked)
              Positioned(
                right: 24,
                bottom: showControls ? 110 : 40,
                child: SafeArea(
                  child: GlassButton(
                    icon: Icons.fast_forward_rounded,
                    label: skip.kind == SkipKind.intro
                        ? 'Salta intro'
                        : 'Salta riassunto',
                    prominent: true,
                    onPressed: () => s.seekTo(
                      Duration(milliseconds: (skip.end * 1000).round()),
                    ),
                  ),
                ),
              ),
            if (s.error != null)
              _ErrorOverlay(
                message: s.error!,
                onRetry: s.retry,
                onExit: _exit,
                alternatives: s.args.alternatives,
                onAlternative: s.switchSource,
              ),
            if (!_inPip && s.locked)
              Positioned(
                left: 24,
                bottom: 24,
                child: SafeArea(
                  child: GlassButton(
                    icon: Icons.lock_open_rounded,
                    label: 'Sblocca',
                    onPressed: () => s.setLocked(false),
                  ),
                ),
              ),
            if (_nextCountdown > 0 && !_inPip)
              Positioned(
                right: 24,
                bottom: 90,
                child: SafeArea(
                  child: GlassSurface(
                    padding: const EdgeInsets.all(14),
                    strong: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Prossimo episodio tra $_nextCountdown s'),
                        const SizedBox(width: 10),
                        TextButton(
                          onPressed: _goNext,
                          child: const Text('Ora'),
                        ),
                        TextButton(
                          onPressed: () {
                            _nextTimer?.cancel();
                            setState(() => _nextCountdown = 0);
                          },
                          child: const Text('Annulla'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Controls
            AnimatedOpacity(
              opacity: showControls ? 1 : 0,
              duration: look.reduceEffects
                  ? Duration.zero
                  : AetherTokens.medium,
              child: IgnorePointer(
                ignoring: !showControls,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xAA000000),
                        Colors.transparent,
                        Colors.transparent,
                        Color(0xCC000000),
                      ],
                      stops: [0, 0.25, 0.65, 1],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              GlassButton(
                                icon: Icons.arrow_back_ios_new_rounded,
                                tooltip: 'Chiudi il player',
                                onPressed: _exit,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s.args.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    if (s.args.isEpisode)
                                      Text(
                                        'S${s.args.season} · E${s.args.episode}${s.args.episodeTitle == null ? '' : ' · ${s.args.episodeTitle}'}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                  ],
                                ),
                              ),
                              if (_canCast)
                                GlassButton(
                                  icon: Icons.cast_rounded,
                                  tooltip: 'Trasmetti sulla TV',
                                  onPressed: _openCast,
                                ),
                              if (canPip)
                                GlassButton(
                                  icon: Icons.picture_in_picture_alt_rounded,
                                  tooltip: 'Picture in Picture',
                                  onPressed: _enterPip,
                                ),
                            ],
                          ),
                          const Spacer(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              GlassButton(
                                icon: settings.skipBackSec == 10
                                    ? Icons.replay_10_rounded
                                    : Icons.replay_rounded,
                                tooltip:
                                    'Indietro di ${settings.skipBackSec} secondi',
                                size: 54,
                                onPressed: () {
                                  s.seekBy(
                                    Duration(seconds: -settings.skipBackSec),
                                  );
                                  _scheduleHide();
                                },
                              ),
                              const SizedBox(width: 28),
                              GlassButton(
                                icon: s.playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                tooltip: s.playing ? 'Pausa' : 'Riproduci',
                                size: 72,
                                prominent: true,
                                onPressed: () {
                                  s.togglePlay();
                                  _scheduleHide();
                                },
                              ),
                              const SizedBox(width: 28),
                              GlassButton(
                                icon: settings.skipForwardSec == 10
                                    ? Icons.forward_10_rounded
                                    : Icons.fast_forward_rounded,
                                tooltip: 'Avanti di 10 secondi',
                                size: 54,
                                onPressed: () {
                                  s.seekBy(
                                    Duration(seconds: settings.skipForwardSec),
                                  );
                                  _scheduleHide();
                                },
                              ),
                            ],
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Text(
                                _fmt(Duration(milliseconds: pos.round())),
                                style: const TextStyle(
                                  fontFeatures: [FontFeature.tabularFigures()],
                                  fontSize: 12,
                                ),
                              ),
                              Expanded(
                                child: Slider(
                                  value: pos,
                                  max: total <= 0 ? 1 : total,
                                  onChanged: total <= 0
                                      ? null
                                      : (v) => setState(() => _dragSeekMs = v),
                                  onChangeEnd: (v) {
                                    setState(() => _dragSeekMs = null);
                                    s.seekTo(Duration(milliseconds: v.round()));
                                    _scheduleHide();
                                  },
                                ),
                              ),
                              Text(
                                total <= 0
                                    ? '--:--'
                                    : '-${_fmt(Duration(milliseconds: (total - pos).round()))}',
                                style: const TextStyle(
                                  fontFeatures: [FontFeature.tabularFigures()],
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                GlassButton(
                                  icon: Icons.lock_outline_rounded,
                                  tooltip: 'Blocca i controlli',
                                  size: 40,
                                  onPressed: () => s.setLocked(true),
                                ),
                                const SizedBox(width: 8),
                                GlassButton(
                                  icon: Icons.subtitles_rounded,
                                  label: 'Sottotitoli',
                                  size: 40,
                                  selected: s.subtitlesOn,
                                  onPressed: () => _openPanel(
                                    (_) => SubtitlePanel(session: s),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GlassButton(
                                  icon: Icons.audiotrack_rounded,
                                  label: 'Audio',
                                  size: 40,
                                  onPressed: () =>
                                      _openPanel((_) => AudioPanel(session: s)),
                                ),
                                const SizedBox(width: 8),
                                GlassButton(
                                  icon: Icons.speed_rounded,
                                  label: s.speed == 1
                                      ? 'Velocità'
                                      : '${s.speed}×',
                                  size: 40,
                                  onPressed: () =>
                                      _openPanel((_) => SpeedPanel(session: s)),
                                ),
                                const SizedBox(width: 8),
                                GlassButton(
                                  icon: Icons.aspect_ratio_rounded,
                                  label: s.aspect.label,
                                  size: 40,
                                  onPressed: s.cycleAspect,
                                ),
                                if (s.args.alternatives.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  GlassButton(
                                    icon: Icons.swap_horiz_rounded,
                                    label: 'Sorgenti',
                                    size: 40,
                                    onPressed: () => _openPanel(
                                      (_) => SourcesPanel(session: s),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({
    required this.message,
    required this.onRetry,
    required this.onExit,
    required this.alternatives,
    required this.onAlternative,
  });
  final String message;
  final Future<void> Function() onRetry;
  final VoidCallback onExit;
  final List<PlayerAlternative> alternatives;
  final Future<void> Function(PlayerAlternative) onAlternative;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: GlassSurface(
            padding: const EdgeInsets.all(22),
            strong: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 40,
                  color: AetherTokens.warning,
                ),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    GlassButton(
                      icon: Icons.refresh_rounded,
                      label: 'Riprova',
                      prominent: true,
                      onPressed: onRetry,
                    ),
                    if (alternatives.isNotEmpty)
                      GlassButton(
                        icon: Icons.swap_horiz_rounded,
                        label: 'Altra sorgente',
                        onPressed: () => onAlternative(alternatives.first),
                      ),
                    GlassButton(
                      icon: Icons.close_rounded,
                      label: 'Esci',
                      onPressed: onExit,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown while the first frame is prepared: the fanart.tv logo when there is one, else the title.
class _StartingCard extends ConsumerWidget {
  const _StartingCard({required this.args});
  final PlayerArgs args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logo = ref
        .watch(
          logoProvider((metaId: args.metaId, isMovie: args.type != 'series')),
        )
        .value;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (logo != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320, maxHeight: 120),
            child: Image.network(
              logo,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Text(
                args.title,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          )
        else
          Text(
            args.title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
          ),
        const SizedBox(height: 18),
        const CircularProgressIndicator(),
      ],
    );
  }
}

/// An external subtitle line: a solid outline is painted under the fill, so it stays readable on any picture and whatever colour
/// the viewer picked. (A text style with only shadows turned unreadable on bright scenes.)
class _SubtitleText extends StatelessWidget {
  const _SubtitleText({
    required this.text,
    required this.scale,
    required this.color,
    required this.bold,
    required this.outline,
    required this.outlineColor,
    required this.background,
  });
  final String text;
  final double scale;
  final Color color;
  final bool bold;
  final bool outline;
  final Color outlineColor;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: 22 * scale,
      fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
      height: 1.25,
      decoration: TextDecoration.none,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          if (outline)
            Text(
              text,
              textAlign: TextAlign.center,
              style: base.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 4 * scale.clamp(0.8, 1.6)
                  ..strokeJoin = StrokeJoin.round
                  ..color = outlineColor,
              ),
            ),
          Text(
            text,
            textAlign: TextAlign.center,
            style: base.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
