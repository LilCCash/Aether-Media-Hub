import 'package:dio/dio.dart';

import '../util/lenient.dart';
import 'service_http.dart';

class TvdbEpisode {
  const TvdbEpisode({
    required this.season,
    required this.number,
    this.name,
    this.overview,
    this.image,
  });
  final int season;
  final int number;
  final String? name;
  final String? overview;
  final String? image;
}

/// TheTVDB v4 with the user's own project key (and subscriber PIN, if the key needs one). `POST /login` answers
/// `data.token`; the token is kept in memory only. The data paths follow the public v4 documentation; decoding is tolerant, a
/// failure only means "no extra data". Used to translate episode titles and overviews.
class TvdbClient {
  TvdbClient({
    required this.keyProvider,
    required this.pinProvider,
    Dio? dio,
    Uri? baseUrl,
  }) : _http = ServiceHttp(dio: dio, timeout: const Duration(seconds: 15)),
       base = baseUrl ?? Uri.parse('https://api4.thetvdb.com/v4');

  final Future<String?> Function() keyProvider;
  final Future<String?> Function() pinProvider;
  final ServiceHttp _http;
  final Uri base;
  String? _token;
  String? _tokenFor;

  Uri _uri(String path, [Map<String, String>? q]) =>
      base.replace(path: '${base.path}$path', queryParameters: q);

  Future<String?> _login(String key, String? pin) async {
    final reply = await _http.send(
      'tvdb',
      _uri('/login'),
      method: 'POST',
      data: {'apikey': key, if (pin != null) 'pin': pin},
      contentType: 'application/json',
    );
    if (reply == null || !reply.ok) return null;
    final token = asNonEmptyString(asMap(asMap(reply.body)?['data'])?['token']);
    if (token != null) {
      _token = token;
      _tokenFor = '$key\n${pin ?? ''}';
    }
    return token;
  }

  Future<ServiceReply?> _get(
    String path, {
    Map<String, String>? query,
    CancelToken? cancel,
  }) async {
    final key = (await keyProvider())?.trim() ?? '';
    if (key.isEmpty) return null;
    final rawPin = (await pinProvider())?.trim();
    final pin = (rawPin == null || rawPin.isEmpty) ? null : rawPin;
    final fingerprint = '$key\n${pin ?? ''}';
    for (var attempt = 0; attempt < 2; attempt++) {
      var token = _tokenFor == fingerprint ? _token : null;
      token ??= await _login(key, pin);
      if (token == null) return null;
      final reply = await _http.send(
        'tvdb',
        _uri(path, query),
        headers: {'Authorization': 'Bearer $token'},
        cancel: cancel,
      );
      if (reply != null && reply.status == 401 && attempt == 0) {
        _token = null; // expired or revoked: log in once more
        continue;
      }
      return reply;
    }
    return null;
  }

  /// Null when the key logs in, else a reason.
  Future<String?> check() async {
    final key = (await keyProvider())?.trim() ?? '';
    if (key.isEmpty) return 'Manca la chiave TheTVDB.';
    final rawPin = (await pinProvider())?.trim();
    final token = await _login(
      key,
      (rawPin == null || rawPin.isEmpty) ? null : rawPin,
    );
    return token == null
        ? 'TheTVDB non accetta la chiave (o non risponde).'
        : null;
  }

  Future<int?> seriesIdForImdb(String imdb, {CancelToken? cancel}) async {
    final reply = await _get('/search/remoteid/$imdb', cancel: cancel);
    if (reply == null || !reply.ok) return null;
    for (final e in asList(asMap(reply.body)?['data'])) {
      final id = asInt(asMap(asMap(e)?['series'])?['id']);
      if (id != null) return id;
    }
    return null;
  }

  /// Episodes with titles translated into [language] (ISO 639-2, e.g. "ita"), up to 4 pages.
  Future<List<TvdbEpisode>> episodes(
    int seriesId,
    String language, {
    CancelToken? cancel,
  }) async {
    final result = <TvdbEpisode>[];
    for (var page = 0; page < 4; page++) {
      final reply = await _get(
        '/series/$seriesId/episodes/default/$language',
        query: {'page': '$page'},
        cancel: cancel,
      );
      if (reply == null || !reply.ok) break;
      final body = asMap(reply.body);
      for (final raw in asList(asMap(body?['data'])?['episodes'])) {
        final m = asMap(raw);
        final s = asInt(m?['seasonNumber']);
        final n = asInt(m?['number']);
        if (m == null || s == null || n == null) continue;
        result.add(
          TvdbEpisode(
            season: s,
            number: n,
            name: asNonEmptyString(m['name']),
            overview: asNonEmptyString(m['overview']),
            image: asNonEmptyString(m['image']),
          ),
        );
      }
      final next = asNonEmptyString(asMap(body?['links'])?['next']);
      if (next == null) break;
    }
    return result;
  }
}
