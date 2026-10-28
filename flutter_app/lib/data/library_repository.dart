import 'dart:convert';

import '../core/model/meta.dart';
import '../core/util/lenient.dart';
import 'stores.dart';

/// How far the viewer got in one video (a film, or one episode).
class WatchProgress {
  const WatchProgress({
    required this.metaId,
    required this.videoId,
    required this.type,
    required this.name,
    this.poster,
    this.season,
    this.episode,
    this.episodeTitle,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  final String metaId;
  final String videoId;
  final String type;
  final String name;
  final String? poster;
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  double get fraction => durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0, 1).toDouble();

  /// Watched when 92% (or the last 3 minutes) is behind.
  bool get completed => durationMs > 0 && (fraction >= 0.92 || durationMs - positionMs < 180000 && fraction > 0.5);

  bool get resumable => !completed && positionMs >= 10000;

  Map<String, Object?> toJson() => {
        'metaId': metaId,
        'videoId': videoId,
        'type': type,
        'name': name,
        if (poster != null) 'poster': poster,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
        if (episodeTitle != null) 'episodeTitle': episodeTitle,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static WatchProgress? fromJson(Object? raw) {
    final m = asMap(raw);
    final metaId = asNonEmptyString(m?['metaId']);
    final videoId = asNonEmptyString(m?['videoId']);
    if (m == null || metaId == null || videoId == null) return null;
    return WatchProgress(
      metaId: metaId,
      videoId: videoId,
      type: asNonEmptyString(m['type']) ?? 'movie',
      name: asNonEmptyString(m['name']) ?? metaId,
      poster: asNonEmptyString(m['poster']),
      season: asInt(m['season']),
      episode: asInt(m['episode']),
      episodeTitle: asNonEmptyString(m['episodeTitle']),
      positionMs: asInt(m['positionMs']) ?? 0,
      durationMs: asInt(m['durationMs']) ?? 0,
      updatedAt: asDate(m['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Favorites, watchlist and watch history, persisted as JSON.
class LibraryRepository {
  LibraryRepository(this._store);
  static const _key = 'library.v1';

  final KeyValueStore _store;
  final Map<String, MetaItem> _favorites = {};
  final Map<String, MetaItem> _watchlist = {};
  final Map<String, WatchProgress> _progress = {}; // by videoId
  final Map<String, DateTime> _lastSeen = {}; // metaId -> last time watched

  Future<void> load() async {
    final raw = await _store.read(_key);
    if (raw == null) return;
    try {
      final m = asMap(jsonDecode(raw)) ?? const {};
      for (final item in asList(m['favorites'])) {
        final meta = MetaItem.parse(item);
        if (meta != null) _favorites[meta.id] = meta;
      }
      for (final item in asList(m['watchlist'])) {
        final meta = MetaItem.parse(item);
        if (meta != null) _watchlist[meta.id] = meta;
      }
      for (final item in asList(m['progress'])) {
        final p = WatchProgress.fromJson(item);
        if (p != null) {
          _progress[p.videoId] = p;
          final seen = _lastSeen[p.metaId];
          if (seen == null || p.updatedAt.isAfter(seen)) _lastSeen[p.metaId] = p.updatedAt;
        }
      }
    } on FormatException {
      // A damaged file starts an empty library rather than blocking the app.
    }
  }

  Future<void> _save() => _store.write(
        _key,
        jsonEncode({
          'favorites': _favorites.values.map((e) => e.toJson()).toList(),
          'watchlist': _watchlist.values.map((e) => e.toJson()).toList(),
          'progress': _progress.values.map((e) => e.toJson()).toList(),
        }),
      );

  List<MetaItem> get favorites => _favorites.values.toList().reversed.toList();
  List<MetaItem> get watchlist => _watchlist.values.toList().reversed.toList();
  bool isFavorite(String id) => _favorites.containsKey(id);
  bool isInWatchlist(String id) => _watchlist.containsKey(id);

  Future<bool> toggleFavorite(MetaItem meta) async {
    final added = !_favorites.containsKey(meta.id);
    added ? _favorites[meta.id] = meta.preview : _favorites.remove(meta.id);
    await _save();
    return added;
  }

  Future<bool> toggleWatchlist(MetaItem meta) async {
    final added = !_watchlist.containsKey(meta.id);
    added ? _watchlist[meta.id] = meta.preview : _watchlist.remove(meta.id);
    await _save();
    return added;
  }

  WatchProgress? progressOf(String videoId) => _progress[videoId];

  Future<void> saveProgress(WatchProgress p) async {
    _progress[p.videoId] = p;
    _lastSeen[p.metaId] = p.updatedAt;
    await _save();
  }

  Future<void> markWatched(String metaId, String videoId, {required String type, required String name, String? poster, int? season, int? episode, bool watched = true}) async {
    if (!watched) {
      _progress.remove(videoId);
    } else {
      final now = DateTime.now();
      _progress[videoId] = WatchProgress(
        metaId: metaId, videoId: videoId, type: type, name: name, poster: poster, season: season, episode: episode,
        positionMs: 1000, durationMs: 1000, updatedAt: now,
      );
      _lastSeen[metaId] = now;
    }
    await _save();
  }

  bool isWatched(String videoId) => _progress[videoId]?.completed ?? false;

  /// History, most recent first.
  List<WatchProgress> get history => _progress.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// One entry per title: the video to resume, most recent first. Finished films are left out; for a series, a finished episode
  /// is left out too (the "next episode" logic proposes the following one).
  List<WatchProgress> get continueWatching {
    final byMeta = <String, WatchProgress>{};
    for (final p in history) {
      if (!byMeta.containsKey(p.metaId)) byMeta[p.metaId] = p;
    }
    return byMeta.values.where((p) => p.resumable).toList();
  }

  Future<void> removeFromHistory(String videoId) async {
    _progress.remove(videoId);
    await _save();
  }

  Future<void> clearHistory() async {
    _progress.clear();
    _lastSeen.clear();
    await _save();
  }

  // Backup support ------------------------------------------------------------------------------------------------------

  Map<String, Object?> exportJson() => {
        'favorites': _favorites.values.map((e) => e.toJson()).toList(),
        'watchlist': _watchlist.values.map((e) => e.toJson()).toList(),
        'progress': _progress.values.map((e) => e.toJson()).toList(),
      };

  Future<void> importJson(Object? raw) async {
    final m = asMap(raw) ?? const {};
    for (final item in asList(m['favorites'])) {
      final meta = MetaItem.parse(item);
      if (meta != null) _favorites[meta.id] = meta;
    }
    for (final item in asList(m['watchlist'])) {
      final meta = MetaItem.parse(item);
      if (meta != null) _watchlist[meta.id] = meta;
    }
    for (final item in asList(m['progress'])) {
      final p = WatchProgress.fromJson(item);
      if (p != null) {
        final existing = _progress[p.videoId];
        if (existing == null || p.updatedAt.isAfter(existing.updatedAt)) _progress[p.videoId] = p;
      }
    }
    await _save();
  }
}
