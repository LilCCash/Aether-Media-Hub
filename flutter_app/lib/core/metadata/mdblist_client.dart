import 'package:dio/dio.dart';

import '../util/lenient.dart';
import 'service_http.dart';

/// One rating of a title, as MDBList reports it.
class MdbRating {
  const MdbRating(this.source, {this.value, this.score, this.votes});
  final String source;
  final double? value;
  final double? score; // 0–100 when MDBList gives it
  final int? votes;

  static const titles = {
    'imdb': 'IMDb',
    'tmdb': 'TMDB',
    'tomatoes': 'Rotten Tomatoes',
    'tomatoesaudience': 'Pubblico RT',
    'metacritic': 'Metacritic',
    'metacriticuser': 'Metacritic utenti',
    'trakt': 'Trakt',
    'letterboxd': 'Letterboxd',
    'rogerebert': 'Roger Ebert',
    'myanimelist': 'MyAnimeList',
  };

  String get title => titles[source] ?? source;

  /// "7.7", "92%" or "81", written the way each service writes its own scale.
  String? get display {
    switch (source) {
      case 'tomatoes':
      case 'tomatoesaudience':
      case 'trakt':
        final n = score ?? value;
        return n == null ? null : '${n.round()}%';
      case 'metacritic':
        final n = value ?? score;
        return n == null ? null : '${n.round()}';
      default:
        if (value != null) {
          return value! <= 10 ? value!.toStringAsFixed(1) : '${value!.round()}';
        }
        return score == null ? null : '${score!.round()}';
    }
  }

  static String canonical(String raw) {
    switch (raw.toLowerCase()) {
      case 'rottentomatoes':
      case 'rotten_tomatoes':
      case 'tomatoes':
        return 'tomatoes';
      case 'popcorn':
      case 'audience':
      case 'tomatoesaudience':
      case 'tomatoes_audience':
        return 'tomatoesaudience';
      case 'metacritic_user':
      case 'metacriticuser':
        return 'metacriticuser';
      case 'mal':
      case 'myanimelist':
        return 'myanimelist';
      default:
        return raw.toLowerCase();
    }
  }
}

/// MDBList (api.mdblist.com) with the user's own key: the ratings of a title from several services at once.
class MdbListClient {
  MdbListClient({required this.keyProvider, Dio? dio, Uri? baseUrl})
    : _http = ServiceHttp(dio: dio),
      base = baseUrl ?? Uri.parse('https://api.mdblist.com');

  final Future<String?> Function() keyProvider;
  final ServiceHttp _http;
  final Uri base;

  Future<ServiceReply?> _get(String path, {CancelToken? cancel}) async {
    final key = (await keyProvider())?.trim() ?? '';
    if (key.isEmpty) return null;
    return _http.send(
      'mdblist',
      base.replace(path: path, queryParameters: {'apikey': key}),
      cancel: cancel,
    );
  }

  /// Empty without a key or on any failure.
  Future<List<MdbRating>> ratings(
    int tmdbId, {
    required bool isMovie,
    CancelToken? cancel,
  }) async {
    final reply = await _get(
      '/tmdb/${isMovie ? 'movie' : 'show'}/$tmdbId',
      cancel: cancel,
    );
    if (reply == null || !reply.ok) return const [];
    return parse(reply.body);
  }

  static List<MdbRating> parse(Object? body) {
    final seen = <String>{};
    final result = <MdbRating>[];
    for (final raw in asList(asMap(body)?['ratings'])) {
      final m = asMap(raw);
      final src = asNonEmptyString(m?['source']);
      if (m == null || src == null) continue;
      final source = MdbRating.canonical(src);
      if (!seen.add(source)) continue;
      final r = MdbRating(
        source,
        value: asDouble(m['value']),
        score: asDouble(m['score']),
        votes: asInt(m['votes']),
      );
      if (r.display != null) result.add(r);
    }
    return result;
  }

  /// Null when the key is accepted, else a reason.
  Future<String?> check() async {
    if (((await keyProvider())?.trim() ?? '').isEmpty) {
      return 'Manca la chiave MDBList.';
    }
    final reply = await _get('/user');
    if (reply == null) return 'MDBList non risponde.';
    if (reply.status == 401 || reply.status == 403) {
      return 'MDBList non accetta la chiave.';
    }
    return reply.ok ? null : 'MDBList ha risposto con errore ${reply.status}.';
  }
}
