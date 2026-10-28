import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/orientation.dart';
import '../../app/providers.dart';
import '../../design/glass.dart';
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

class _PreparingPlayerState extends ConsumerState<PreparingPlayer> {
  PlayerArgs? _ready;
  String _message = 'Contatto il servizio…';
  double? _fraction;
  String? _error;
  CancelToken _cancel = CancelToken();

  @override
  void initState() {
    super.initState();
    AppOrientation.setBase(
      AppOrientation.landscape,
      ui: SystemUiMode.immersiveSticky,
    ).then((_) {
      if (!mounted) AppOrientation.restore();
    });
    _run();
  }

  @override
  void dispose() {
    _cancel.cancel();
    AppOrientation.restore();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() => _error = null);
    _cancel = CancelToken();
    final control = PrepareControl(
      status: (m, [f]) {
        if (mounted) {
          setState(() {
            _message = m;
            _fraction = f;
          });
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
      if (mounted) setState(() => _ready = widget.args.withSource(source));
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
    final ready = _ready;
    if (ready != null) return PlayerScreen(args: ready, engine: widget.engine);
    final a = widget.args;
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
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (logo != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 340,
                        maxHeight: 130,
                      ),
                      child: Image.network(
                        logo,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => _title(a.title),
                      ),
                    )
                  else
                    _title(a.title),
                  if (a.isEpisode)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'S${a.season} · E${a.episode}${a.episodeTitle == null ? '' : ' · ${a.episodeTitle}'}',
                      ),
                    ),
                  const SizedBox(height: 22),
                  if (_error == null) ...[
                    SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(value: _fraction),
                    ),
                    const SizedBox(height: 12),
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

  Widget _title(String t) => Text(
    t,
    textAlign: TextAlign.center,
    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
  );
}
