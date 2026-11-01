import 'dart:async';

import '../metadata/tmdb_client.dart';
import '../model/meta.dart';
import '../util/lenient.dart';
import 'search_intent.dart';

/// Quanto ha impiegato una fase della ricerca.
class PhaseTiming {
  const PhaseTiming(this.name, this.seconds, {this.detail});
  final String name;
  final double seconds;
  final String? detail;

  Map<String, Object?> toJson() => {
    'name': name,
    'seconds': seconds,
    'detail': detail,
  };
  static PhaseTiming? fromJson(Object? v) {
    final m = asMap(v);
    final name = asString(m?['name']);
    final seconds = asDouble(m?['seconds']);
    if (name == null || seconds == null) return null;
    return PhaseTiming(name, seconds, detail: asString(m?['detail']));
  }
}

class AdvancedOptions {
  const AdvancedOptions({
    this.kinds = 'both',
    this.maxResults = 20,
    this.minVotes = 300,
    this.includeAdult = false,
    this.keywordSearch = true,
    this.language = 'it-IT',
  });
  final String kinds; // both | movie | series
  final int maxResults;
  final int minVotes;
  final bool includeAdult;
  final bool keywordSearch;
  final String language;
}

class AdvancedOutcome {
  const AdvancedOutcome(this.items, this.notes, this.timings);
  final List<MetaItem> items;
  final List<String> notes;
  final List<PhaseTiming> timings;
}

class _Hit {
  const _Hit(this.isMovie, this.data);
  final bool isMovie;
  final Map<String, Object?> data;
}

/// Esegue un `SearchIntent` su TMDB (discover, parole chiave, titolo) e restituisce titoli apribili in Aether.
class AdvancedSearchService {
  AdvancedSearchService(this.tmdb);
  final TmdbClient tmdb;
  final Map<String, MetaItem> _metaCache = {};
  final Map<String, String> _imdbCache = {};

  Future<bool> get isAvailable => tmdb.isConfigured;

  void clearCache() {
    _metaCache.clear();
    _imdbCache.clear();
  }

