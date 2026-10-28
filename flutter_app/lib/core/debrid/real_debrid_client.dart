import 'dart:async';

import 'package:dio/dio.dart';

import '../model/stream.dart';
import '../util/app_log.dart';
import '../util/lenient.dart';
import 'debrid_provider.dart';
import 'debrid_resolver.dart';
import 'torbox_client.dart';

/// Real-Debrid (https://api.real-debrid.com/rest/1.0) with the user's own token. Bearer header, form bodies. The
/// `instantAvailability` endpoint is retired, so there is no cache probe: a torrent that is not already in the account needs
/// the viewer's confirmation to be added (which is what [DebridFailure.notCached] triggers in the play flow). Never deletes
/// anything; the token never appears in errors or logs.
class RealDebridClient implements DebridProvider {
  RealDebridClient({
    required this.keyProvider,
    Dio? dio,
    Uri? baseUrl,
    this.pollInterval = const Duration(seconds: 3),
    this.maxWait = const Duration(minutes: 30),
  }) : _dio = dio ?? Dio(),
       base = baseUrl ?? Uri.parse('https://api.real-debrid.com/rest/1.0') {
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 25);
    _dio.options.validateStatus = (_) => true;
  }

  final Future<String?> Function() keyProvider;
  final Dio _dio;
  final Uri base;
  final Duration pollInterval;
  final Duration maxWait;

  @override
  String get name => 'Real-Debrid';

  @override
  Future<Map<String, bool>?> cached(
    List<String> hashes, {
    CancelToken? cancel,
  }) async => null;

  Future<Object?> _send(
    String method,
    String path, {
    Map<String, String>? form,
    CancelToken? cancel,
  }) async {
    final key = (await keyProvider())?.trim() ?? '';
    if (key.isEmpty) {
      throw const DebridException(
        DebridFailure.notConfigured,
        'Manca il token Real-Debrid (Impostazioni ▸ Servizi).',
      );
    }
    final Response<Object?> response;
    try {
      response = await _dio.requestUri<Object?>(
        base.replace(path: '${base.path}$path'),
        data: form,
        cancelToken: cancel,
        options: Options(
          method: method,
          headers: {
            'Authorization': 'Bearer $key',
            'Accept': 'application/json',
          },
          contentType: form == null ? null : Headers.formUrlEncodedContentType,
        ),
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        throw const DebridException(
          DebridFailure.cancelled,
          'Operazione annullata.',
        );
      }
      AppLog.instance.add('realdebrid', 'Errore di rete (${e.type.name})');
      throw const DebridException(
        DebridFailure.unavailable,
        'Real-Debrid non è raggiungibile.',
      );
    }
    final status = response.statusCode ?? 0;
    if (status == 401 || status == 403) {
      throw const DebridException(
        DebridFailure.invalidKey,
        'Real-Debrid non accetta il token (o l’account non è Premium).',
      );
    }
    if (status == 429) {
      throw const DebridException(
        DebridFailure.rateLimited,
        'Real-Debrid: troppe richieste, riprova tra poco.',
      );
    }
    if (status >= 500) {
      throw const DebridException(
        DebridFailure.unavailable,
        'Real-Debrid non risponde.',
      );
    }
    if (status < 200 || status >= 300) {
      throw DebridException(
        DebridFailure.unknown,
        'Real-Debrid ha risposto con errore $status.',
      );
    }
    return response.data;
  }

  /// Account description, or throws.
  Future<String> check() async {
    final user = asMap(await _send('GET', '/user'));
    final premium = asString(user?['type'])?.toLowerCase() == 'premium';
    return premium ? 'Premium' : (asString(user?['type']) ?? 'Free');
  }

  static String? _hashOf(Map<String, Object?> t) =>
      asString(t['hash'])?.toLowerCase();

  @override
  Future<ResolvedLink> resolve(
    AddonStream stream, {
    bool allowDownload = false,
    int? season,
    int? episode,
    void Function(ResolveStatus)? onStatus,
    CancelToken? cancel,
  }) async {
    final hash = stream.infoHash?.toLowerCase();
    if (hash == null) {
      throw const DebridException(
        DebridFailure.unknown,
        'Questa sorgente non è un torrent.',
      );
    }
    void report(String m, [double? f]) =>
        onStatus?.call(ResolveStatus(m, fraction: f));
    void checkCancel() {
      if (cancel?.isCancelled ?? false) {
        throw const DebridException(
          DebridFailure.cancelled,
          'Operazione annullata.',
        );
      }
    }

    report('Controllo Real-Debrid…');
    String? id;
    final list = asList(await _send('GET', '/torrents', cancel: cancel));
    for (final raw in list) {
      final t = asMap(raw);
      if (t != null && _hashOf(t) == hash) {
        id = asNonEmptyString(t['id']);
        break;
      }
    }
    checkCancel();
    if (id == null) {
      if (!allowDownload) {
        throw const DebridException(
          DebridFailure.notCached,
          'Questo torrent non è ancora nel tuo account Real-Debrid.',
        );
      }
      report('Aggiungo il torrent a Real-Debrid…');
      final added = asMap(
        await _send(
          'POST',
          '/torrents/addMagnet',
          form: {'magnet': stream.magnet},
          cancel: cancel,
        ),
      );
      id = asNonEmptyString(added?['id']);
      if (id == null) {
        throw const DebridException(
          DebridFailure.unknown,
          'Real-Debrid non ha restituito l’identificativo del torrent.',
        );
      }
    }
    final started = DateTime.now();
    Map<String, Object?> info = const {};
    var selected = false;
    while (true) {
      checkCancel();
      info =
          asMap(await _send('GET', '/torrents/info/$id', cancel: cancel)) ??
          const {};
      final status = asString(info['status']) ?? 'unknown';
      if (status == 'downloaded') break;
      if (status == 'waiting_files_selection' && !selected) {
        await _send(
          'POST',
          '/torrents/selectFiles/$id',
          form: {'files': 'all'},
          cancel: cancel,
        );
        selected = true;
      }
      if (const ['error', 'virus', 'dead', 'magnet_error'].contains(status)) {
        throw DebridException(
          DebridFailure.notReady,
          'Real-Debrid non può usare questo torrent ($status).',
        );
      }
      if (DateTime.now().difference(started) > maxWait) {
        throw const DebridException(
          DebridFailure.notReady,
          'Real-Debrid sta ancora scaricando: riprova più tardi.',
        );
      }
      final pct = asDouble(info['progress']);
      report(
        'Real-Debrid${pct == null ? '' : ' · ${pct.round()}%'}',
        pct == null ? null : pct / 100,
      );
      await Future<void>.delayed(pollInterval);
    }

    final rawFiles = asList(info['files'])
        .map(asMap)
        .whereType<Map<String, Object?>>()
        .toList();
    final files = [
      for (final f in rawFiles)
        if (asInt(f['id']) != null && asString(f['path']) != null)
          TorBoxFile(
            id: asInt(f['id'])!,
            name: asString(f['path'])!,
            size: asInt(f['bytes']) ?? 0,
          ),
    ];
    final file = TorBoxClient.chooseFile(
      files,
      fileIdx: stream.fileIdx,
      episodeHint: TorBoxClient.episodeHint(season, episode),
    );
    if (file == null) {
      throw DebridException(
        DebridFailure.notReady,
        season != null && episode != null
            ? 'L’episodio S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')} non è nel torrent.'
            : 'Nel torrent non c’è nessun file video.',
      );
    }
    // `links` follows the order of the SELECTED files.
    final chosen = rawFiles.where((f) => asInt(f['selected']) != 0).toList();
    final index = chosen.indexWhere((f) => asInt(f['id']) == file.id);
    final links = asStringList(info['links']);
    if (index < 0 || index >= links.length) {
      throw const DebridException(
        DebridFailure.notReady,
        'Real-Debrid non ha restituito il link del file scelto.',
      );
    }
    report('Ottengo il link…');
    final unrestricted = asMap(
      await _send(
        'POST',
        '/unrestrict/link',
        form: {'link': links[index]},
        cancel: cancel,
      ),
    );
    final url = Uri.tryParse(asString(unrestricted?['download']) ?? '');
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      throw const DebridException(
        DebridFailure.unknown,
        'Link di riproduzione Real-Debrid non valido.',
      );
    }
    return ResolvedLink(url, fileName: file.name);
  }
}
