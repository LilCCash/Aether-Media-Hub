import '../shell/shell.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
import '../../design/liquid.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../core/casting/upnp.dart';

import 'package:pip_kit/pip_kit.dart';

import 'avplayer_engine.dart';
import 'remux_bridge.dart';
import 'cast_sheet.dart';
import '../../design/light_theme.dart';
import 'now_playing.dart';
import 'google_cast_section.dart';
import 'media_kit_engine.dart';
import 'playback_engine.dart';
import 'player_panels.dart';
import 'player_session.dart';
import 'source_check.dart';
import 'subtitle_style.dart';

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
    with WidgetsBindingObserver, HidesDock<PlayerScreen> {
  late PlaybackEngine _engine;
  late PlayerSession _session;
  bool _fellBack = false;
  bool _creditsDismissed = false;
  bool _creditsAuto = false;
  DateTime? _sleepEnd;
  DateTime _npAt = DateTime.fromMillisecondsSinceEpoch(0);
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
    _engine = widget.engine ?? _pickEngine();
    _makeSession();
    _session.start();
    _loadSegments();
    _armPip();
    _wireNowPlaying();
    if (Platform.isAndroid) {
      _pipChannel
          .invokeMethod<void>('setAuto', {
            'on': ref.read(settingsProvider).autoPip,
          })
          .catchError((Object _) {});
    }
    final sleep = ref.read(settingsProvider).sleepTimerMin;
    if (sleep > 0) {
      _sleepEnd = DateTime.now().add(Duration(minutes: sleep));
      _sleepTimer = Timer(Duration(minutes: sleep), () {
        if (!mounted) return;
        _engine.pause();
        _hint('Timer di spegnimento: in pausa');
        setState(() => _controls = true);
      });
    }
    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged' && mounted) {
        setState(() => _inPip = call.arguments == true);
      }
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
    return (UpnpDiscovery.supported ||
            GoogleCastSection.supported ||
            Platform.isIOS) &&
        !src.isLocalFile &&
        (Uri.tryParse(src.uri)?.hasScheme ?? false) &&
        Uri.parse(src.uri).scheme.startsWith('http');
  }

  Future<void> _openCast() async {
    final src = widget.args.source;
    _hideTimer?.cancel();
    var url = Uri.parse(src.uri);
    String? mime;
    var headers = src.headers.isNotEmpty;
    if (RemuxBridge.supported) {
      // The television cannot send headers and does not read MKV: the phone serves the file (converted if need be) on the Wi-Fi.
      final engine = _engine;
      try {
        if (engine is AvPlayerEngine && (engine.lease?.lan ?? false)) {
          url = engine.lease!.url;
          mime = 'application/x-mpegURL';
          headers = false;
        } else if (RemuxBridge.isMatroska(src.uri)) {
          _hint('Preparo il file per la TV…', ms: 4000);
          final l = await RemuxBridge.open(src.uri, src.headers);
          url = l.url;
          mime = 'application/x-mpegURL';
          headers = false;
        } else if (headers) {
          _hint('Preparo il file per la TV…', ms: 4000);
          final l = await RemuxBridge.forward(src.uri, src.headers);
          url = l.url;
          headers = false;
        }
      } on Object catch (e) {
        _hint(RemuxBridge.messageOf(e), ms: 5000);
      }
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => CastSheet(
        url: url,
        mime: mime,
        title: widget.args.title,
        artwork: widget.args.poster,
        hasHeaders: headers,
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
    if (_engine is AvPlayerEngine && _session.error != null && !_fellBack) {
      _fallBackToMpv();
      return;
    }
    if (_session.nextRequested && _nextTimer == null) _startNextCountdown();
    final n = _session.notice;
    if (n != null) {
      _session.notice = null;
      _hint(n, ms: 3500);
    }
    _updateNowPlaying();
    setState(() {});
  }

  /// The lock screen: title, position and the buttons, refreshed about once a second.
  void _updateNowPlaying() {
    if (!Platform.isIOS || !ref.read(settingsProvider).nowPlaying) return;
    final now = DateTime.now();
    if (now.difference(_npAt).inMilliseconds < 1000) return;
    _npAt = now;
    final a = _session.args;
    NowPlaying.update(
      title: a.title,
      subtitle: a.isEpisode
          ? 'S${a.season} · E${a.episode}${a.episodeTitle == null ? '' : ' · ${a.episodeTitle}'}'
          : null,
      artwork: a.poster,
      durationSec: _session.duration.inMilliseconds / 1000,
      positionSec: _session.position.inMilliseconds / 1000,
      rate: _session.speed,
      playing: _session.playing,
      hasPrevious: _hasPrevious,
      hasNext: _hasNext,
    );
  }

  bool get _hasPrevious {
    final a = widget.args;
    final i = a.episodes.indexWhere((v) => v.id == a.videoId);
    return a.onPrevious != null && i > 0;
  }

  bool get _hasNext =>
      widget.args.onNext != null && widget.args.nextVideo != null;

  void _wireNowPlaying() {
    if (!Platform.isIOS) return;
    NowPlaying.listen((name, a) {
      if (!mounted) return;
      switch (name) {
        case 'play':
          _engine.play();
        case 'pause':
          _engine.pause();
        case 'toggle':
          _session.togglePlay();
        case 'forward':
          _session.seekBy(
            Duration(seconds: ref.read(settingsProvider).skipForwardSec),
          );
        case 'back':
          _session.seekBy(
            Duration(seconds: -ref.read(settingsProvider).skipBackSec),
          );
        case 'seek':
          final p = (a['position'] as num?)?.toDouble();
          if (p != null) {
            _session.seekTo(Duration(milliseconds: (p * 1000).round()));
          }
        case 'next':
          _goNext();
        case 'previous':
          _goPrevious();
      }
    });
  }

  Future<void> _goTo(
    Future<PlayerArgs?> Function()? prepare,
    String waiting,
    String missing,
  ) async {
    if (prepare == null) return;
    _hint(waiting, ms: 6000);
    final next = await prepare();
    if (!mounted) return;
    if (next == null) {
      _hint(missing, ms: 3500);
      return;
    }
    await _session.saveProgressNow();
    if (!mounted) return;
    context.pushReplacement('/player', extra: next);
  }

  Future<void> _goPrevious() => _goTo(
    widget.args.onPrevious,
    'Cerco l’episodio precedente…',
    'Nessuna fonte pronta per l’episodio precedente.',
  );

  Future<void> _openEpisodes() async {
    final a = widget.args;
    if (a.onEpisode == null || a.episodes.isEmpty) return;
    await _openPanel(
      (ctx) => EpisodesPanel(
        episodes: a.episodes,
        currentId: a.videoId,
        watched: ref.read(servicesProvider).library.isWatched,
        onPick: (v) {
          Navigator.of(ctx).pop();
          _goTo(
            () => a.onEpisode!(v),
            'Cerco una fonte per ${v.label}…',
            'Nessuna fonte pronta per quell’episodio.',
          );
        },
      ),
    );
  }

  void _startNextCountdown() {
    setState(
      () => _nextCountdown = ref.read(settingsProvider).nextCountdownSec,
    );
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
    setState(() => _nextCountdown = 0);
    await _goTo(
      widget.args.onNext,
      'Cerco l’episodio successivo…',
      'Nessuna fonte pronta per l’episodio successivo.',
    );
  }

  /// On iPhone an MP4, MOV or HLS file goes to the system player (the only one that can show Picture in Picture), like in the iOS
  /// app; everything else, and every other platform, stays on libmpv.
  PlaybackEngine _pickEngine() {
    final mode = ref.read(settingsProvider).playerEngine;
    if (Platform.isIOS &&
        mode != 'mpv' &&
        AvPlayerEngine.canOpen(widget.args.source, always: mode == 'av')) {
      return AvPlayerEngine()
        ..languages = [ref.read(settingsProvider).audioLanguage];
    }
    return MediaKitEngine();
  }

  void _makeSession() {
    final services = ref.read(servicesProvider);
    _session = PlayerSession(
      engine: _engine,
      args: widget.args,
      library: services.library,
      settings: ref.read(settingsProvider),
      subtitleLoader: services.subtitleLoader,
      preflight: checkSource,
      sync: services.sync,
    );
    _session.addListener(_onSession);
  }

  /// The system player could not open the file: libmpv takes over, once, from the same place.
  void _fallBackToMpv() {
    _fellBack = true;
    final why = _session.error;
    if (ref.read(settingsProvider).playerEngine == 'av') {
      _hint(
        'Il player di sistema non ha aperto il file${why == null ? '' : ' ($why)'}: uso libmpv.',
        ms: 5000,
      );
    }
    final at = _session.position;
    _session.removeListener(_onSession);
    _session.dispose();
    _engine.dispose();
    _engine = MediaKitEngine();
    _makeSession();
    _session.start();
    if (at > Duration.zero) _session.seekTo(at);
    unawaited(PipController.instance.disarm());
    if (mounted) setState(() {});
  }

  PipContent get _pipContent => PipContent.video(
    (context) => _engine.buildVideo(context, fit: BoxFit.contain),
  );

  /// iPhone: Picture in Picture opens by itself when the viewer leaves the app (when the setting is on), for system-player files.
  Future<void> _armPip() async {
    if (!Platform.isIOS || _engine is! AvPlayerEngine) return;
    try {
      if (await PipController.instance.isSupported() &&
          ref.read(settingsProvider).autoPip) {
        await PipController.instance.arm(
          _pipContent,
          options: const PipOptions(autoEnter: true),
        );
      }
    } on Object {
      // no Picture in Picture on this device (the simulator)
    }
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
    if (Platform.isIOS) {
      unawaited(PipController.instance.disarm());
      unawaited(NowPlaying.clear());
    }
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
        if (mounted && _session.playing && !_panelOpen) {
          setState(() => _controls = false);
        }
      },
    );
  }

  bool _panelOpen = false;

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _scheduleHide();
  }

  void _hint(String text, {int ms = 700}) {
    setState(() => _seekHint = text);
    _hintTimer?.cancel();
    _hintTimer = Timer(
      Duration(milliseconds: ms),
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
    if (Platform.isIOS) {
      final ok =
          _engine is AvPlayerEngine &&
          await PipController.instance.isSupported() &&
          await PipController.instance.enter(
            content: _pipContent,
            options: const PipOptions(),
          );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _engine is AvPlayerEngine
                  ? 'Il Picture in Picture non è disponibile su questo dispositivo.'
                  : 'Su iPhone il Picture in Picture funziona con i file MP4, MOV e HLS (player di sistema): questo file passa da libmpv, che non lo supporta.',
            ),
          ),
        );
      }
      return;
    }
    try {
      await _pipChannel.invokeMethod<void>('enter', {'width': 16, 'height': 9});
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Questo dispositivo non permette il Picture in Picture.',
            ),
          ),
        );
      }
    }
  }

  void _setSleep(int? minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepEnd = minutes == null
        ? null
        : DateTime.now().add(Duration(minutes: minutes));
    if (minutes == null) {
      setState(() {});
      return;
    }
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      if (!mounted) return;
      _engine.pause();
      _hint('Timer di spegnimento: in pausa');
      setState(() => _controls = true);
    });
    _hint('Si ferma tra $minutes minuti');
  }

  Future<void> _importSubtitle() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    if (picked.isEmpty || picked.first.path == null) return;
    final f = picked.first;
    final bytes = await File(f.path!).readAsBytes();
    await _session.selectExternalSubtitle(
      ExternalSubtitle(
        id: 'file:${f.name}',
        label: f.name,
        text: utf8.decode(bytes, allowMalformed: true),
        addon: 'File',
      ),
    );
    _hint('Sottotitoli caricati: ${f.name}');
  }

  /// The «⋯» menu of the iOS player: speed, sleep timer, fill, change source, import subtitles, source information.
  Widget _moreMenu(PlayerSession s) {
    return GlassSurface(
      radius: 22,
      child: SizedBox(
        width: 44,
        height: 44,
        child: PopupMenuButton<String>(
          tooltip: 'Altre opzioni',
          icon: const Icon(Icons.more_horiz_rounded),
          color: AetherTokens.inkRaised,
          onOpened: () {
            _panelOpen = true;
            _hideTimer?.cancel();
          },
          onCanceled: () {
            _panelOpen = false;
            _scheduleHide();
          },
          onSelected: (v) {
            _panelOpen = false;
            switch (v) {
              case 'speed':
                _openPanel((_) => SpeedPanel(session: s));
              case 'sleep':
                _openPanel(
                  (_) => ChoicePanel<int>(
                    title: 'Timer di spegnimento',
                    options: const {
                      0: 'Disattivato',
                      15: '15 minuti',
                      30: '30 minuti',
                      45: '45 minuti',
                      60: '60 minuti',
                      90: '90 minuti',
                    },
                    onPick: (m) => _setSleep(m == 0 ? null : m),
                  ),
                );
              case 'fill':
                s.cycleAspect();
              case 'sources':
                _openPanel((_) => SourcesPanel(session: s));
              case 'episodes':
                _openEpisodes();
              case 'import':
                _importSubtitle();
              case 'info':
                _openPanel((_) => InfoPanel(session: s, engine: _engine));
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'speed',
              child: _MenuRow(
                Icons.speed_rounded,
                'Velocità (${s.speed == 1 ? 'Normale' : '${s.speed}×'})',
              ),
            ),
            const PopupMenuItem(
              value: 'sleep',
              child: _MenuRow(Icons.bedtime_outlined, 'Timer di spegnimento'),
            ),
            PopupMenuItem(
              value: 'fill',
              child: _MenuRow(
                s.aspect == AspectMode.fit
                    ? Icons.zoom_out_map_rounded
                    : Icons.zoom_in_map_rounded,
                s.aspect == AspectMode.fit
                    ? 'Riempi lo schermo'
                    : 'Adatta allo schermo',
              ),
            ),
            if (s.args.onEpisode != null && s.args.episodes.isNotEmpty)
              const PopupMenuItem(
                value: 'episodes',
                child: _MenuRow(Icons.format_list_numbered_rounded, 'Episodi'),
              ),
            if (s.args.alternatives.isNotEmpty)
              const PopupMenuItem(
                value: 'sources',
                child: _MenuRow(Icons.swap_horiz_rounded, 'Cambia sorgente'),
              ),
            const PopupMenuItem(
              value: 'import',
              child: _MenuRow(Icons.note_add_outlined, 'Importa sottotitoli…'),
            ),
            const PopupMenuItem(
              value: 'info',
              child: _MenuRow(
                Icons.info_outline_rounded,
                'Informazioni sulla sorgente',
              ),
            ),
          ],
        ),
      ),
    );
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
    final player = LightCancel(child: _buildPlayer(context));
    // Over the system player's native view the controls are flat: a blur behind them would show grey patches of the picture.
    return _engine is AvPlayerEngine
        ? AetherLook.flat(context, player)
        : player;
  }

  Widget _buildPlayer(BuildContext context) {
    final s = _session;
    final settings = ref.watch(settingsProvider);
    ref.listen(settingsProvider, (_, next) => _session.applyStyleOptions(next));
    final look = AetherLook.of(context);
    final canPip = Platform.isAndroid || Platform.isIOS;
    // While the first picture is being prepared the logo/title is on screen: the controls wait.
    final starting =
        s.buffering && s.position == Duration.zero && s.error == null;
    final showControls = _controls && !_inPip && !s.locked && !starting;
    final skip = _segments?.active(
      s.position.inMilliseconds / 1000,
      duration: s.duration.inMilliseconds / 1000,
    );
    final total = s.duration.inMilliseconds.toDouble();
    // End credits: the «next episode» card appears in the last seconds (or where the service says the credits start).
    final nextV = s.args.nextVideo;
    final creditsAt =
        _segments?.credits?.start ??
        (total > 0 ? total / 1000 - settings.creditsSec : double.infinity);
    final inCredits =
        nextV != null &&
        s.args.onNext != null &&
        settings.skipCredits &&
        total > 0 &&
        !_creditsDismissed &&
        _nextCountdown == 0 &&
        s.position.inMilliseconds / 1000 >= creditsAt &&
        total - s.position.inMilliseconds > 2000;
    if (inCredits &&
        settings.autoNextAtCredits &&
        _nextTimer == null &&
        !_creditsAuto) {
      _creditsAuto = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startNextCountdown();
      });
    }
    final sleepLeft = _sleepEnd?.difference(DateTime.now());
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
                  child: Center(
                    child: SubtitleText(
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
                            if (target != null) {
                              s.seekTo(Duration(milliseconds: target.round()));
                            }
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
            if (inCredits && !_inPip && !s.locked)
              Positioned(
                right: 24,
                bottom: showControls ? 120 : 56,
                child: SafeArea(
                  child: NextEpisodeCard(
                    video: nextV,
                    preview: settings.nextPreview,
                    onNow: _goNext,
                    onStay: () => setState(() => _creditsDismissed = true),
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
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // The shade must not take taps: a tap on the picture hides the controls.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
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
                        ),
                      ),
                    ),
                    SafeArea(
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
                                  icon: Icons.keyboard_arrow_down_rounded,
                                  tooltip: 'Chiudi il player',
                                  onPressed: _exit,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                      if (sleepLeft != null &&
                                          sleepLeft > Duration.zero)
                                        Text(
                                          'Si spegne tra ${sleepLeft.inMinutes + 1} min',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: AetherTokens.textSecondary,
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
                                if (Platform.isIOS)
                                  GlassSurface(
                                    radius: 22,
                                    child: const SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: UiKitView(
                                        viewType: 'aether/airplay',
                                      ),
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
                                const SizedBox(width: 6),
                                _moreMenu(s),
                              ],
                            ),
                            const Spacer(),
                            _CenterControls(
                              playing: s.playing,
                              backSec: settings.skipBackSec,
                              forwardSec: settings.skipForwardSec,
                              onBack: () {
                                s.seekBy(
                                  Duration(seconds: -settings.skipBackSec),
                                );
                                _scheduleHide();
                              },
                              onToggle: () {
                                s.togglePlay();
                                _scheduleHide();
                              },
                              onForward: () {
                                s.seekBy(
                                  Duration(seconds: settings.skipForwardSec),
                                );
                                _scheduleHide();
                              },
                              onPrevious: _hasPrevious ? _goPrevious : null,
                              onNextEpisode: _hasNext ? _goNext : null,
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                Expanded(
                                  child: Slider(
                                    value: pos,
                                    max: total <= 0 ? 1 : total,
                                    onChanged: total <= 0
                                        ? null
                                        : (v) =>
                                              setState(() => _dragSeekMs = v),
                                    onChangeEnd: (v) {
                                      setState(() => _dragSeekMs = null);
                                      s.seekTo(
                                        Duration(milliseconds: v.round()),
                                      );
                                      _scheduleHide();
                                    },
                                  ),
                                ),
                              ],
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _fmt(Duration(milliseconds: pos.round())),
                                    style: const TextStyle(
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    total <= 0
                                        ? '--:--'
                                        : '\u2212${_fmt(Duration(milliseconds: (total - pos).round()))}',
                                    style: const TextStyle(
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Row(
                              children: [
                                GlassButton(
                                  icon: Icons.lock_outline_rounded,
                                  tooltip: 'Blocca i controlli',
                                  size: 40,
                                  onPressed: () => s.setLocked(true),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    reverse: true,
                                    child: Row(
                                      children: [
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
                                          onPressed: () => _openPanel(
                                            (_) => AudioPanel(session: s),
                                          ),
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
                                        const SizedBox(width: 8),
                                        GlassButton(
                                          icon: Icons.speed_rounded,
                                          label: s.speed == 1
                                              ? 'Velocità'
                                              : '${s.speed}×',
                                          size: 40,
                                          onPressed: () => _openPanel(
                                            (_) => SpeedPanel(session: s),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        GlassButton(
                                          icon: Icons.aspect_ratio_rounded,
                                          label: s.aspect == AspectMode.fit
                                              ? 'Riempi'
                                              : s.aspect.label,
                                          size: 40,
                                          onPressed: s.cycleAspect,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
  );
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
          LogoImage(
            url: logo,
            maxWidth: 320,
            maxHeight: 120,
            fallback: Text(
              args.title,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
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

/// The three central controls as one piece: a glass capsule with the skip buttons and a large play/pause disc between them.
class _CenterControls extends StatelessWidget {
  const _CenterControls({
    required this.playing,
    required this.backSec,
    required this.forwardSec,
    required this.onBack,
    required this.onToggle,
    required this.onForward,
    this.onPrevious,
    this.onNextEpisode,
  });
  final VoidCallback? onPrevious;
  final VoidCallback? onNextEpisode;
  final bool playing;
  final int backSec;
  final int forwardSec;
  final VoidCallback onBack;
  final VoidCallback onToggle;
  final VoidCallback onForward;

  Widget _skip(
    IconData icon,
    String tip,
    VoidCallback tap, {
    bool small = false,
  }) => Semantics(
    button: true,
    label: tip,
    excludeSemantics: true,
    child: Tooltip(
      message: tip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tap,
        child: SizedBox(
          width: small ? 44 : 64,
          height: small ? 44 : 64,
          child: Icon(icon, size: small ? 26 : 34, color: Colors.white),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final accent = AetherLook.of(context).accent;
    return Center(
      child: LiquidSurface(
        radius: 48,
        strong: true,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onPrevious != null) ...[
              _skip(
                Icons.skip_previous_rounded,
                'Episodio precedente',
                onPrevious!,
                small: true,
              ),
              const SizedBox(width: 4),
            ],
            _skip(
              backSec == 10 ? Icons.replay_10_rounded : Icons.replay_rounded,
              'Indietro di $backSec secondi',
              onBack,
            ),
            const SizedBox(width: 10),
            Semantics(
              button: true,
              label: playing ? 'Pausa' : 'Riproduci',
              excludeSemantics: true,
              child: Tooltip(
                message: playing ? 'Pausa' : 'Riproduci',
                child: GestureDetector(
                  onTap: onToggle,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white,
                          Color.lerp(Colors.white, accent, 0.45)!,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.45),
                          blurRadius: 24,
                        ),
                      ],
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (c, a) => ScaleTransition(
                        scale: a,
                        child: FadeTransition(opacity: a, child: c),
                      ),
                      child: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        key: ValueKey(playing),
                        size: 46,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _skip(
              forwardSec == 10
                  ? Icons.forward_10_rounded
                  : Icons.fast_forward_rounded,
              'Avanti di $forwardSec secondi',
              onForward,
            ),
            if (onNextEpisode != null) ...[
              const SizedBox(width: 4),
              _skip(
                Icons.skip_next_rounded,
                'Episodio successivo',
                onNextEpisode!,
                small: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