  Future<AdvancedOutcome> run(
    SearchIntent intent,
    List<String> extraKeywords,
    AdvancedOptions o,
  ) async {
    final notes = <String>[];
    final timings = <PhaseTiming>[];
    final kinds = _kinds(intent, o);
    if (kinds.isEmpty) return const AdvancedOutcome([], [], []);

    // I titoli proposti dall'AI vanno per primi; i filtri (se ci sono) completano la lista.
    if (intent.suggestions.isNotEmpty) {
      final sw = Stopwatch()..start();
      final suggested = await _resolveItems(intent.suggestions, kinds, o);
      timings.add(
        PhaseTiming(
          'TMDB · titoli proposti (ricerca e codici IMDb)',
          sw.elapsedMilliseconds / 1000,
          detail: '${suggested.length} su ${intent.suggestions.length} trovati',
        ),
      );
      if (suggested.length < intent.suggestions.length) {
        notes.add(
          '${suggested.length} titoli su ${intent.suggestions.length} proposti dall\'AI sono stati trovati su TMDB.',
        );
      }
      final rest = intent.copy()
        ..suggestions.clear()
        ..similarTo = null
        ..title = null;
      if (!rest.hasFilters || suggested.length >= o.maxResults) {
        return AdvancedOutcome(suggested, notes, timings);
      }
      final more = await run(rest, extraKeywords, o);
      final seen = {for (final m in suggested) m.id};
      final merged = [...suggested];
      for (final m in more.items) {
        if (merged.length < o.maxResults && seen.add(m.id)) merged.add(m);
      }
      return AdvancedOutcome(
        merged,
        [...notes, ...more.notes],
        [...timings, ...more.timings],
      );
    }

    // «Simili a …»: si cerca il titolo di partenza e si prendono i consigliati di TMDB.
    final reference = intent.similarTo;
    if (reference != null) {
      final sw = Stopwatch()..start();
      var found = <_Hit>[];
      for (final isMovie in kinds) {
        final match = (await _searchTitles(
          isMovie,
          reference,
          o.language,
        )).firstOrNull;
        final id = asInt(match?['id']);
        if (match == null || id == null) continue;
        final path = isMovie ? 'movie' : 'tv';
        final rec = await _list('$path/$id/recommendations', {
          'language': o.language,
        });
        final sim = await _list('$path/$id/similar', {'language': o.language});
        final seen = <int>{};
        found = [
          for (final m in [...rec, ...sim])
            if (asInt(m['id']) != id && seen.add(asInt(m['id']) ?? -1))
              _Hit(isMovie, m),
        ];
        final y = asString(match['release_date'] ?? match['first_air_date']);
        notes.add(
          'Titolo di partenza: «${asString(match['title'] ?? match['name']) ?? reference}»${y != null && y.length >= 4 ? ' (${y.substring(0, 4)})' : ''}.',
        );
        break;
      }
      if (found.isEmpty && notes.isEmpty)
        notes.add('Non ho trovato «$reference» su TMDB.');
      final items = await _toItems(found, o.maxResults);
      timings.add(
        PhaseTiming(
          'TMDB · titoli simili (raccomandazioni)',
          sw.elapsedMilliseconds / 1000,
          detail: '${items.length} titoli',
        ),
      );
      return AdvancedOutcome(items, notes, timings);
    }

    // Un titolo preciso: ricerca per nome.
    final title = intent.title;
    if (title != null && intent.genres.isEmpty) {
      final found = <_Hit>[];
      for (final isMovie in kinds) {
        for (final m in (await _searchTitles(
          isMovie,
          title,
          o.language,
        )).take(o.maxResults)) {
          found.add(_Hit(isMovie, m));
        }
      }
      return AdvancedOutcome(
        await _toItems(found, o.maxResults),
        notes,
        timings,
      );
    }

    final words = [...intent.keywords];
    if (o.keywordSearch) {
      for (final w in extraKeywords) {
        if (words.length < 4 && !words.contains(w)) words.add(w);
      }
    }
    final kwSw = Stopwatch()..start();
    final ids = await _keywordIds(words);
    if (words.isNotEmpty) {
      timings.add(
        PhaseTiming(
          'TMDB · parole chiave',
          kwSw.elapsedMilliseconds / 1000,
          detail: words.join(', '),
        ),
      );
      if (ids.isEmpty) {
        notes.add(
          'Nessuna parola chiave TMDB corrisponde a «${words.join(', ')}»: ho usato solo gli altri filtri.',
        );
      }
    }
    final dSw = Stopwatch()..start();
    var found = await _discover(kinds, intent, ids, o, notes);
    // Le parole chiave restringono molto: se i titoli sono pochi, si completa con quelli degli altri filtri.
    if (ids.isNotEmpty && found.length < o.maxResults) {
      final more = await _discover(kinds, intent, const [], o, notes);
      final seen = {
        for (final h in found) '${h.isMovie}-${asInt(h.data['id'])}',
      };
      for (final h in more) {
        if (seen.add('${h.isMovie}-${asInt(h.data['id'])}')) found.add(h);
      }
      if (more.isNotEmpty)
        notes.add(
          'Prima i titoli con la parola chiave, poi altri dello stesso genere.',
        );
    }
    timings.add(
      PhaseTiming(
        'TMDB · elenco per filtri (discover)',
        dSw.elapsedMilliseconds / 1000,
        detail: '${found.length} candidati',
      ),
    );
    final iSw = Stopwatch()..start();
    final items = await _toItems(found, o.maxResults);
    timings.add(
      PhaseTiming(
        'TMDB · codici IMDb',
        iSw.elapsedMilliseconds / 1000,
        detail: '${items.length} titoli',
      ),
    );
    return AdvancedOutcome(items, notes, timings);
  }

