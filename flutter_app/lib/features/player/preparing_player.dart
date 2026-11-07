import 'dart:io';

import '../shell/shell.dart';

import 'package:dio/dio.dart' show CancelToken;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/model/meta.dart';
import '../../design/widgets.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/orientation.dart';
import '../../app/providers.dart';
import '../../data/prefs_ext.dart';
import '../../design/image_cache.dart';
import '../../design/glass.dart';
import '../../design/loader.dart';
import 'intro_sound.dart';
import 'playback_engine.dart';
import 'player_screen.dart';
import 'player_session.dart';

/// The player as soon as the viewer taps «Guarda» on a torrent: it is already landscape, shows the fanart.tv logo (or the title)
/// and what the debrid service is doing, and swaps to the real player when the link is ready. Back cancels the wait.
class PreparingPlayer extends ConsumerStatefulWidget {
  const PreparingPlayer({super.key, required this.args, this.engine});
  final PlayerArgs args;

  /// Tests inject an engine for the real player that replaces this screen.
  final PlaybackEngine? engine;

  @override
  ConsumerState<PreparingPlayer> createState() => _PreparingPlayerState();
}

class _PreparingPlayerState extends ConsumerState<PreparingPlayer>
    with HidesDock<PreparingPlayer> {
  PlayerArgs? _ready;

  /// The source is known (the link is ready) but the viewer has not pressed «Guarda» yet.
  PlayerArgs? _prepared;
  bool _intro = false;
  bool _zoomed = false;
  String _message = 'Contatto il servizio…';
  String? _error;
  CancelToken _cancel = CancelToken();

  @override
  void initState() {
    super.initState();
    AppOrientation.enterLandscape();
    final s = ref.read(settingsProvider);
    _intro = s.introFor(widget.args.type);
    final animates = _intro && s.animations;
    if (animates &&
        s.introSound &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      IntroSound.instance.play();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _zoomed = true);
    });
    if (widget.args.prepare == null) {
      _arrived(widget.args);
    } else {
      _run();
    }
  }

  /// The source is ready: it starts by itself, or waits for «Guarda» when the start screen is on for this kind of title.
  void _arrived(PlayerArgs ready) {
    _prepared = ready;
    if (!_intro) _ready = ready;
  }

  void _watch() {
    IntroSound.instance.stop();
    final p = _prepared;
    if (p != null) setState(() => _ready = p);
  }

  @override
  void dispose() {
    _cancel.cancel();
    IntroSound.instance.stop();
    AppOrientation.restore();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() => _error = null);
    _cancel = CancelToken();
    final control = PrepareControl(
      status: (m, [_]) {
        if (mounted) {
          setState(() => _message = m);
        }
      },
      confirm: (title, message, yes) async =>
          await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Annulla'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: Text(yes),
                ),
              ],
            ),
          ) ??
          false,
      cancel: _cancel,
    );
    try {
      final source = await widget.args.prepare!(control);
      if (mounted) setState(() => _arrived(widget.args.withSource(source)));
    } on Object catch (e) {
      if (mounted && !_cancel.isCancelled) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  void _back() {
    _cancel.cancel();
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final go = _ready;
    if (go != null) return PlayerScreen(args: go, engine: widget.engine);
    final a = widget.args;
    final settings = ref.watch(settingsProvider);
    final animates = _intro && settings.animations;
    final scene = _intro && settings.introScene;
    final meta = scene
        ? ref.watch(metaProvider(MetaKey(a.type, a.metaId))).value
        : null;
    final backdrop = meta?.background ?? meta?.poster ?? a.poster;
    final ready = _prepared != null;
    final logo = ref
        .watch(logoProvider((metaId: a.metaId, isMovie: a.type != 'series')))
        .value;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (scene && backdrop != null) ...[
              Opacity(
                opacity: 0.4,
                child: CachedNetworkImage(
                  imageUrl: backdrop,
                  cacheManager: AetherImageCache.manager,
                  fit: BoxFit.cover,
                  memCacheWidth: 900,
                  errorWidget: (_, __, ___) => const SizedBox(),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x59000000), Color(0xEB000000)],
                  ),
                ),
              ),
            ],
            Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(
                        begin: animates ? 0 : 1,
                        end: _zoomed || !animates ? 1 : 0,
                      ),
                      duration: animates
                          ? const Duration(milliseconds: 2200)
                          : Duration.zero,
                      curve: Curves.easeOut,
                      builder: (_, t, child) => Opacity(
                        opacity: t,
                        child: Transform.scale(
                          scale: animates ? 3.2 - 2.2 * t : 1,
                          child: child,
                        ),
                      ),
                      child: logo != null
                          ? LogoImage(
                              url: logo,
                              maxWidth: 340,
                              maxHeight: 130,
                              fallback: _title(a.title),
                            )
                          : _title(a.title),
                    ),
                    if (scene && meta != null) _info(meta),
                    if (a.isEpisode)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'S${a.season} · E${a.episode}${a.episodeTitle == null ? '' : ' · ${a.episodeTitle}'}',
                        ),
                      ),
                    const SizedBox(height: 22),
                    if (_error == null && ready && _intro) ...[
                      GlassButton(
                        icon: Icons.play_arrow_rounded,
                        label: 'Guarda',
                        onPressed: _watch,
                      ),
                    ] else if (_error == null) ...[
                      const AetherLoader(),
                      const SizedBox(height: 14),
                      Text(_message),
                    ] else ...[
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        children: [
                          GlassButton(
                            icon: Icons.refresh_rounded,
                            label: 'Riprova',
                            onPressed: _run,
                          ),
                          GlassButton(label: 'Chiudi', onPressed: _back),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              top: 12,
              child: SafeArea(
                child: GlassButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  tooltip: 'Annulla e torna indietro',
                  onPressed: _back,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Year, length and genres on one line, then the plot.
  Widget _info(MetaItem m) {
    final facts = [
      m.releaseInfo,
      m.runtime,
      m.genres.take(3).join(' · '),
    ].whereType<String>().where((e) => e.isNotEmpty).join('   ·   ');
    final plot = m.description;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          if (facts.isNotEmpty)
            Text(
              facts,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
                color: Colors.white70,
              ),
            ),
          if (plot != null && plot.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(
                  plot,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.35),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _title(String t) => Text(
    t,
    textAlign: TextAlign.center,
    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
  );
}
