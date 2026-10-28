import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/providers.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
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

class _PlayerScreenState extends ConsumerState<PlayerScreen> with WidgetsBindingObserver {
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _keepAwake(true);
    final services = ref.read(servicesProvider);
    _session = PlayerSession(engine: _engine, args: widget.args, library: services.library, settings: ref.read(settingsProvider), subtitleLoader: services.subtitleLoader);
    _session.addListener(_onSession);
    _session.start();
    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged' && mounted) setState(() => _inPip = call.arguments == true);
    });
    _scheduleHide();
  }

  /// Keeps the screen on while watching; a device without the feature must not break playback.
  Future<void> _keepAwake(bool on) async {
    try {
      await (on ? WakelockPlus.enable() : WakelockPlus.disable());
    } on Object {
      // not available on this platform / in tests
    }
  }

  void _onSession() {
    if (!mounted) return;
    if (_session.nextRequested && _nextTimer == null) _startNextCountdown();
    setState(() {});
  }

  void _startNextCountdown() {
    _nextCountdown = 8;
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
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) _session.saveProgressNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _nextTimer?.cancel();
    _hintTimer?.cancel();
    _pipChannel.setMethodCallHandler(null);
    _session.removeListener(_onSession);
    _session.dispose();
    _engine.dispose();
    _keepAwake(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _session.playing && !_panelOpen) setState(() => _controls = false);
    });
  }

  bool _panelOpen = false;

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _scheduleHide();
  }

  void _hint(String text) {
    setState(() => _seekHint = text);
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 700), () => mounted ? setState(() => _seekHint = null) : null);
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Questo dispositivo non permette il Picture in Picture.')));
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
    final showControls = _controls && !_inPip && !s.locked;
    final total = s.duration.inMilliseconds.toDouble();
    final pos = (_dragSeekMs ?? s.position.inMilliseconds.toDouble()).clamp(0, total <= 0 ? 1 : total).toDouble();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          _engine.buildVideo(context, fit: s.aspect.boxFit),
          if (s.externalLine != null && !_inPip)
            Positioned(
              left: 40,
              right: 40,
              bottom: showControls ? 96 : 36,
              child: IgnorePointer(
                child: Text(s.externalLine!, textAlign: TextAlign.center, style: TextStyle(fontSize: 22 * settings.subtitleScale, fontWeight: FontWeight.w600, color: Colors.white, height: 1.25, shadows: const [Shadow(blurRadius: 6, color: Colors.black), Shadow(blurRadius: 2, color: Colors.black)])),
              ),
            ),
          // Gestures: tap shows / hides the controls, double tap on a side seeks 10 s, a horizontal drag scrubs.
          if (!_inPip)
            Positioned.fill(
              child: LayoutBuilder(builder: (context, c) => GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _toggleControls,
                onDoubleTapDown: s.locked ? null : (d) {
                  final left = d.localPosition.dx < c.maxWidth / 2;
                  s.seekBy(Duration(seconds: left ? -10 : 10));
                  _hint(left ? '−10 s' : '+10 s');
                },
                onDoubleTap: () {},
                onHorizontalDragStart: s.locked ? null : (_) => _dragSeekStartMs = s.position.inMilliseconds.toDouble(),
                onHorizontalDragUpdate: s.locked ? null : (d) => setState(() {
                  _dragSeekMs = ((_dragSeekMs ?? _dragSeekStartMs) + d.delta.dx * 120).clamp(0, total <= 0 ? 0 : total).toDouble();
                  _controls = true;
                }),
                onHorizontalDragEnd: s.locked ? null : (_) {
                  final target = _dragSeekMs;
                  setState(() => _dragSeekMs = null);
                  if (target != null) s.seekTo(Duration(milliseconds: target.round()));
                  _scheduleHide();
                },
              )),
            ),
          if (_seekHint != null) Center(child: GlassSurface(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10), radius: 20, child: Text(_seekHint!, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)))),
          if (s.buffering && s.error == null && !_inPip) const Center(child: CircularProgressIndicator()),
          if (s.error != null) _ErrorOverlay(message: s.error!, onRetry: s.retry, onExit: _exit, alternatives: s.args.alternatives, onAlternative: s.switchSource),
          if (!_inPip && s.locked)
            Positioned(left: 24, bottom: 24, child: SafeArea(child: GlassButton(icon: Icons.lock_open_rounded, label: 'Sblocca', onPressed: () => s.setLocked(false)))),
          if (_nextCountdown > 0 && !_inPip)
            Positioned(right: 24, bottom: 90, child: SafeArea(child: GlassSurface(padding: const EdgeInsets.all(14), strong: true, child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Prossimo episodio tra $_nextCountdown s'),
              const SizedBox(width: 10),
              TextButton(onPressed: _goNext, child: const Text('Ora')),
              TextButton(onPressed: () { _nextTimer?.cancel(); setState(() => _nextCountdown = 0); }, child: const Text('Annulla')),
            ])))),
          // Controls
          AnimatedOpacity(
            opacity: showControls ? 1 : 0,
            duration: look.reduceEffects ? Duration.zero : AetherTokens.medium,
            child: IgnorePointer(
              ignoring: !showControls,
              child: Container(
                decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xAA000000), Colors.transparent, Colors.transparent, Color(0xCC000000)], stops: [0, 0.25, 0.65, 1])),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(children: [
                      Row(children: [
                        GlassButton(icon: Icons.arrow_back_ios_new_rounded, tooltip: 'Chiudi il player', onPressed: _exit),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s.args.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                          if (s.args.isEpisode) Text('S${s.args.season} · E${s.args.episode}${s.args.episodeTitle == null ? '' : ' · ${s.args.episodeTitle}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                        ])),
                        if (canPip) GlassButton(icon: Icons.picture_in_picture_alt_rounded, tooltip: 'Picture in Picture', onPressed: _enterPip),
                      ]),
                      const Spacer(),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        GlassButton(icon: Icons.replay_10_rounded, tooltip: 'Indietro di 10 secondi', size: 54, onPressed: () { s.seekBy(const Duration(seconds: -10)); _scheduleHide(); }),
                        const SizedBox(width: 28),
                        GlassButton(icon: s.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, tooltip: s.playing ? 'Pausa' : 'Riproduci', size: 72, prominent: true, onPressed: () { s.togglePlay(); _scheduleHide(); }),
                        const SizedBox(width: 28),
                        GlassButton(icon: Icons.forward_10_rounded, tooltip: 'Avanti di 10 secondi', size: 54, onPressed: () { s.seekBy(const Duration(seconds: 10)); _scheduleHide(); }),
                      ]),
                      const Spacer(),
                      Row(children: [
                        Text(_fmt(Duration(milliseconds: pos.round())), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: pos,
                            max: total <= 0 ? 1 : total,
                            onChanged: total <= 0 ? null : (v) => setState(() => _dragSeekMs = v),
                            onChangeEnd: (v) {
                              setState(() => _dragSeekMs = null);
                              s.seekTo(Duration(milliseconds: v.round()));
                              _scheduleHide();
                            },
                          ),
                        ),
                        Text(total <= 0 ? '--:--' : '-${_fmt(Duration(milliseconds: (total - pos).round()))}', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 12)),
                      ]),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: [
                          GlassButton(icon: Icons.lock_outline_rounded, tooltip: 'Blocca i controlli', size: 40, onPressed: () => s.setLocked(true)),
                          const SizedBox(width: 8),
                          GlassButton(icon: Icons.subtitles_rounded, label: 'Sottotitoli', size: 40, selected: s.subtitlesOn, onPressed: () => _openPanel((_) => SubtitlePanel(session: s))),
                          const SizedBox(width: 8),
                          GlassButton(icon: Icons.audiotrack_rounded, label: 'Audio', size: 40, onPressed: () => _openPanel((_) => AudioPanel(session: s))),
                          const SizedBox(width: 8),
                          GlassButton(icon: Icons.speed_rounded, label: s.speed == 1 ? 'Velocità' : '${s.speed}×', size: 40, onPressed: () => _openPanel((_) => SpeedPanel(session: s))),
                          const SizedBox(width: 8),
                          GlassButton(icon: Icons.aspect_ratio_rounded, label: s.aspect.label, size: 40, onPressed: s.cycleAspect),
                          if (s.args.alternatives.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            GlassButton(icon: Icons.swap_horiz_rounded, label: 'Sorgenti', size: 40, onPressed: () => _openPanel((_) => SourcesPanel(session: s))),
                          ],
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({required this.message, required this.onRetry, required this.onExit, required this.alternatives, required this.onAlternative});
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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline_rounded, size: 40, color: AetherTokens.warning),
              const SizedBox(height: 10),
              Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
                GlassButton(icon: Icons.refresh_rounded, label: 'Riprova', prominent: true, onPressed: onRetry),
                if (alternatives.isNotEmpty) GlassButton(icon: Icons.swap_horiz_rounded, label: 'Altra sorgente', onPressed: () => onAlternative(alternatives.first)),
                GlassButton(icon: Icons.close_rounded, label: 'Esci', onPressed: onExit),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
