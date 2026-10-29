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

/// A video of the title on YouTube (trailer, teaser…).
class TmdbVideo {
  const TmdbVideo({
    required this.key,
    required this.name,
    required this.type,
    this.language,
    this.official = false,
  });
  final String key;
  final String name;
  final String type;
  final String? language;
  final bool official;
}

/// A production company with its logo when TMDB has one.
class CompanyCard {
  const CompanyCard(this.name, this.logo);
  final String name;
  final String? logo;
}

/// A similar or recommended title: enough to draw its poster and to open it (through its IMDb code).
class SimilarTitle {
  const SimilarTitle({
    required this.tmdbId,
    required this.title,
    required this.isMovie,
    this.year,
    this.poster,
    this.rating,
  });
  final int tmdbId;
  final String title;
  final bool isMovie;
  final String? year;
  final String? poster;
  final double? rating;
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
    this.status,
    this.originalTitle,
    this.originalLanguage,
    this.runtime,
    this.releaseDate,
    this.countries = const [],
    this.spokenLanguages = const [],
    this.voteCount,
    this.homepage,
    this.networks = const [],
    this.seasons,
    this.episodes,
    this.creators = const [],
    this.keywords = const [],
    this.certification,
    this.providers = const [],
    this.crew = const [],
    this.recommendations = const [],
    this.videos = const [],
    this.companyCards = const [],
    this.similarTitles = const [],
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
  final String? status;
  final String? originalTitle;
  final String? originalLanguage;
  final int? runtime; // minutes
  final String? releaseDate;
  final List<String> countries;
  final List<String> spokenLanguages;
  final int? voteCount;
  final String? homepage;
  final List<String> networks;
  final int? seasons;
  final int? episodes;
  final List<String> creators;
  final List<String> keywords;
  final String? certification;
  final List<String> providers; // where to watch in the user's region
  final List<String> crew; // «Name · Job»
  final List<String> recommendations;
  final List<TmdbVideo> videos;
  final List<CompanyCard> companyCards;
  final List<SimilarTitle> similarTitles;
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
const _jobIt = {
  'Director': 'Regia',
  'Writer': 'Scrittura',
  'Screenplay': 'Sceneggiatura',
  'Story': 'Soggetto',
  'Novel': 'Romanzo',
  'Original Music Composer': 'Musiche',
  'Director of Photography': 'Fotografia',
  'Producer': 'Produzione',
};

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
      'append_to_response': 'credits,videos,similar,recommendations,keywords,external_ids,release_dates,content_ratings,watch/providers',
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

