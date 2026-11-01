import 'dart:async';

import '../metadata/tmdb_client.dart';
import '../model/meta.dart';
import '../util/lenient.dart';
import 'trakt_client.dart';

/// I cataloghi che Trakt offre.
enum TraktCatalogKind {
  continueWatching('Da riprendere (Trakt)', true),
  calendar('In uscita nei prossimi giorni', true),
  recommendedMovies('Film consigliati per te', true),
  recommendedShows('Serie consigliate per te', true),
  watchlist('La tua watchlist', true),
  trendingMovies('Film in tendenza', false),
  trendingShows('Serie in tendenza', false),
  popularMovies('Film popolari', false),
  popularShows('Serie popolari', false),
  anticipatedMovies('Film più attesi', false),
  anticipatedShows('Serie più attese', false),
  boxOffice('Box office della settimana', false);

  const TraktCatalogKind(this.title, this.needsLogin);
  final String title;

  /// Serve aver collegato l'account.
  final bool needsLogin;
}

class TraktShelf {
  const TraktShelf(this.meta, this.note);
  final MetaItem meta;
  final String? note;
}

class TraktListInfo {
  const TraktListInfo(this.id, this.name, this.count);
  final int id;
  final String name;
  final int count;
}

class _Title {
  const _Title(
    this.isMovie,
    this.title,
    this.year,
    this.imdb,
    this.tmdb, {
    this.note,
  });
  final bool isMovie;
  final String title;
  final int? year;
  final String? imdb;
  final int? tmdb;
  final String? note;
}

/// Trasforma i titoli di Trakt in titoli apribili in Aether: Trakt non ha immagini, quindi nome, trama e locandina vengono da TMDB
/// (se c'è la chiave), nella lingua dell'utente.
class TraktCatalogService {
  TraktCatalogService(this.trakt, this.tmdb);
  final TraktClient trakt;
  final TmdbClient tmdb;
  final Map<
    String,
    ({String? name, String? overview, String? poster, String? background})
  >
  _cache = {};

  Future<List<TraktShelf>> items(
    TraktCatalogKind kind,
    int limit,
    String language,
  ) async {
    final q = '?limit=$limit';
    final titles = switch (kind) {
      TraktCatalogKind.trendingMovies => _wrapped(
        await trakt.getJson('/movies/trending$q'),
        'movie',
        true,
        _watchers,
      ),
      TraktCatalogKind.trendingShows => _wrapped(
        await trakt.getJson('/shows/trending$q'),
        'show',
        false,
        _watchers,
      ),
      TraktCatalogKind.popularMovies => _plain(
        await trakt.getJson('/movies/popular$q'),
        true,
      ),
      TraktCatalogKind.popularShows => _plain(
        await trakt.getJson('/shows/popular$q'),
        false,
      ),
      TraktCatalogKind.anticipatedMovies => _wrapped(
        await trakt.getJson('/movies/anticipated$q'),
        'movie',
        true,
        _lists,
      ),
      TraktCatalogKind.anticipatedShows => _wrapped(
        await trakt.getJson('/shows/anticipated$q'),
        'show',
        false,
        _lists,
      ),
      TraktCatalogKind.boxOffice => _wrapped(
        await trakt.getJson('/movies/boxoffice'),
        'movie',
        true,
        _revenue,
      ),
      TraktCatalogKind.recommendedMovies => _plain(
        await trakt.getJson('/recommendations/movies$q', auth: true),
        true,
      ),
      TraktCatalogKind.recommendedShows => _plain(
        await trakt.getJson('/recommendations/shows$q', auth: true),
        false,
      ),
      TraktCatalogKind.watchlist => [
        ..._wrapped(
          await trakt.getJson(
            '/sync/watchlist/movies?sort=added,desc',
            auth: true,
          ),
          'movie',
          true,
          null,
        ),
        ..._wrapped(
          await trakt.getJson(
            '/sync/watchlist/shows?sort=added,desc',
            auth: true,
          ),
          'show',
          false,
          null,
        ),
      ].take(limit < 50 ? 50 : limit).toList(),
      TraktCatalogKind.continueWatching => _playback(
        await trakt.getJson('/sync/playback?limit=$limit', auth: true),
      ).take(limit).toList(),
      TraktCatalogKind.calendar => _calendar(
        await trakt.getJson('/calendars/my/shows/${_today()}/14', auth: true),
      ).take(limit).toList(),
    };
    return _shelf(titles, language);
  }

  Future<List<TraktListInfo>> lists() async {
    final r = await trakt.getJson('/users/me/lists', auth: true);
    return [
      for (final e in asList(r))
        if (asString(asMap(e)?['name']) != null &&
            asInt(asMap(asMap(e)?['ids'])?['trakt']) != null)
          TraktListInfo(
            asInt(asMap(asMap(e)!['ids'])!['trakt'])!,
            asString(asMap(e)!['name'])!,
            asInt(asMap(e)!['item_count']) ?? 0,
          ),
    ];
  }

  Future<List<TraktShelf>> listItems(int id, int limit, String language) async {
    final r = await trakt.getJson(
      '/users/me/lists/$id/items/movie,show?limit=$limit',
      auth: true,
    );
    final titles = <_Title>[];
    for (final e in asList(r)) {
      final m = asMap(e);
      final movie = _title(asMap(m?['movie']), true);
      final show = _title(asMap(m?['show']), false);
      if (movie != null) titles.add(movie);
      if (show != null) titles.add(show);
    }
    return _shelf(titles, language);
  }

