import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/addons/network_policy.dart';
import '../../core/util/app_log.dart';
import '../../core/util/lenient.dart';
import '../../data/stores.dart';
import '../player/source_check.dart';

enum DownloadStatus { queued, running, paused, failed, done }

/// Another source of the same episode, tried when the current one fails.
class DownloadFallback {
  const DownloadFallback(this.url, {this.headers = const {}, this.resolve});
  final String url;
  final Map<String, String> headers;

  /// For a source that must be prepared first (a torrent through the debrid service): the link is asked for only when this
  /// source is really needed, and null means it could not be had (the next source is tried).
  final Future<({String url, Map<String, String> headers})?> Function()?
  resolve;
}

class DownloadItem {
  DownloadItem({
    required this.id,
    required this.metaId,
    required this.videoId,
    required this.type,
    required this.title,
    required this.url,
    this.poster,
    this.season,
    this.episode,
    this.status = DownloadStatus.queued,
    this.received = 0,
    this.total = 0,
    this.error,
    this.fileName = '',
  });

  final String id;
  final String metaId;
  final String videoId;
  final String type;
  final String title;
  String url;
  final String? poster;
  final int? season;
  final int? episode;
  DownloadStatus status;
  int received;
  int total;
  String? error;
  String fileName;

  /// Request headers the source needs, other sources to try if this one fails, and the retry state. Kept in memory only: they
  /// can carry tokens, so they are never written to the store (after a restart a resumed download uses the plain link).
  Map<String, String> headers = const {};
  List<DownloadFallback> fallbacks = [];
  int retries = 0;
  DateTime? notBefore;

  double? get fraction =>
      total > 0 ? (received / total).clamp(0, 1).toDouble() : null;

  Map<String, Object?> toJson() => {
    'id': id,
    'metaId': metaId,
    'videoId': videoId,
    'type': type,
    'title': title,
    'url': url,
    if (poster != null) 'poster': poster,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
    'status': status.name,
    'received': received,
    'total': total,
    if (error != null) 'error': error,
    'fileName': fileName,
  };

  static DownloadItem? fromJson(Object? raw) {
    final m = asMap(raw);
    final id = asNonEmptyString(m?['id']);
    final url = asNonEmptyString(m?['url']);
    if (m == null || id == null || url == null) return null;
    final status = DownloadStatus.values.firstWhere(
      (s) => s.name == asString(m['status']),
      orElse: () => DownloadStatus.paused,
    );
    return DownloadItem(
      id: id,
      metaId: asString(m['metaId']) ?? '',
      videoId: asString(m['videoId']) ?? '',
      type: asString(m['type']) ?? 'movie',
      title: asString(m['title']) ?? id,
      url: url,
      poster: asNonEmptyString(m['poster']),
      season: asInt(m['season']),
      episode: asInt(m['episode']),
      // A download that was running when the app closed is only paused now: it resumes where it stopped.
      status:
          (status == DownloadStatus.running || status == DownloadStatus.queued)
          ? DownloadStatus.paused
          : status,
      received: asInt(m['received']) ?? 0,
      total: asInt(m['total']) ?? 0,
      error: asNonEmptyString(m['error']),
      fileName: asString(m['fileName']) ?? '',
    );
  }
}

