import 'package:dio/dio.dart';

import '../util/app_log.dart';
import '../util/lenient.dart';

class CastMember {
  const CastMember({required this.name, this.role, this.photo, this.tmdbId});
  final String name;
  final String? role;
  final String? photo;
  final int? tmdbId;
}

class RichDetails {
  const RichDetails({
    this.tmdbId,
    this.cast = const [],
    this.trailers = const [],
    this.companies = const [],
    this.overview,
    this.tagline,
    this.budget,
    this.revenue,
    this.voteAverage,
    this.collectionName,
    this.similar = const [],
  });
  final int? tmdbId;
  final List<CastMember> cast;
  final List<String> trailers; // YouTube keys
  final List<String> companies;
  final String? overview;
  final String? tagline;
  final int? budget;
  final int? revenue;
  final double? voteAverage;
  final String? collectionName;
  final List<String> similar;
}

class PersonCredit {
  const PersonCredit({
    required this.title,
    this.role,
    this.year,
    this.poster,
    required this.isMovie,
    required this.tmdbId,
    this.popularity = 0,
  });
  final String title;
  final String? role;
  final String? year;
  final String? poster;
  final bool isMovie;
  final int tmdbId;
  final double popularity;
}

/// TMDB v3 client. The user's own key (v3 `api_key`, or a v4 read token, which starts with "eyJ") comes from [keyProvider].
/// Attribution required by TMDB: "This product uses the TMDB API but is not endorsed or certified by TMDB."
class TmdbClient {
  TmdbClient({required this.keyProvider, Dio? dio, Uri? baseUrl})
    : _dio = dio ?? Dio(),
      base = baseUrl ?? Uri.parse('https://api.themoviedb.org/3') {
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 15);
    _dio.options.validateStatus = (_) => true;
  }

  final Future<String?> Function() keyProvider;
  final Dio _dio;
  final Uri base;
  static const imageBase = 'https://image.tmdb.org/t/p';

  Future<bool> get isConfigured async =>
      ((await keyProvider())?.trim() ?? '').isNotEmpty;

  Future<Map<String, Object?>?> _get(
    String path,
    Map<String, String> query, {
    CancelToken? cancel,
  }) async {
    final key = (await keyProvider())?.trim();
    if (key == null || key.isEmpty) return null;
    final bearer = key.startsWith('eyJ');
    final params = {...query, if (!bearer) 'api_key': key};
    try {
      final response = await _dio.getUri<Object?>(
        base.replace(path: '${base.path}/$path', queryParameters: params),
        cancelToken: cancel,
        options: Options(
          headers: {
            if (bearer) 'Authorization': 'Bearer $key',
            'Accept': 'application/json',
          },
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == 401)
        throw const FormatException('TMDB non accetta la chiave.');
      if (status == 429)
        throw const FormatException(
          'TMDB: troppe richieste, riprova più tardi.',
        );
      if (status < 200 || status >= 300) return null;
      return asMap(response.data);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return null;
      AppLog.instance.add('tmdb', 'Errore di rete (${e.type.name})');
      return null;
    }
  }

  /// Verifies the key. Returns null when accepted, else a reason.
  Future<String?> check() async {
    try {
      final r = await _get('configuration', const {});
      return r == null ? 'TMDB non risponde o la chiave non è valida.' : null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  static String? image(String? path, {String size = 'w342'}) =>
      (path == null || path.isEmpty) ? null : '$imageBase/$size$path';

  /// TMDB's id for an IMDb code (`tt…`) or the id inside a Stremio id.
  Future<({int id, bool isMovie})?> findByImdb(
    String imdbId, {
    CancelToken? cancel,
  }) async {
    final r = await _get('find/$imdbId', {
      'external_source': 'imdb_id',
    }, cancel: cancel);
    final movie = asList(r?['movie_results']);
    if (movie.isNotEmpty) {
      final id = asInt(asMap(movie.first)?['id']);
      if (id != null) return (id: id, isMovie: true);
    }
    final tv = asList(r?['tv_results']);
    if (tv.isNotEmpty) {
      final id = asInt(asMap(tv.first)?['id']);
      if (id != null) return (id: id, isMovie: false);
    }
    return null;
  }

  Future<RichDetails?> details(
    String imdbId, {
    String language = 'it-IT',
    CancelToken? cancel,
  }) async {
    final found = await findByImdb(imdbId, cancel: cancel);
    if (found == null) return null;
    final r = await _get('${found.isMovie ? 'movie' : 'tv'}/${found.id}', {
      'language': language,
      'append_to_response': 'credits,videos,similar',
    }, cancel: cancel);
    if (r == null) return null;
    final cast = <CastMember>[];
    for (final c in asList(asMap(r['credits'])?['cast']).take(20)) {
      final m = asMap(c);
      final name = asNonEmptyString(m?['name']);
      if (m == null || name == null) continue;
      cast.add(
        CastMember(
          name: name,
          role: asNonEmptyString(m['character']),
          photo: image(asNonEmptyString(m['profile_path']), size: 'w185'),
          tmdbId: asInt(m['id']),
        ),
      );
    }
    final trailers = <String>[];
    for (final v in asList(asMap(r['videos'])?['results'])) {
      final m = asMap(v);
      if (asString(m?['site']) == 'YouTube' &&
          (asString(m?['type']) == 'Trailer' ||
              asString(m?['type']) == 'Teaser')) {
        final k = asNonEmptyString(m?['key']);
        if (k != null) trailers.add(k);
      }
    }
    return RichDetails(
      tmdbId: found.id,
      cast: cast,
      trailers: trailers,
      companies: asList(r['production_companies'])
          .map((e) => asNonEmptyString(asMap(e)?['name']))
          .whereType<String>()
          .toList(),
      overview: asNonEmptyString(r['overview']),
      tagline: asNonEmptyString(r['tagline']),
      budget: asInt(r['budget']),
      revenue: asInt(r['revenue']),
      voteAverage: asDouble(r['vote_average']),
      collectionName: asNonEmptyString(
        asMap(r['belongs_to_collection'])?['name'],
      ),
      similar: asList(asMap(r['similar'])?['results'])
          .map(
            (e) =>
                asNonEmptyString(asMap(e)?['title']) ??
                asNonEmptyString(asMap(e)?['name']),
          )
          .whereType<String>()
          .take(12)
          .toList(),
    );
  }

  Future<List<PersonCredit>> filmography(
    int personId, {
    String language = 'it-IT',
    CancelToken? cancel,
  }) async {
    final r = await _get('person/$personId/combined_credits', {
      'language': language,
    }, cancel: cancel);
    final result = <PersonCredit>[];
    for (final c in asList(r?['cast'])) {
      final m = asMap(c);
      final id = asInt(m?['id']);
      final isMovie = asString(m?['media_type']) == 'movie';
      final title =
          asNonEmptyString(m?['title']) ?? asNonEmptyString(m?['name']);
      if (m == null || id == null || title == null) continue;
      final date =
          asNonEmptyString(m['release_date']) ??
          asNonEmptyString(m['first_air_date']);
      result.add(
        PersonCredit(
          title: title,
          role: asNonEmptyString(m['character']),
          year: (date != null && date.length >= 4)
              ? date.substring(0, 4)
              : null,
          poster: image(asNonEmptyString(m['poster_path'])),
          isMovie: isMovie,
          tmdbId: id,
          popularity: asDouble(m['popularity']) ?? 0,
        ),
      );
    }
    result.sort((a, b) => b.popularity.compareTo(a.popularity));
    return result;
  }

  /// TheTVDB id of a series (TMDB external ids), used for fanart.tv logos of series.
  Future<int?> tvdbIdOf(int tmdbId, {CancelToken? cancel}) async {
    final r = await _get('tv/$tmdbId/external_ids', const {}, cancel: cancel);
    return asInt(r?['tvdb_id']);
  }

  /// The IMDb code of a TMDB title (to open it from the catalogs).
  Future<String?> imdbIdOf(
    int tmdbId, {
    required bool isMovie,
    CancelToken? cancel,
  }) async {
    final r = await _get(
      '${isMovie ? 'movie' : 'tv'}/$tmdbId/external_ids',
      const {},
      cancel: cancel,
    );
    return asNonEmptyString(r?['imdb_id']);
  }
}