  List<bool> _kinds(SearchIntent intent, AdvancedOptions o) {
    if (intent.kind != null) return [intent.kind == IntentKind.movie];
    return switch (o.kinds) {
      'movie' => [true],
      'series' => [false],
      _ => [true, false],
    };
  }

  Future<List<Map<String, Object?>>> _list(
    String path,
    Map<String, String> q,
  ) async {
    try {
      final r = await tmdb.raw(path, q);
      return [for (final e in asList(r?['results'])) ?asMap(e)];
    } on FormatException {
      return const [];
    }
  }

  Future<List<Map<String, Object?>>> _searchTitles(
    bool isMovie,
    String text,
    String language, {
    int? year,
  }) => _list('search/${isMovie ? 'movie' : 'tv'}', {
    'query': text,
    'language': language,
    'page': '1',
    if (year != null) (isMovie ? 'year' : 'first_air_date_year'): '$year',
  });

  Future<List<int>> _keywordIds(List<String> words) async {
    if (words.isEmpty) return const [];
    final lists = await Future.wait([
      for (final w in words) _list('search/keyword', {'query': w, 'page': '1'}),
    ]);
    final ids = <int>{
      for (final l in lists)
        if (l.isNotEmpty && asInt(l.first['id']) != null) asInt(l.first['id'])!,
    };
    return ids.toList()..sort();
  }

  Future<List<_Hit>> _discover(
    List<bool> kinds,
    SearchIntent i,
    List<int> keywordIds,
    AdvancedOptions o,
    List<String> notes,
  ) async {
    final lists = await Future.wait([
      for (final isMovie in kinds)
        _list(
          'discover/${isMovie ? 'movie' : 'tv'}',
          _query(isMovie, i, keywordIds, o, notes),
        ).then((l) => [for (final m in l) _Hit(isMovie, m)]),
    ]);
    // Film e serie si alternano, così nessuno dei due riempie la lista.
    final merged = <_Hit>[];
    var index = 0;
    while (merged.length < o.maxResults * 2) {
      var added = false;
      for (final l in lists) {
        if (index < l.length) {
          merged.add(l[index]);
          added = true;
        }
      }
      if (!added) break;
      index++;
    }
    return merged;
  }

  Map<String, String> _query(
    bool isMovie,
    SearchIntent i,
    List<int> keywordIds,
    AdvancedOptions o,
    List<String> notes,
  ) {
    final q = <String, String>{
      'language': o.language,
      'include_adult': o.includeAdult ? 'true' : 'false',
      'page': '1',
    };
    final genreIds = [
      for (final g in i.genres)
        if ((isMovie ? g.movieId : g.tvId) != null)
          (isMovie ? g.movieId : g.tvId)!,
    ];
    if (genreIds.length < i.genres.length) {
      final missing = [
        for (final g in i.genres)
          if ((isMovie ? g.movieId : g.tvId) == null) g.italian,
      ];
      notes.add(
        'Per le serie TMDB non ha il genere ${missing.join(', ')}: l\'ho ignorato.',
      );
    }
    if (genreIds.isNotEmpty)
      q['with_genres'] = (genreIds.toSet().toList()..sort()).join(',');
    if (keywordIds.isNotEmpty) q['with_keywords'] = keywordIds.join('|');
    final dateKey = isMovie ? 'primary_release_date' : 'first_air_date';
    if (i.yearFrom != null) q['$dateKey.gte'] = '${i.yearFrom}-01-01';
    if (i.yearTo != null) q['$dateKey.lte'] = '${i.yearTo}-12-31';
    if (i.minRating != null)
      q['vote_average.gte'] = i.minRating!.toStringAsFixed(1);
    if (i.countries.isNotEmpty)
      q['with_origin_country'] = i.countries.join('|');
    if (i.maxRuntime != null && isMovie)
      q['with_runtime.lte'] = '${i.maxRuntime}';
    switch (i.sort) {
      case IntentSort.popularity:
        q['sort_by'] = 'popularity.desc';
        q['vote_count.gte'] = '20';
      case IntentSort.rating:
        q['sort_by'] = 'vote_average.desc';
        q['vote_count.gte'] = '${o.minVotes}';
      case IntentSort.newest:
        q['sort_by'] = '$dateKey.desc';
        q['vote_count.gte'] = '30';
      case IntentSort.oldest:
        q['sort_by'] = '$dateKey.asc';
        q['vote_count.gte'] = '200';
    }
    return q;
  }

