import 'dart:async';

import 'package:dio/dio.dart';

import '../model/stream.dart';
import 'debrid_provider.dart';
import 'torbox_client.dart';

class ResolveStatus {
  const ResolveStatus(this.message, {this.fraction});
  final String message;
  final double? fraction;
}

class ResolvedLink {
  const ResolvedLink(this.uri, {this.fileName});
  final Uri uri;
  final String? fileName;
}

/// Turns a torrent stream into a playable link through TorBox. It never deletes or "repairs" anything in the user's account.
/// With [allowDownload] false only content that is already in TorBox's cache is accepted (nothing new is started); with true
/// and a torrent that is not cached, TorBox downloads it and this waits, reporting progress, until it is ready or cancelled.
class DebridResolver implements DebridProvider {
  DebridResolver(
    this.client, {
    this.pollInterval = const Duration(seconds: 3),
    this.maxCachedWait = const Duration(seconds: 90),
    this.maxDownloadWait = const Duration(hours: 2),
  });

  final TorBoxClient client;
  final Duration pollInterval;
  final Duration maxCachedWait;
  final Duration maxDownloadWait;

  @override
  String get name => 'TorBox';

  @override
  Future<Map<String, bool>?> cached(
    List<String> hashes, {
    CancelToken? cancel,
  }) => client.checkCached(hashes);

  @override
  Future<ResolvedLink> resolve(
    AddonStream stream, {
    bool allowDownload = false,
    int? season,
    int? episode,
    void Function(ResolveStatus)? onStatus,
    CancelToken? cancel,
  }) async {
    final hash = stream.infoHash;
    if (hash == null)
      throw const DebridException(
        DebridFailure.unknown,
        'Questa sorgente non è un torrent.',
      );
    void report(String m, [double? f]) =>
        onStatus?.call(ResolveStatus(m, fraction: f));
    void checkCancel() {
      if (cancel?.isCancelled ?? false)
        throw const DebridException(
          DebridFailure.cancelled,
          'Operazione annullata.',
        );
    }

    report('Controllo TorBox…');
    var id = await client.findByHash(hash, cancel: cancel);
    checkCancel();
    if (id == null) {
      report(
        allowDownload
            ? 'Aggiungo il torrent a TorBox…'
            : 'Preparo la sorgente su TorBox…',
      );
      try {
        id = await client.addMagnet(
          stream.magnet,
          onlyIfCached: !allowDownload,
          cancel: cancel,
        );
      } on DebridException catch (e) {
        if (e.failure == DebridFailure.notCached && allowDownload) {
          // Some answers use 409 for an already-queued item: look it up before giving up.
          id = await client.findByHash(hash, cancel: cancel);
          if (id == null) rethrow;
        } else {
          rethrow;
        }
      }
    }
    final limit = allowDownload ? maxDownloadWait : maxCachedWait;
    final started = DateTime.now();
    while (true) {
      checkCancel();
      final torrent = await client.torrent(id, cancel: cancel);
      if (torrent != null && torrent.ready) {
        final hint = TorBoxClient.episodeHint(season, episode);
        final file = TorBoxClient.chooseFile(
          torrent.files,
          fileIdx: stream.fileIdx,
          episodeHint: hint,
        );
        if (file == null)
          throw DebridException(
            DebridFailure.notReady,
            hint != null
                ? 'L’episodio ${hint.toUpperCase()} non è nel torrent.'
                : 'Nel torrent non c’è nessun file video.',
          );
        report('Ottengo il link…');
        final link = await client.requestLink(id, file.id, cancel: cancel);
        return ResolvedLink(link, fileName: file.name);
      }
      if (DateTime.now().difference(started) > limit) {
        throw DebridException(
          DebridFailure.notReady,
          allowDownload
              ? 'TorBox sta ancora scaricando: riprova più tardi.'
              : 'TorBox non ha preparato il contenuto in tempo.',
        );
      }
      final pct = torrent == null ? null : torrent.progress;
      report(
        allowDownload
            ? 'Download su TorBox${pct == null ? '' : ' · ${(pct * 100).round()}%'}'
            : 'TorBox sta preparando il file…',
        pct,
      );
      await Future<void>.delayed(pollInterval);
    }
  }
}