    List<String> names(Object? list, String key) =>
        asList(list)
            .map((e) => asNonEmptyString(asMap(e)?[key]))
            .whereType<String>()
            .toList();
    final crew = <String>[];
    for (final c in asList(asMap(r['credits'])?['crew'])) {
      final m = asMap(c);
      final job = asString(m?['job']);
      final name = asNonEmptyString(m?['name']);
      if (name == null) continue;
      if (const {
        'Director',
        'Writer',
        'Screenplay',
        'Story',
        'Novel',
        'Original Music Composer',
        'Director of Photography',
        'Producer',
      }.contains(job)) {
        final label = '$name · ${_jobIt[job] ?? job}';
        if (!crew.contains(label)) crew.add(label);
      }
    }
    String? certification;
    final region = 'IT';
    for (final c in asList(asMap(r['release_dates'])?['results'])) {
      final m = asMap(c);
      if (asString(m?['iso_3166_1']) != region && certification != null) {
        continue;
      }
      for (final d in asList(m?['release_dates'])) {
        final cert = asNonEmptyString(asMap(d)?['certification']);
        if (cert != null &&
            (asString(m?['iso_3166_1']) == region || certification == null)) {
          certification = cert;
        }
      }
    }
    for (final c in asList(asMap(r['content_ratings'])?['results'])) {
      final m = asMap(c);
      final cert = asNonEmptyString(m?['rating']);
      if (cert != null &&
          (asString(m?['iso_3166_1']) == region || certification == null)) {
        certification = cert;
      }
    }
    final providerRegion = asMap(
      asMap(asMap(r['watch/providers'])?['results'])?[region],
    );
    final date =
        asNonEmptyString(r['release_date']) ??
        asNonEmptyString(r['first_air_date']);
    final runtimes = asList(r['episode_run_time']);
    final videos = <TmdbVideo>[];
    for (final v in asList(asMap(r['videos'])?['results'])) {
      final m = asMap(v);
      final k = asNonEmptyString(m?['key']);
      if (m == null || k == null || asString(m['site']) != 'YouTube') continue;
      final type = asString(m['type']) ?? '';
      if (type != 'Trailer' && type != 'Teaser') continue;
      videos.add(
        TmdbVideo(
          key: k,
          name: asNonEmptyString(m['name']) ?? type,
          type: type,
          language: asNonEmptyString(m['iso_639_1']),
          official: m['official'] == true,
        ),
      );
    }
    final similarTitles = <SimilarTitle>[];
    final seenSimilar = <int>{};
    for (final list in [
      asMap(r['recommendations'])?['results'],
      asMap(r['similar'])?['results'],
    ]) {
      for (final e in asList(list)) {
        final m = asMap(e);
        final id = asInt(m?['id']);
        final title =
            asNonEmptyString(m?['title']) ?? asNonEmptyString(m?['name']);
        final poster = asNonEmptyString(m?['poster_path']);
        if (m == null ||
            id == null ||
            title == null ||
            poster == null ||
            !seenSimilar.add(id)) {
          continue;
        }
        final d =
            asNonEmptyString(m['release_date']) ??
            asNonEmptyString(m['first_air_date']);
        similarTitles.add(
          SimilarTitle(
            tmdbId: id,
            title: title,
            isMovie: found.isMovie,
            year: (d != null && d.length >= 4) ? d.substring(0, 4) : null,
            poster: image(poster, size: 'w342'),
            rating: asDouble(m['vote_average']),
          ),
        );
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
      videos: videos,
      companyCards: [
        for (final c in asList(r['production_companies']))
          if (asNonEmptyString(asMap(c)?['name']) != null)
            CompanyCard(
              asNonEmptyString(asMap(c)?['name'])!,
              image(asNonEmptyString(asMap(c)?['logo_path']), size: 'w300'),
            ),
      ],
      similarTitles: similarTitles.take(20).toList(),
      status: asNonEmptyString(r['status']),
      originalTitle:
          asNonEmptyString(r['original_title']) ??
          asNonEmptyString(r['original_name']),
      originalLanguage: asNonEmptyString(r['original_language']),
      runtime:
          asInt(r['runtime']) ??
          (runtimes.isEmpty ? null : asInt(runtimes.first)),
      releaseDate: date,
      countries: names(r['production_countries'], 'name'),
      spokenLanguages: names(r['spoken_languages'], 'name'),
      voteCount: asInt(r['vote_count']),
      homepage: asNonEmptyString(r['homepage']),
      networks: names(r['networks'], 'name'),
      seasons: asInt(r['number_of_seasons']),
      episodes: asInt(r['number_of_episodes']),
      creators: names(r['created_by'], 'name'),
      keywords: names(
        asMap(r['keywords'])?['keywords'] ?? asMap(r['keywords'])?['results'],
        'name',
      ).take(12).toList(),
      certification: certification,
      providers: {
        ...names(providerRegion?['flatrate'], 'provider_name'),
        ...names(providerRegion?['free'], 'provider_name'),
        ...names(providerRegion?['ads'], 'provider_name'),
      }.toList(),
      crew: crew.take(10).toList(),
      recommendations: asList(asMap(r['recommendations'])?['results'])
          .map(
            (e) =>
                asNonEmptyString(asMap(e)?['title']) ??
                asNonEmptyString(asMap(e)?['name']),
          )
          .whereType<String>()
          .take(12)
          .toList(),
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

  /// The title's own logo from TMDB's artwork (the viewer's language, then English, then a language-free one; never a vector).
  /// Used when fanart.tv has none: the iOS app gets its logos the same way.
  Future<String?> logoUrl(
    String imdbId, {
    String language = 'it',
    CancelToken? cancel,
  }) async {
    final found = await findByImdb(imdbId, cancel: cancel);
    if (found == null) return null;
    final wanted = language.length >= 2
        ? language.substring(0, 2).toLowerCase()
        : language;
    final r = await _get(
      '${found.isMovie ? 'movie' : 'tv'}/${found.id}/images',
      {'include_image_language': '$wanted,en,null'},
      cancel: cancel,
    );
    final logos = [
      for (final e in asList(r?['logos']))
        if (asMap(e) != null &&
            asNonEmptyString(asMap(e)!['file_path']) != null &&
            !asNonEmptyString(asMap(e)!['file_path'])!.endsWith('.svg'))
          asMap(e)!,
    ];
    if (logos.isEmpty) return null;
    int tier(Map<String, Object?> l) {
      final lang = asString(l['iso_639_1']);
      return lang == wanted ? 0 : (lang == 'en' ? 1 : (lang == null ? 2 : 3));
    }

    logos.sort((a, b) {
      final t = tier(a).compareTo(tier(b));
      return t != 0
          ? t
          : (asDouble(b['vote_average']) ?? 0).compareTo(
              asDouble(a['vote_average']) ?? 0,
            );
    });
    return image(asNonEmptyString(logos.first['file_path']), size: 'w500');
  }

  /// The title's posters from TMDB (the viewer's language first, then English, then textless ones), best rated first.
  Future<List<String>> posters(
    String imdbId, {
    String language = 'it',
    CancelToken? cancel,
  }) async {
    final found = await findByImdb(imdbId, cancel: cancel);
    if (found == null) return const [];
    final wanted = language.length >= 2
        ? language.substring(0, 2).toLowerCase()
        : language;
    final r = await _get(
      '${found.isMovie ? 'movie' : 'tv'}/${found.id}/images',
      {'include_image_language': '$wanted,en,null'},
      cancel: cancel,
    );
    final list = [
      for (final e in asList(r?['posters']))
        if (asMap(e) != null &&
            asNonEmptyString(asMap(e)!['file_path']) != null)
          asMap(e)!,
    ];
    int tier(Map<String, Object?> l) {
      final lang = asString(l['iso_639_1']);
      return lang == wanted ? 0 : (lang == 'en' ? 1 : (lang == null ? 2 : 3));
    }

    list.sort((a, b) {
      final t = tier(a).compareTo(tier(b));
      return t != 0
          ? t
          : (asDouble(b['vote_average']) ?? 0).compareTo(
              asDouble(a['vote_average']) ?? 0,
            );
    });
    return [
      for (final p in list.take(24))
        ?image(asNonEmptyString(p['file_path']), size: 'w500'),
    ];
  }

  /// How many episodes of a season have aired, so a season download stops at the real last one.
  Future<int?> airedEpisodes(
    String imdbId,
    int season, {
    CancelToken? cancel,
  }) async {
    final found = await findByImdb(imdbId, cancel: cancel);
    if (found == null || found.isMovie) return null;
    final r = await _get(
      'tv/${found.id}/season/$season',
      const {},
      cancel: cancel,
    );
    final eps = asList(r?['episodes']);
    if (eps.isEmpty) return null;
    final now = DateTime.now();
    var last = 0;
    for (final e in eps) {
      final m = asMap(e);
      final n = asInt(m?['episode_number']) ?? 0;
      final d = DateTime.tryParse(asString(m?['air_date']) ?? '');
      if (d == null || !d.isAfter(now)) last = n > last ? n : last;
    }
    return last == 0 ? null : last;
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
