import 'meta.dart';

/// TMDB's genre id for talk shows (TV).
const int kTmdbTalkGenre = 10767;

bool isTalkGenres(Iterable<String> genres) =>
    genres.any((g) => g.toLowerCase().contains('talk'));

bool isTalkShow(MetaItem m) => isTalkGenres(m.genres);

/// Removes the talk shows from a list of catalogue items (when the viewer asked not to see them).
List<MetaItem> withoutTalkShows(List<MetaItem> items, {required bool hide}) =>
    hide
    ? [
        for (final m in items)
          if (!isTalkShow(m)) m,
      ]
    : items;