/// Direct-link downloads for offline viewing. One file per item in [directory]; partial files (`.part`) resume with an HTTP
/// Range request when the server supports it, otherwise restart. State survives a restart.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required KeyValueStore store,
    required this.directory,
    Dio? dio,
    NetworkPolicy policy = const NetworkPolicy(),
  }) : _store = store,
       _dio = dio ?? Dio(),
       _policy = policy;

  static const _key = 'downloads.v1';
  final KeyValueStore _store;
  final Directory directory;
  final Dio _dio;
  NetworkPolicy _policy;
  final List<DownloadItem> _items = [];
  final Map<String, CancelToken> _tokens = {};

  set policy(NetworkPolicy p) => _policy = p;

  /// How many transfers run at once; the others wait as «in coda».
  int maxConcurrent = 2;

  /// Seconds to wait before each retry of a 5xx / 429 answer.
  List<int> retryWaits = const [3, 8, 20];
  bool allowCellular = false;

  /// Asked before a transfer starts; false keeps it queued (for example: only on Wi-Fi).
  Future<bool> Function()? networkAllowed;

  Future<void> _pump() async {
    for (final item
        in _items.where((i) => i.status == DownloadStatus.queued).toList()) {
      final running = _items
          .where((i) => i.status == DownloadStatus.running)
          .length;
      if (running >= maxConcurrent) return;
      final wait = item.notBefore;
      if (wait != null && wait.isAfter(DateTime.now())) continue;
      if (networkAllowed != null && !await networkAllowed!()) {
        item.error = 'In attesa del Wi-Fi';
        notifyListeners();
        return;
      }
      item.error = null;
      unawaited(_run(item));
    }
  }

  /// Removes the finished download of a video (used by «Elimina i download dopo la visione»).
  Future<void> removeIfDone(String videoId) async {
    final i = byVideo(videoId);
    if (i != null && i.status == DownloadStatus.done) await remove(i.id);
  }

  List<DownloadItem> get items => List.unmodifiable(_items);
  DownloadItem? byVideo(String videoId) {
    for (final i in _items) {
      if (i.videoId == videoId) return i;
    }
    return null;
  }

  Future<void> load() async {
    final raw = await _store.read(_key);
    if (raw == null) return;
    try {
      for (final item in asList(jsonDecode(raw))) {
        final d = DownloadItem.fromJson(item);
        if (d == null) continue;
        if (d.status == DownloadStatus.done && !await File(pathOf(d)).exists())
          continue; // file removed from outside
        _items.add(d);
      }
    } on FormatException {
      // damaged list: start empty
    }
  }

  Future<void> _save() =>
      _store.write(_key, jsonEncode(_items.map((e) => e.toJson()).toList()));

  String pathOf(DownloadItem item) =>
      '${directory.path}/${item.id}${_ext(item)}';
  String _partPath(DownloadItem item) => '${pathOf(item)}.part';

  static String _ext(DownloadItem item) {
    final name = item.fileName.isNotEmpty
        ? item.fileName
        : (Uri.tryParse(item.url)?.pathSegments.lastOrNull ?? '');
    final m = RegExp(r'\.([A-Za-z0-9]{2,4})$').firstMatch(name);
    return m == null ? '.mp4' : '.${m.group(1)!.toLowerCase()}';
  }

  /// Local file of a finished download, or null.
  String? localPath(String videoId) {
    final d = byVideo(videoId);
    return (d != null && d.status == DownloadStatus.done) ? pathOf(d) : null;
  }

  Future<DownloadItem> enqueue({
    required String metaId,
    required String videoId,
    required String type,
    required String title,
    required String url,
    String? poster,
    int? season,
    int? episode,
    String? fileName,
    Map<String, String> headers = const {},
    List<DownloadFallback> fallbacks = const [],
  }) async {
    final problem = _policy.reject(Uri.parse(url));
    if (problem != null) throw FormatException(problem);
    final existing = byVideo(videoId);
    if (existing != null && existing.status != DownloadStatus.failed)
      return existing;
    if (existing != null) _items.remove(existing);
    final item =
        DownloadItem(
            id: '${DateTime.now().microsecondsSinceEpoch}',
            metaId: metaId,
            videoId: videoId,
            type: type,
            title: title,
            url: url,
            poster: poster,
            season: season,
            episode: episode,
            fileName: fileName ?? '',
          )
          ..headers = headers
          ..fallbacks = [...fallbacks];
    _items.add(item);
    await _save();
    notifyListeners();
    unawaited(_pump());
    return item;
  }

  Future<void> resume(String id) async {
    final item = _items.firstWhere((i) => i.id == id);
    if (item.status == DownloadStatus.running ||
        item.status == DownloadStatus.done)
      return;
    item.status = DownloadStatus.queued;
    notifyListeners();
    unawaited(_pump());
  }

  Future<void> pause(String id) async {
    _tokens[id]?.cancel('pause');
  }

  Future<void> remove(String id) async {
    _tokens[id]?.cancel('remove');
    final item = _items.firstWhere(
      (i) => i.id == id,
      orElse: () => throw StateError('unknown download'),
    );
    _items.remove(item);
    for (final p in [pathOf(item), _partPath(item)]) {
      final f = File(p);
      if (await f.exists()) await f.delete();
    }
    await _save();
    notifyListeners();
  }

  /// Free space is not exposed by dart:io portably; the size on disk of all downloads is.
  Future<int> bytesOnDisk() async {
    var sum = 0;
    if (!await directory.exists()) return 0;
    await for (final e in directory.list()) {
      if (e is File) sum += await e.length();
    }
    return sum;
  }

  /// A 5xx is often transient (twice, with a pause); otherwise the next source of the same episode, if any; otherwise it fails.
  Future<void> _recover(
    DownloadItem item,
    String message, {
    int? status,
  }) async {
    final part = File(_partPath(item));
    Future<void> reset() async {
      item.received = 0;
      item.total = 0;
      if (await part.exists()) await part.delete();
    }

    final waits = retryWaits;
    if (status != null &&
        (status >= 500 || status == 429) &&
        item.retries < waits.length) {
      final wait = waits[item.retries];
      item.retries++;
      await reset();
      item.status = DownloadStatus.queued;
      item.error =
          'Server temporaneamente non disponibile (HTTP $status); nuovo tentativo ${item.retries}/${waits.length}…';
      item.notBefore = DateTime.now().add(Duration(seconds: wait));
      Timer(Duration(seconds: wait), () => unawaited(_pump()));
      return;
    }
    while (item.fallbacks.isNotEmpty) {
      final next = item.fallbacks.removeAt(0);
      var url = next.url;
      var headers = next.headers;
      if (next.resolve != null) {
        try {
          final r = await next.resolve!();
          if (r == null) continue;
          url = r.url;
          headers = r.headers;
        } on Object {
          continue;
        }
      }
      await reset();
      item
        ..url = url
        ..headers = headers
        ..retries = 0
        ..notBefore = null
        ..status = DownloadStatus.queued
        ..error =
            'Sorgente precedente non disponibile; provo un\'altra sorgente.';
      return;
    }
    item.status = DownloadStatus.failed;
    item.error = message;
  }

  Future<void> _run(DownloadItem item) async {
    if (_tokens.containsKey(item.id)) return;
    final token = CancelToken();
    _tokens[item.id] = token;
    item.status = DownloadStatus.running;
    item.error = null;
    notifyListeners();
    IOSink? sink;
    try {
      await directory.create(recursive: true);
      final part = File(_partPath(item));
      var offset = await part.exists() ? await part.length() : 0;
      final response = await _dio.get<ResponseBody>(
        item.url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            // Many CDNs and debrid gateways answer 503/403 to the default Dart client.
            if (!item.headers.keys.any((k) => k.toLowerCase() == 'user-agent'))
              'User-Agent': 'Aether/1.0',
            ...item.headers,
            if (offset > 0) 'Range': 'bytes=$offset-',
          },
          validateStatus: (_) => true,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == 416 && offset > 0) {
        // The partial file is already complete (or stale): finish it.
        await part.rename(pathOf(item));
        item.status = DownloadStatus.done;
        item.received = offset;
        item.total = offset;
        return;
      }
      final contentType = (response.headers.value('content-type') ?? '')
          .toLowerCase();
      final textual =
          contentType.contains('text/') ||
          contentType.contains('json') ||
          contentType.contains('html');
      if ((status != 200 && status != 206) || textual) {
        // An error page or a «playback unavailable» message: read it, so the reason can be shown and the next source tried.
        final head = <int>[];
        await for (final c in response.data!.stream) {
          head.addAll(c);
          if (head.length >= 1024) break;
        }
        throw _HttpFailure(
          (status == 200 || status == 206) ? 415 : status,
          textSnippet(head),
        );
      }
      if (status == 200) offset = 0; // no range support: start again
      final length =
          int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '',
          ) ??
          0;
      item.total = length > 0 ? length + offset : 0;
      item.received = offset;
      sink = part.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var lastNotify = DateTime.now();
      await for (final chunk in response.data!.stream) {
        sink.add(chunk);
        item.received += chunk.length;
        if (DateTime.now().difference(lastNotify).inMilliseconds > 400) {
          lastNotify = DateTime.now();
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (item.total > 0 && item.received < item.total)
        throw const HttpException('Download interrotto dal server.');
      await part.rename(pathOf(item));
      item.total = item.received;
      item.status = DownloadStatus.done;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        item.status = DownloadStatus.paused;
      } else {
        AppLog.instance.add('download', 'Errore di rete (${e.type.name})');
        await _recover(item, 'Connessione interrotta: riprova.');
      }
    } on _HttpFailure catch (e) {
      AppLog.instance.add('download', 'HTTP ${e.status} ${e.detail ?? ''}');
      await _recover(
        item,
        e.status == 415
            ? explainBadAnswer(200, e.detail)
            : explainBadAnswer(e.status, e.detail),
        status: e.status,
      );
    } on Object catch (e) {
      AppLog.instance.add('download', 'Errore: ${e.runtimeType}');
      await _recover(
        item,
        e is HttpException ? e.message : 'Download non riuscito.',
      );
    } finally {
      await sink?.close();
      _tokens.remove(item.id);
      await _save();
      notifyListeners();
      unawaited(_pump());
    }
  }
}

class _HttpFailure implements Exception {
  const _HttpFailure(this.status, [this.detail]);
  final int status;
  final String? detail;
}
