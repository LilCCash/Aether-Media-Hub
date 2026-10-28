import 'package:aether_flutter/core/catalog/result_filters.dart';
import 'package:aether_flutter/core/model/meta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const items = [
    MetaItem(
      id: 'a',
      type: 'movie',
      name: 'A',
      releaseInfo: '1999',
      genres: ['Azione', 'Drama'],
    ),
    MetaItem(
      id: 'b',
      type: 'series',
      name: 'B',
      releaseInfo: '2019–2021',
      genres: ['drama'],
    ),
    MetaItem(id: 'c', type: 'movie', name: 'C', genres: ['Commedia']),
  ];

  test(
    'year is read from a plain year, a range or free text; none when absent',
    () {
      expect(ResultFilters.yearOf(items[0]), 1999);
      expect(ResultFilters.yearOf(items[1]), 2019);
      expect(ResultFilters.yearOf(items[2]), isNull);
    },
  );

  test('type, genre (case-insensitive) and decade combine', () {
    expect(const ResultFilters(type: 'movie').apply(items).map((m) => m.id), [
      'a',
      'c',
    ]);
    expect(const ResultFilters(genre: 'DRAMA').apply(items).map((m) => m.id), [
      'a',
      'b',
    ]);
    expect(const ResultFilters(decade: 2010).apply(items).map((m) => m.id), [
      'b',
    ]);
    expect(
      const ResultFilters(
        type: 'series',
        genre: 'drama',
        decade: 2010,
      ).apply(items).length,
      1,
    );
    expect(
      const ResultFilters(decade: 1990, genre: 'Commedia').apply(items),
      isEmpty,
    );
    expect(ResultFilters.none.active, isFalse);
  });

  test('the options offered come from the items, without duplicates', () {
    expect(ResultFilters.genresOf(items), ['Azione', 'Commedia', 'Drama']);
    expect(ResultFilters.decadesOf(items), [2010, 1990]);
    expect(ResultFilters.typesOf(items), ['movie', 'series']);
    expect(const ResultFilters(genre: 'x').copyWith(genre: null).genre, isNull);
  });
}