  /// Dà a ogni titolo nome, locandina e trama; chi non ha il codice IMDb (quello che usano gli addon) viene saltato.
  Future<List<TraktShelf>> _shelf(List<_Title> titles, String language) async {
    final usable = [
      for (final t in titles)
        if (t.imdb != null) t,
    ];
    final results = await Future.wait([
      for (final t in usable) _toShelf(t, language),
    ]);
    final seen = <String>{};
    return [
      for (final r in results)
        if (seen.add(r.meta.id)) r,
    ];
  }

  Future<TraktShelf> _toShelf(_Title t, String language) async {
    final r = await _resolve(t, language);
    return TraktShelf(
      MetaItem(
        id: t.imdb!,
        type: t.isMovie ? 'movie' : 'series',
        name: r.name ?? t.title,
        poster: r.poster,
        background: r.background,
        description: r.overview,
        releaseInfo: t.year?.toString(),
      ),
      t.note,
    );
  }

  Future<({String? name, String? overview, String? poster, String? background})>
  _resolve(_Title t, String language) async {
    const none = (name: null, overview: null, poster: null, background: null);
    final id = t.tmdb;
    if (id == null) return none;
    final key = '${t.isMovie}-$id-$language';
    final hit = _cache[key];
    if (hit != null) return hit;
    Map<String, Object?>? d;
    try {
      d = await tmdb.raw('${t.isMovie ? 'movie' : 'tv'}/$id', {
        'language': language,
      });
    } on FormatException {
      return none;
    }
    if (d == null) return none;
    String? image(Object? p, String size) {
      final path = asString(p);
      if (path == null || !path.startsWith('/') || path.contains('..'))
        return null;
      return '${TmdbClient.imageBase}/$size$path';
    }

    final r = (
      name: asString(d['title'] ?? d['name']),
      overview: asString(d['overview']),
      poster: image(d['poster_path'], 'w342'),
      background: image(d['backdrop_path'], 'w780'),
    );
    if (_cache.length > 1500) _cache.clear();
    _cache[key] = r;
    return r;
  }

  // ── lettura delle risposte ──

  static String _today() {
    final d = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static _Title? _title(Map<String, Object?>? o, bool isMovie, {String? note}) {
    final name = asString(o?['title']);
    if (o == null || name == null) return null;
    final ids = asMap(o['ids']);
    return _Title(
      isMovie,
      name,
      asInt(o['year']),
      asString(ids?['imdb']),
      asInt(ids?['tmdb']),
      note: note,
    );
  }

  static String? _watchers(Map<String, Object?> e) =>
      asInt(e['watchers']) == null
      ? null
      : '${asInt(e['watchers'])} spettatori ora';
  static String? _lists(Map<String, Object?> e) =>
      asInt(e['list_count']) == null
      ? null
      : 'in ${asInt(e['list_count'])} liste';
  static String? _revenue(Map<String, Object?> e) {
    final v = asInt(e['revenue']);
    if (v == null) return null;
    return 'incasso ${v >= 1000000 ? '${(v / 1000000).toStringAsFixed(1)} M\$' : '$v \$'}';
  }

  static List<_Title> _plain(Object? body, bool isMovie) => [
    for (final e in asList(body)) ?_title(asMap(e), isMovie),
  ];

  static List<_Title> _wrapped(
    Object? body,
    String key,
    bool isMovie,
    String? Function(Map<String, Object?>)? note,
  ) => [
    for (final e in asList(body))
      ?_title(
        asMap(asMap(e)?[key]),
        isMovie,
        note: asMap(e) == null ? null : note?.call(asMap(e)!),
      ),
  ];

  static List<_Title> _playback(Object? body) {
    final out = <_Title>[];
    final seen = <String>{};
    for (final e in asList(body)) {
      final m = asMap(e);
      final progress = asDouble(m?['progress']);
      final movie = _title(
        asMap(m?['movie']),
        true,
        note: progress == null ? null : 'visto al ${progress.round()}%',
      );
      if (movie != null) {
        if (seen.add(movie.imdb ?? movie.title)) out.add(movie);
        continue;
      }
      final episode = asMap(m?['episode']);
      final label =
          'S${asInt(episode?['season']) ?? 0}E${asInt(episode?['number']) ?? 0}${progress == null ? '' : ' · ${progress.round()}%'}';
      final show = _title(asMap(m?['show']), false, note: label);
      if (show != null && seen.add(show.imdb ?? show.title)) out.add(show);
    }
    return out;
  }

  static List<_Title> _calendar(Object? body) {
    final out = <_Title>[];
    for (final e in asList(body)) {
      final m = asMap(e);
      final episode = asMap(m?['episode']);
      final aired = asString(m?['first_aired']);
      final day = aired != null && aired.length >= 10
          ? aired.substring(0, 10)
          : null;
      final show = _title(
        asMap(m?['show']),
        false,
        note: [
          'S${asInt(episode?['season']) ?? 0}E${asInt(episode?['number']) ?? 0}',
          ?day,
        ].join(' · '),
      );
      if (show != null) out.add(show);
    }
    return out;
  }
}
