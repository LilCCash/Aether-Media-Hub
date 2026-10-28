import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/debrid/debrid_resolver.dart';
import '../../core/debrid/torbox_client.dart';
import '../../core/model/meta.dart';
import '../../core/streams/stream_analyzer.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../player/playback_engine.dart';
import '../player/player_session.dart';
import 'play_planner.dart';

/// From a tap on a source to the player: handles direct links, torrents through TorBox (with a confirmation before anything is
/// downloaded), external pages, and explains every failure.
Future<void> playStream(
  BuildContext context,
  WidgetRef ref, {
  required MetaItem meta,
  Video? video,
  required RankedStream chosen,
  required List<RankedStream> all,
  required StreamsState state,

  /// When set, the player is not opened: the resolved source goes here instead (used to download a torrent source).
  Future<void> Function(PlaybackSource source)? onResolved,
}) async {
  final services = ref.read(servicesProvider);
  final planner = PlayPlanner(services, ref.read(settingsProvider));
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);

  if (chosen.playability == StreamPlayability.external) {
    final url =
        chosen.stream.externalUrl ??
        (chosen.stream.ytId == null
            ? null
            : 'https://www.youtube.com/watch?v=${chosen.stream.ytId}');
    if (url != null &&
        Uri.tryParse(url) != null &&
        Uri.parse(url).scheme.startsWith('http')) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
    return;
  }

  PlaybackSource? source;
  if (chosen.playability == StreamPlayability.direct) {
    source = await planner.sourceFor(chosen.stream);
  } else if (chosen.playability == StreamPlayability.needsDebrid) {
    if (!await planner.debridConfigured) {
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Serve un servizio debrid'),
            content: const Text(
              'Questa sorgente è un torrent: per guardarla serve TorBox. Inserisci la tua chiave in Impostazioni ▸ Servizi.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Chiudi'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(c);
                  router.push('/settings/services');
                },
                child: const Text('Apri Servizi'),
              ),
            ],
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;
    if (onResolved == null) {
      // The player opens at once, shows the logo and does the waiting itself (with its own confirmation).
      final args = planner.buildArgs(
        meta: meta,
        video: video,
        stream: chosen.stream,
        source: const PlaybackSource(uri: ''),
        addonSubtitles: state.subtitles,
        others: all,
        prepare: (ctl) async {
          ctl.status(
            'Controllo ${(await planner.provider)?.name ?? 'il servizio'}…',
          );
          try {
            return await planner.sourceFor(
              chosen.stream,
              season: video?.season,
              episode: video?.episode,
              onStatus: (s) => ctl.status(s.message, s.fraction),
              cancel: ctl.cancel,
            );
          } on DebridException catch (e) {
            if (e.failure != DebridFailure.notCached) rethrow;
            final ok = await ctl.confirm(
              'Avviare il download sul servizio debrid?',
              'Questo contenuto non è già pronto: andrebbe scaricato sul tuo account (può contare sui tuoi limiti). Aether non cancella mai nulla dal tuo account.',
              'Avvia il download',
            );
            if (!ok) {
              throw const DebridException(
                DebridFailure.cancelled,
                'Download annullato.',
              );
            }
            return planner.sourceFor(
              chosen.stream,
              allowDownload: true,
              season: video?.season,
              episode: video?.episode,
              onStatus: (s) => ctl.status(s.message, s.fraction),
              cancel: ctl.cancel,
            );
          }
        },
      );
      router.push('/player', extra: args);
      return;
    }
    source = await _resolveWithDialog(
      context,
      planner,
      chosen,
      video,
      allowDownload: false,
    );
    if (source == null &&
        context.mounted &&
        _lastFailure == DebridFailure.notCached) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Avviare il download su TorBox?'),
          content: const Text(
            'Questo contenuto non è nella cache di TorBox: andrebbe scaricato sul tuo account (può contare sui tuoi limiti). Aether non cancella mai nulla dal tuo account.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Annulla'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Avvia il download'),
            ),
          ],
        ),
      );
      if (ok == true && context.mounted)
        source = await _resolveWithDialog(
          context,
          planner,
          chosen,
          video,
          allowDownload: true,
        );
    }
    if (source == null) {
      if (_lastFailure != null &&
          _lastFailure != DebridFailure.cancelled &&
          _lastFailure != DebridFailure.notCached)
        messenger.showSnackBar(
          SnackBar(content: Text(_lastMessage ?? 'TorBox non ha risposto.')),
        );
      return;
    }
  }
  if (source == null) return;
  if (onResolved != null) {
    await onResolved(source);
    return;
  }
  final args = planner.buildArgs(
    meta: meta,
    video: video,
    stream: chosen.stream,
    source: source,
    addonSubtitles: state.subtitles,
    others: all,
  );
  router.push('/player', extra: args);
}

DebridFailure? _lastFailure;
String? _lastMessage;

Future<PlaybackSource?> _resolveWithDialog(
  BuildContext context,
  PlayPlanner planner,
  RankedStream chosen,
  Video? video, {
  required bool allowDownload,
}) async {
  _lastFailure = null;
  _lastMessage = null;
  final cancel = CancelToken();
  final status = ValueNotifier<ResolveStatus>(
    const ResolveStatus('Controllo TorBox…'),
  );
  PlaybackSource? result;
  var finished = false;
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: GlassSurface(
          padding: const EdgeInsets.all(22),
          strong: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<ResolveStatus>(
                valueListenable: status,
                builder: (_, s, __) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: s.fraction, minHeight: 4),
                    const SizedBox(height: 16),
                    Text(
                      s.message,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => cancel.cancel(),
                child: const Text('Annulla'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    result = await planner.sourceFor(
      chosen.stream,
      allowDownload: allowDownload,
      season: video?.season,
      episode: video?.episode,
      onStatus: (s) => status.value = s,
      cancel: cancel,
    );
  } on DebridException catch (e) {
    _lastFailure = e.failure;
    _lastMessage = e.message;
  } on Object {
    _lastFailure = DebridFailure.unknown;
    _lastMessage = 'Non riesco a preparare questa sorgente.';
  } finally {
    finished = true;
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialog;
    status.dispose();
  }
  assert(finished);
  return result;
}

/// Shows why a source could not be played, in the AetherTokens palette.
void showProblem(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(backgroundColor: AetherTokens.inkRaised, content: Text(message)),
    );
