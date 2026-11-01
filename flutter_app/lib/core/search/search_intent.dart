/// Generi comuni a film e serie, con il codice TMDB di ciascun tipo (null = non esiste per quel tipo).
enum IntentGenre {
  action('azione', 28, 10759),
  adventure('avventura', 12, 10759),
  animation('animazione', 16, 16),
  comedy('commedia', 35, 35),
  crime('crimine', 80, 80),
  documentary('documentario', 99, 99),
  drama('drammatico', 18, 18),
  family('famiglia', 10751, 10751),
  fantasy('fantasy', 14, 10765),
  history('storico', 36, null),
  horror('horror', 27, null),
  music('musicale', 10402, null),
  mystery('mistero', 9648, 9648),
  romance('romantico', 10749, 10749),
  scifi('fantascienza', 878, 10765),
  thriller('thriller', 53, null),
  war('guerra', 10752, 10768),
  western('western', 37, 37);

  const IntentGenre(this.italian, this.movieId, this.tvId);
  final String italian;
  final int? movieId;
  final int? tvId;

  static IntentGenre? parse(String raw) {
    final key = raw.toLowerCase().replaceAll('-', '').trim();
    for (final g in values) {
      if (g.name == key || g.italian == key) return g;
    }
    return null;
  }
}

enum IntentKind { movie, series }

enum IntentSort {
  popularity('più popolari'),
  rating('meglio votati'),
  newest('più recenti'),
  oldest('più vecchi');

  const IntentSort(this.italian);
  final String italian;
}

enum IntentSource { keyword, parser, ai }

/// Un titolo proposto dall'AI (nome originale e anno, per ritrovarlo su TMDB).
class SuggestedTitle {
  const SuggestedTitle(this.title, {this.year, this.kind});
  final String title;
  final int? year;
  final IntentKind? kind;

  @override
  bool operator ==(Object other) =>
      other is SuggestedTitle &&
      other.title == title &&
      other.year == year &&
      other.kind == kind;
  @override
  int get hashCode => Object.hash(title, year, kind);
}

/// Ciò che l'utente vuole, tradotto in filtri: lo producono il parser locale e i modelli AI, lo esegue TMDB.
class SearchIntent {
  SearchIntent({
    this.kind,
    List<IntentGenre>? genres,
    List<String>? keywords,
    this.yearFrom,
    this.yearTo,
    this.sort = IntentSort.popularity,
    this.minRating,
    List<String>? countries,
    this.maxRuntime,
    this.title,
    this.similarTo,
    List<SuggestedTitle>? suggestions,
    this.source = IntentSource.parser,
  }) : genres = genres ?? [],
       keywords = keywords ?? [],
       countries = countries ?? [],
       suggestions = suggestions ?? [];

  IntentKind? kind;
  final List<IntentGenre> genres;
  final List<String> keywords;
  int? yearFrom;
  int? yearTo;
  IntentSort sort;
  double? minRating;
  final List<String> countries;
  int? maxRuntime;
  String? title;
  String? similarTo;
  final List<SuggestedTitle> suggestions;
  IntentSource source;

  /// Vero se il testo ha prodotto almeno un filtro utile.
  bool get hasFilters =>
      genres.isNotEmpty ||
      keywords.isNotEmpty ||
      yearFrom != null ||
      yearTo != null ||
      minRating != null ||
      countries.isNotEmpty ||
      maxRuntime != null ||
      kind != null ||
      similarTo != null ||
      suggestions.isNotEmpty;

  SearchIntent copy() => SearchIntent(
    kind: kind,
    genres: [...genres],
    keywords: [...keywords],
    yearFrom: yearFrom,
    yearTo: yearTo,
    sort: sort,
    minRating: minRating,
    countries: [...countries],
    maxRuntime: maxRuntime,
    title: title,
    similarTo: similarTo,
    suggestions: [...suggestions],
    source: source,
  );

  /// La frase letta dall'app, in italiano, per mostrarla all'utente.
  String get summary {
    final parts = <String>[];
    if (similarTo != null && suggestions.isNotEmpty) {
      return "consigliati dall'AI, simili a «$similarTo»";
    }
    if (similarTo != null) {
      final label = kind == IntentKind.series
          ? 'serie'
          : (kind == IntentKind.movie ? 'film' : 'titoli');
      return '$label simili a «$similarTo»';
    }
    if (suggestions.isNotEmpty &&
        genres.isEmpty &&
        keywords.isEmpty &&
        yearFrom == null &&
        yearTo == null) {
      return "consigliati dall'AI";
    }
    if (kind != null) parts.add(kind == IntentKind.movie ? 'film' : 'serie');
    if (genres.isNotEmpty) parts.add(genres.map((g) => g.italian).join(' + '));
    if (keywords.isNotEmpty) parts.add('«${keywords.join(', ')}»');
    if (yearFrom != null && yearTo != null) {
      parts.add(yearFrom == yearTo ? '$yearFrom' : '$yearFrom–$yearTo');
    } else if (yearFrom != null) {
      parts.add('dal $yearFrom');
    } else if (yearTo != null) {
      parts.add('fino al $yearTo');
    }
    if (countries.isNotEmpty) parts.add(countries.join(', '));
    if (maxRuntime != null) parts.add('fino a $maxRuntime min');
    if (minRating != null) {
      parts.add('voto ≥ ${minRating!.toStringAsFixed(1)}');
    }
    parts.add(sort.italian);
    return parts.join(' · ');
  }
}
