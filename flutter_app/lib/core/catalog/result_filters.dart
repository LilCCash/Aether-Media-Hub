import '../model/meta.dart';

/// Filters the viewer applies to search results and to the library: type, genre and decade. Pure, so it is testable.
class ResultFilters {
  const ResultFilters({this.type, this.genre, this.decade});

  final String? type;
  final String? genre;

  /// First year of the decade (1990, 2000…).
  final int? decade;

  static const none = ResultFilters();

  bool get active => type != null || genre != null || decade != null;

  ResultFilters copyWith({
    Object? type = _keep,
    Object? genre = _keep,
    Object? decade = _keep,
  }) => ResultFilters(
    type: identical(type, _keep) ? this.type : type as String?,
    genre: identical(genre, _keep) ? this.genre : genre as String?,
    decade: identical(decade, _keep) ? this.decade : decade as int?,
  );

  /// The year in "2019", "2019–2021", "2019-" or a date; null when there is none.
  static int? yearOf(MetaItem m) {
    final match = RegExp(r'(19|20)\d{2}').firstMatch(m.releaseInfo ?? '');
    return match == null ? null : int.parse(match.group(0)!);
  }

  bool accepts(MetaItem m) {
    if (type != null && m.type != type) return false;
    if (genre != null &&
        !m.genres.any((g) => g.toLowerCase() == genre!.toLowerCase())) {
      return false;
    }
    if (decade != null) {
      final y = yearOf(m);
      if (y == null || y < decade! || y >= decade! + 10) return false;
    }
    return true;
  }

  List<MetaItem> apply(Iterable<MetaItem> items) =>
      items.where(accepts).toList();

  static List<String> typesOf(Iterable<MetaItem> items) =>
      items.map((m) => m.type).toSet().toList()..sort();

  static List<String> genresOf(Iterable<MetaItem> items) {
    final seen = <String, String>{};
    for (final m in items) {
      for (final g in m.genres) {
        seen.putIfAbsent(g.toLowerCase(), () => g);
      }
    }
    final list = seen.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  static List<int> decadesOf(Iterable<MetaItem> items) {
    final set = <int>{};
    for (final m in items) {
      final y = yearOf(m);
      if (y != null) set.add(y ~/ 10 * 10);
    }
    return set.toList()..sort((a, b) => b.compareTo(a));
  }
}

const Object _keep = Object();
