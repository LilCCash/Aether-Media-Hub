import '../core/model/meta.dart';
import '../core/sync/simkl_client.dart';
import '../core/sync/trakt_client.dart';
import 'library_repository.dart';
import 'prefs_ext.dart';
import 'settings.dart';

/// Keeps the library in step with Trakt and Simkl: what is watched here is scrobbled or sent, and «Sincronizza ora» pulls the
/// watched list and the watchlist from Trakt into the library. Every call is best-effort: a service that is down never reaches
/// the player.
class SyncService {
  SyncService({
    required this.trakt,
    required this.simkl,
    required this.library,
    required this.settings,
  });
  final TraktClient trakt;
  final SimklClient simkl;
  final LibraryRepository library;
  AppSettings Function() settings;

  static String? imdbOf(String metaId) {
    final base = metaId.split(':').first;
    return RegExp(r'^tt[0-9]{6,10}$').hasMatch(base) ? base : null;
  }

  Future<void> scrobble(
    String action, {
    required String metaId,
    required String type,
    int? season,
    int? episode,
    required double progress,
  }) async {
    final s = settings();
    final imdb = imdbOf(metaId);
    if (imdb == null || !s.traktScrobble) return;
    try {
      await trakt.scrobble(
        action,
        type: type == 'movie' ? 'movie' : 'series',
        imdb: imdb,
        season: season,
        episode: episode,
        progress: progress,
      );
    } on Object {
      // best effort
    }
  }

  /// A film or episode was finished: Simkl is told (Trakt already knows from the scrobble).
  Future<void> watched({
    required String metaId,
    required String type,
    int? season,
    int? episode,
  }) async {
    final imdb = imdbOf(metaId);
    if (imdb == null || !settings().simklSync) return;
    try {
      await simkl.markWatched(
        type: type == 'movie' ? 'movie' : 'series',
        imdb: imdb,
        season: season,
        episode: episode,
      );
    } on Object {
      // best effort
    }
  }

  Future<void> watchlistAdded(MetaItem meta) async {
    final imdb = imdbOf(meta.id);
    if (imdb == null) return;
    final s = settings();
    try {
      if (s.traktSyncWatchlist) await trakt.addToWatchlist(meta.type, imdb);
      if (s.simklSync) await simkl.addToWatchlist(meta.type, imdb);
    } on Object {
      // best effort
    }
  }

  Future<void> watchlistRemoved(MetaItem meta) async {
    final imdb = imdbOf(meta.id);
    if (imdb == null) return;
    try {
      if (settings().traktSyncWatchlist) {
        await trakt.removeFromWatchlist(meta.type, imdb);
      }
    } on Object {
      // best effort
    }
  }

  /// All'apertura dell'app: se Trakt è collegato e la scelta è accesa, porta qui le novità.
  Future<void> autoSync() async {
    if (!settings().traktSyncOnLaunch || !await trakt.linked) return;
    try {
      await pullTrakt();
    } on Object {
      // best effort
    }
  }

  /// Pulls Trakt into the library. Returns a line for the viewer.
  Future<String> pullTrakt() async {
    final s = settings();
    final pull = await trakt.pull(
      history: s.traktSyncHistory,
      watchlist: s.traktSyncWatchlist,
    );
    if (pull == null) return 'Trakt non è collegato o non risponde.';
    var films = 0, eps = 0, listed = 0;
    for (final m in pull.watchedMovies) {
      if (!library.isWatched(m.imdb)) {
        await library.markWatched(m.imdb, m.imdb, type: 'movie', name: m.name);
        films++;
      }
    }
    for (final e in pull.watchedEpisodes.entries) {
      for (final se in e.value) {
        final parts = se.split(':');
        final id = '${e.key}:${parts[0]}:${parts[1]}';
        if (!library.isWatched(id)) {
          await library.markWatched(
            e.key,
            id,
            type: 'series',
            name: e.key,
            season: int.tryParse(parts[0]),
            episode: int.tryParse(parts[1]),
          );
          eps++;
        }
      }
    }
    for (final w in pull.watchlist) {
      if (!library.isInWatchlist(w.imdb)) {
        await library.toggleWatchlist(
          MetaItem(id: w.imdb, type: w.type, name: w.name),
        );
        listed++;
      }
    }
    // Da Aether a Trakt: ciò che qui risulta visto e Trakt non conosce ancora.
    var pushed = 0;
    if (s.traktSyncHistory) {
      final remoteMovies = {for (final m in pull.watchedMovies) m.imdb};
      final toMovies = <String>[];
      final toEpisodes = <(String, int, int)>[];
      for (final p in library.history.where((p) => p.completed)) {
        final imdb = imdbOf(p.metaId);
        if (imdb == null) continue;
        if (p.type == 'movie') {
          if (!remoteMovies.contains(imdb)) toMovies.add(imdb);
        } else if (p.season != null && p.episode != null && p.season! > 0) {
          final known =
              pull.watchedEpisodes[imdb]?.contains(
                '${p.season}:${p.episode}',
              ) ??
              false;
          if (!known) toEpisodes.add((imdb, p.season!, p.episode!));
        }
      }
      final movies = toMovies.take(300).toList();
      final episodes = toEpisodes.take(300).toList();
      if (await trakt.addHistory(movies: movies, episodes: episodes)) {
        pushed = movies.length + episodes.length;
      }
    }
    return 'Trakt: $films film e $eps episodi segnati come visti, $listed titoli aggiunti alla watchlist; $pushed titoli visti mandati a Trakt.';
  }
}