  /// Per ogni titolo proposto cerca il titolo e subito il codice IMDb, tutti in parallelo (una catena per titolo).
  Future<List<MetaItem>> _resolveItems(
    List<SuggestedTitle> list,
    List<bool> kinds,
    AdvancedOptions o,
  ) async {
    final results = await Future.wait([
      for (final s in list) _resolveOne(s, kinds, o.language),
    ]);
    final seen = <String>{};
    return [
      for (final m in results)
        if (m != null && seen.add(m.id)) m,
    ].take(o.maxResults).toList();
  }

  Future<MetaItem?> _resolveOne(
    SuggestedTitle s,
    List<bool> kinds,
    String language,
  ) async {
    final order = s.kind != null ? [s.kind == IntentKind.movie] : kinds;
    final key =
        '$language|${s.title.toLowerCase()}|${s.year ?? 0}|${order.join(',')}';
    final hit = _metaCache[key];
    if (hit != null) return hit;
    for (final isMovie in order) {
      final first = (await _searchTitles(
        isMovie,
        s.title,
        language,
        year: s.year,
      )).firstOrNull;
      final id = asInt(first?['id']);
      if (first == null || id == null) continue;
      final imdb = await _imdb(isMovie, id);
      if (imdb == null) continue;
      final meta = _meta(isMovie, first, imdb);
      if (meta == null) continue;
      _metaCache[key] = meta;
      return meta;
    }
    return null;
  }

  Future<String?> _imdb(bool isMovie, int id) async {
    final k = '${isMovie ? 'm' : 't'}$id';
    final cached = _imdbCache[k];
    if (cached != null) return cached;
    String? code;
    try {
      code = await tmdb.imdbIdOf(id, isMovie: isMovie);
    } on FormatException {
      return null;
    }
    if (code != null) _imdbCache[k] = code;
    return code;
  }

  Future<List<MetaItem>> _toItems(List<_Hit> hits, int limit) async {
    final slice = hits.take(limit + 8).toList();
    final metas = await Future.wait([
      for (final h in slice)
        () async {
          final id = asInt(h.data['id']);
          if (id == null) return null;
          final imdb = await _imdb(h.isMovie, id);
          return imdb == null ? null : _meta(h.isMovie, h.data, imdb);
        }(),
    ]);
    final seen = <String>{};
    return [
      for (final m in metas)
        if (m != null && seen.add(m.id)) m,
    ].take(limit).toList();
  }

  MetaItem? _meta(bool isMovie, Map<String, Object?> d, String imdb) {
    final name = asString(d['title'] ?? d['name']);
    if (name == null) return null;
    String? image(Object? p, String size) {
      final path = asString(p);
      if (path == null || !path.startsWith('/') || path.contains('..'))
        return null;
      return '${TmdbClient.imageBase}/$size$path';
    }

    final date = asString(d['release_date'] ?? d['first_air_date']);
    return MetaItem(
      id: imdb,
      type: isMovie ? 'movie' : 'series',
      name: name,
      poster: image(d['poster_path'], 'w342'),
      background: image(d['backdrop_path'], 'w780'),
      description: asString(d['overview']),
      releaseInfo: date != null && date.length >= 4
          ? date.substring(0, 4)
          : null,
    );
  }
}
