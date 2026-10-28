import 'dart:convert';

import 'package:dio/dio.dart';

import '../util/app_log.dart';
import '../util/lenient.dart';

enum DebridFailure { notConfigured, invalidKey, planRequired, rateLimited, notCached, unavailable, notReady, cancelled, unknown }

class DebridException implements Exception {
  const DebridException(this.failure, this.message);
  final DebridFailure failure;
  final String message;
  @override
  String toString() => message;
}

class TorBoxFile {
  const TorBoxFile({required this.id, required this.name, required this.size});
  final int id;
  final String name;
  final int size;

  bool get isVideo => RegExp(r'\.(mkv|mp4|avi|mov|m4v|webm|ts|wmv)$', caseSensitive: false).hasMatch(name);
}

class TorBoxTorrent {
  const TorBoxTorrent({required this.id, required this.hash, required this.name, required this.finished, required this.present, required this.progress, this.files = const []});
  final int id;
  final String hash;
  final String name;
  final bool finished;
  final bool present;
  final double progress;
  final List<TorBoxFile> files;
  bool get ready => finished && present;
}

/// TorBox API client (https://api.torbox.app/v1/api). Behaviour follows `docs/research/torbox-api.md` of the repository, which
/// records what was read from TorBox's own SDK/OpenAPI and from third-party clients. The key is read from [keyProvider] on
/// every call and never appears in an error message or a log line. Never deletes or modifies the user's existing items.
class TorBoxClient {
  TorBoxClient({required this.keyProvider, Dio? dio, Uri? baseUrl})
      : _dio = dio ?? Dio(),
        base = baseUrl ?? Uri.parse('https://api.torbox.app/v1/api') {
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 25);
    _dio.options.validateStatus = (_) => true;
  }

  final Future<String?> Function() keyProvider;
  final Dio _dio;
  final Uri base;

  Future<String> _key() async {
    final key = (await keyProvider())?.trim();
    if (key == null || key.isEmpty) throw const DebridException(DebridFailure.notConfigured, 'Manca la chiave TorBox (Impostazioni ▸ Servizi).');
    return key;
  }

  Uri _uri(String path, [Map<String, String>? query]) => base.replace(path: '${base.path}/$path', queryParameters: query);

  Future<Map<String, Object?>> _send(String method, Uri uri, {Object? data, String? contentType, bool auth = true, CancelToken? cancel}) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (auth) headers['Authorization'] = 'Bearer ${await _key()}';
    try {
      final response = await _dio.requestUri<Object?>(uri, data: data, cancelToken: cancel, options: Options(method: method, headers: headers, contentType: contentType, responseType: ResponseType.plain));
      final status = response.statusCode ?? 0;
      Map<String, Object?> body = const {};
      final raw = response.data;
      if (raw is Map) {
        body = asMap(raw) ?? const {};
      } else if (raw is String && raw.isNotEmpty) {
        try {
          body = asMap(jsonDecode(raw)) ?? const {};
        } on FormatException {
          body = const {}; // HTML / text error pages are common on gateway failures
        }
      }
      final code = asString(body['error']);
      if (status == 401 || status == 403 || code == 'AUTH_ERROR') throw const DebridException(DebridFailure.invalidKey, 'TorBox non accetta la chiave.');
      if (status == 429) throw const DebridException(DebridFailure.rateLimited, 'Troppe richieste a TorBox: riprova tra un minuto.');
      if (status == 409) throw const DebridException(DebridFailure.notCached, 'Il contenuto non è nella cache di TorBox.');
      if (code == 'PLAN_RESTRICTED_FEATURE') throw const DebridException(DebridFailure.planRequired, 'Il tuo piano TorBox non consente questa funzione.');
      if (status >= 500 || status == 0) throw DebridException(DebridFailure.unavailable, 'TorBox non è raggiungibile ($status).');
      if (status >= 400 && body['success'] != true) throw DebridException(DebridFailure.unknown, asString(body['detail']) ?? 'TorBox ha risposto $status.');
      return body;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) throw const DebridException(DebridFailure.cancelled, 'Operazione annullata.');
      AppLog.instance.add('torbox', 'Errore di rete (${e.type.name})');
      throw const DebridException(DebridFailure.unavailable, 'Non riesco a contattare TorBox: controlla la connessione.');
    }
  }

  /// Verifies the key (`user/me`) and returns the plan name when TorBox gives one.
  Future<String?> check({CancelToken? cancel}) async {
    final body = await _send('GET', _uri('user/me'), cancel: cancel);
    final data = asMap(body['data']);
    final plan = asInt(data?['plan']);
    return plan == null ? 'attivo' : 'piano $plan';
  }

  /// `hash -> cached`. At most 100 hashes per request; a hash missing from the answer is "not cached" (never an error).
  Future<Map<String, bool>> checkCached(List<String> hashes, {CancelToken? cancel}) async {
    final result = <String, bool>{};
    final unique = hashes.map((h) => h.toLowerCase()).where((h) => RegExp(r'^[0-9a-f]{40}$').hasMatch(h)).toSet().toList();
    for (var i = 0; i < unique.length; i += 100) {
      final chunk = unique.sublist(i, i + 100 > unique.length ? unique.length : i + 100);
      final body = await _send('POST', _uri('torrents/checkcached', {'format': 'list', 'list_files': 'false'}),
          data: jsonEncode({'hashes': chunk}), contentType: 'application/json', cancel: cancel);
      final cached = <String>{};
      final data = body['data'];
      if (data is List) {
        for (final item in data) {
          final hash = asString(asMap(item)?['hash'])?.toLowerCase();
          if (hash != null) cached.add(hash);
        }
      } else if (data is Map) {
        cached.addAll(data.keys.map((k) => k.toString().toLowerCase()));
      }
      for (final h in chunk) {
        result[h] = cached.contains(h);
      }
    }
    return result;
  }

  /// Adds a torrent to the account. With [onlyIfCached] TorBox refuses (HTTP 409) anything not already in its cache, so
  /// nothing new is downloaded. Returns the torrent id.
  Future<int> addMagnet(String magnet, {bool onlyIfCached = true, CancelToken? cancel}) async {
    final form = FormData.fromMap({'magnet': magnet, 'allow_zip': 'false', 'add_only_if_cached': onlyIfCached.toString()});
    final body = await _send('POST', _uri('torrents/createtorrent'), data: form, cancel: cancel);
    final data = asMap(body['data']);
    final id = asInt(data?['torrent_id']) ?? asInt(data?['queued_id']);
    if (id == null) throw const DebridException(DebridFailure.notReady, 'TorBox non ha restituito l’elemento aggiunto.');
    return id;
  }

  Future<TorBoxTorrent?> torrent(int id, {CancelToken? cancel}) async {
    final body = await _send('GET', _uri('torrents/mylist', {'id': '$id', 'bypass_cache': 'true'}), cancel: cancel);
    final raw = body['data'];
    final item = raw is List ? (raw.isEmpty ? null : asMap(raw.first)) : asMap(raw);
    if (item == null) return null;
    final files = <TorBoxFile>[];
    for (final f in asList(item['files'])) {
      final m = asMap(f);
      final fid = asInt(m?['id']);
      if (m != null && fid != null) files.add(TorBoxFile(id: fid, name: asString(m['name']) ?? asString(m['short_name']) ?? '$fid', size: asInt(m['size']) ?? 0));
    }
    return TorBoxTorrent(
      id: id,
      hash: asString(item['hash'])?.toLowerCase() ?? '',
      name: asString(item['name']) ?? '',
      finished: asBool(item['download_finished']),
      present: asBool(item['download_present']),
      progress: (asDouble(item['progress']) ?? 0).clamp(0, 1).toDouble(),
      files: files,
    );
  }

  /// The id of an item already in the account for this hash, or null (avoids duplicates).
  Future<int?> findByHash(String hash, {CancelToken? cancel}) async {
    final body = await _send('GET', _uri('torrents/mylist', {'bypass_cache': 'true'}), cancel: cancel);
    final raw = body['data'];
    if (raw is! List) return null;
    for (final item in raw) {
      final m = asMap(item);
      if (asString(m?['hash'])?.toLowerCase() == hash.toLowerCase()) return asInt(m?['id']);
    }
    return null;
  }

  /// A temporary download link for one file (`requestdl`: the key goes in the `token` query, as TorBox requires).
  Future<Uri> requestLink(int torrentId, int fileId, {CancelToken? cancel}) async {
    final key = await _key();
    final body = await _send('GET', _uri('torrents/requestdl', {'token': key, 'torrent_id': '$torrentId', 'file_id': '$fileId'}), auth: false, cancel: cancel);
    final link = asNonEmptyString(body['data']);
    final uri = link == null ? null : Uri.tryParse(link);
    if (uri == null || uri.scheme != 'https') throw const DebridException(DebridFailure.notReady, 'TorBox non ha restituito un link valido.');
    return uri;
  }

  /// Picks the file to play: the file whose name matches the stream's `fileIdx` order, else the biggest video.
  static TorBoxFile? chooseFile(List<TorBoxFile> files, {int? fileIdx, String? season, String? episodeHint}) {
    final videos = files.where((f) => f.isVideo).toList();
    if (videos.isEmpty) return null;
    if (episodeHint != null) {
      final match = videos.where((f) => f.name.toLowerCase().contains(episodeHint.toLowerCase())).toList()..sort((a, b) => b.size.compareTo(a.size));
      if (match.isNotEmpty) return match.first;
    }
    if (fileIdx != null && fileIdx >= 0 && fileIdx < files.length && files[fileIdx].isVideo) return files[fileIdx];
    videos.sort((a, b) => b.size.compareTo(a.size));
    return videos.first;
  }

  /// "S01E02"-style hints used by [chooseFile] for series packs.
  static String? episodeHint(int? season, int? episode) =>
      (season == null || episode == null) ? null : 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
}
