import 'dart:convert';

import 'package:dio/dio.dart';

import '../model/manifest.dart';
import '../model/meta.dart';
import '../model/stream.dart';
import '../util/app_log.dart';
import '../util/lenient.dart';
import 'network_policy.dart';

class AddonException implements Exception {
  const AddonException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

class CatalogPage {
  const CatalogPage(this.items, {this.cacheMaxAge});
  final List<MetaItem> items;
  final int? cacheMaxAge;
}

/// Talks the Stremio addon protocol (https://stremio.github.io/stremio-addon-sdk/protocol.html): GET `{base}/{resource}/{type}/{id}[/{extra}].json`.
/// Every call has a timeout, can be cancelled and is limited in size; answers are read tolerantly.
class AddonClient {
  AddonClient({
    Dio? dio,
    NetworkPolicy policy = const NetworkPolicy(),
    this.maxBytes = 6 * 1024 * 1024,
  }) : _dio = dio ?? Dio(),
       _policy = policy {
    final options = _dio.options;
    options.connectTimeout = const Duration(seconds: 10);
    options.receiveTimeout = const Duration(seconds: 20);
    options.sendTimeout = const Duration(seconds: 10);
    options.responseType = ResponseType.bytes;
    options.followRedirects = true;
    options.maxRedirects = 4;
    options.validateStatus = (_) => true;
    options.headers['Accept'] = 'application/json';
  }

  final Dio _dio;
  NetworkPolicy _policy;
  final int maxBytes;
  final Map<String, _Cached> _cache = {};

  set policy(NetworkPolicy value) => _policy = value;

  /// Pure: the request address of a resource (exposed for tests).
  static Uri resourceUri(
    Uri base,
    String resource,
    String type,
    String id, {
    Map<String, String> extra = const {},
  }) {
    final extraPart = extra.isEmpty
        ? ''
        : '/${extra.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}';
    final path =
        '${base.path}/$resource/${Uri.encodeComponent(type)}/${Uri.encodeComponent(id)}$extraPart.json';
    return base.replace(path: path, query: null);
  }

  Future<AddonManifest> fetchManifest(Uri base, {CancelToken? cancel}) async {
    final json = await _getJson(
      AddonUrl.manifest(base),
      cancel: cancel,
      useCache: false,
    );
    try {
      return AddonManifest.parse(json);
    } on FormatException catch (e) {
      throw AddonException('Manifest non valido: ${e.message}');
    }
  }

  Future<CatalogPage> catalog(
    Uri base,
    ManifestCatalog catalog, {
    Map<String, String> extra = const {},
    CancelToken? cancel,
  }) async {
    final uri = resourceUri(
      base,
      'catalog',
      catalog.type,
      catalog.id,
      extra: extra,
    );
    final json = asMap(await _getJson(uri, cancel: cancel));
    final items = <MetaItem>[];
    for (final raw in asList(json?['metas'])) {
      final item = MetaItem.parse(raw, fallbackType: catalog.type);
      if (item != null) items.add(item);
    }
    return CatalogPage(items, cacheMaxAge: asInt(json?['cacheMaxAge']));
  }

  Future<MetaItem?> meta(
    Uri base,
    String type,
    String id, {
    CancelToken? cancel,
  }) async {
    final json = asMap(
      await _getJson(resourceUri(base, 'meta', type, id), cancel: cancel),
    );
    return MetaItem.parse(json?['meta'], fallbackType: type);
  }

  Future<List<AddonStream>> streams(
    Uri base,
    String type,
    String videoId, {
    String? addonId,
    String? addonName,
    CancelToken? cancel,
  }) async {
    final json = asMap(
      await _getJson(
        resourceUri(base, 'stream', type, videoId),
        cancel: cancel,
      ),
    );
    final result = <AddonStream>[];
    for (final raw in asList(json?['streams'])) {
      final s = AddonStream.parse(raw, addonId: addonId, addonName: addonName);
      if (s != null) result.add(s);
    }
    return result;
  }

  Future<List<AddonSubtitle>> subtitles(
    Uri base,
    String type,
    String videoId, {
    String? addonName,
    CancelToken? cancel,
    Map<String, String> extra = const {},
  }) async {
    final json = asMap(
      await _getJson(
        resourceUri(base, 'subtitles', type, videoId, extra: extra),
        cancel: cancel,
      ),
    );
    final result = <AddonSubtitle>[];
    for (final raw in asList(json?['subtitles'])) {
      final s = AddonSubtitle.parse(raw, addonName: addonName);
      if (s != null) result.add(s);
    }
    return result;
  }

  Future<Object?> _getJson(
    Uri uri, {
    CancelToken? cancel,
    bool useCache = true,
  }) async {
    final problem = _policy.reject(uri);
    if (problem != null) throw AddonException(problem);
    final now = DateTime.now();
    final cached = _cache[uri.toString()];
    useCache = useCache && cacheEnabled;
    if (useCache && cached != null && cached.expires.isAfter(now)) {
      return cached.json;
    }
    try {
      final response = await _dio.getUri<List<int>>(uri, cancelToken: cancel);
      final status = response.statusCode ?? 0;
      final bytes = response.data ?? const <int>[];
      if (status < 200 || status >= 300) {
        AppLog.instance.add('addon', 'HTTP $status per $uri');
        throw AddonException(
          status >= 500
              ? 'L’addon ha risposto con un errore del server ($status).'
              : 'L’addon ha risposto $status.',
          retryable: status >= 500 || status == 429,
        );
      }
      if (bytes.length > maxBytes) {
        throw const AddonException('La risposta dell’addon è troppo grande.');
      }
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      } on FormatException {
        throw const AddonException('L’addon non ha risposto con JSON valido.');
      }
      final maxAge = asInt(asMap(json)?['cacheMaxAge']) ?? 60;
      if (useCache && maxAge > 0) {
        _cache[uri.toString()] = _Cached(
          json,
          now.add(
            Duration(
              seconds: (maxAge < minCacheSeconds ? minCacheSeconds : maxAge)
                  .clamp(1, 7200),
            ),
          ),
        );
      }
      return json;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        throw const AddonException('Richiesta annullata.');
      }
      AppLog.instance.add('addon', 'Errore di rete per $uri: ${e.type.name}');
      final timeout =
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout;
      throw AddonException(
        timeout
            ? 'L’addon non risponde (tempo scaduto).'
            : 'Impossibile contattare l’addon: controlla la connessione.',
        retryable: true,
      );
    }
  }

  void clearCache() => _cache.clear();

  /// Settings ▸ Metadati: «Salva in cache» off disables the cache; «Aggiorna ogni N minuti» is the least time an answer is kept.
  bool cacheEnabled = true;
  int minCacheSeconds = 0;
}

class _Cached {
  _Cached(this.json, this.expires);
  final Object? json;
  final DateTime expires;
}
