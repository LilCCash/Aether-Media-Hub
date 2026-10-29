import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/image_cache.dart';

import '../core/addons/addon_client.dart';
import '../core/addons/addon_repository.dart';
import '../core/addons/network_policy.dart';
import '../core/metadata/fanart_client.dart';
import '../core/metadata/mdblist_client.dart';
import '../core/metadata/tmdb_client.dart';
import '../core/metadata/tvdb_client.dart';
import '../core/model/manifest.dart';
import '../core/model/meta.dart';
import '../core/model/stream.dart';
import '../core/util/app_log.dart';
import '../data/library_repository.dart';
import '../data/prefs_ext.dart';
import '../data/settings.dart';
import '../data/stores.dart';
import 'services.dart';

final servicesProvider = Provider<AppServices>(
  (ref) => throw UnimplementedError(
    'servicesProvider must be overridden at start-up',
  ),
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(servicesProvider).initialSettings;

  Future<void> update(AppSettings Function(AppSettings) change) async {
    state = change(state);
    final s = ref.read(servicesProvider);
    final policy = NetworkPolicy(allowLocalNetwork: state.allowLocalNetwork);
    s.addonClient.policy = policy;
    s.downloads.policy = policy;
    s.addonClient.cacheEnabled = state.cacheMetadata;
    s.addonClient.minCacheSeconds = state.catalogRefreshMin * 60;
    WatchProgress.threshold = state.watchedThreshold;
    s.downloads.maxConcurrent = state.maxDownloads;
    s.downloads.backgroundNative = state.backgroundDownloads;
    s.downloads.notifyDone = state.notifyDownloads;
    s.downloads.allowCellular = state.downloadOverCellular;
    await s.settingsRepo.save(state);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class AddonsNotifier extends Notifier<List<InstalledAddon>> {
  AddonRepository get _repo => ref.read(servicesProvider).addons;

  @override
  List<InstalledAddon> build() => ref.read(servicesProvider).addons.addons;

  void _sync() => state = _repo.addons;

  /// Re-reads the repository (after a restore that installed addons).
  void reload() => _sync();

  Future<AddonPreview> preview(String input, {CancelToken? cancel}) =>
      _repo.preview(input, cancel: cancel);
  Future<void> install(AddonPreview p) async {
    await _repo.install(p);
    _sync();
  }

  Future<void> setEnabled(String id, bool v) async {
    await _repo.setEnabled(id, v);
    _sync();
  }

  Future<void> rename(String id, String? name) async {
    await _repo.rename(id, name);
    _sync();
  }

  Future<void> setCatalogVisible(String id, ManifestCatalog c, bool v) async {
    await _repo.setCatalogVisible(id, c, v);
    _sync();
  }

  Future<void> remove(String id) async {
    await _repo.remove(id);
    _sync();
  }

  Future<void> move(String id, int delta) async {
    await _repo.move(id, delta);
    _sync();
  }

  Future<void> refresh(String id) async {
    await _repo.refresh(id);
    _sync();
  }
}

final addonsProvider = NotifierProvider<AddonsNotifier, List<InstalledAddon>>(
  AddonsNotifier.new,
);

/// Bumped whenever the library changes (favorites, watchlist, progress), so screens that show it rebuild.
class LibraryVersion extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final libraryVersionProvider = NotifierProvider<LibraryVersion, int>(
  LibraryVersion.new,
);

// Catalogs, meta, streams, search ------------------------------------------------------------------------------------------

class CatalogQuery {
  const CatalogQuery(
    this.addonId,
    this.catalogKey, {
    this.skip = 0,
    this.genre,
    this.search,
  });
  final String addonId;
  final String catalogKey;
  final int skip;
  final String? genre;
  final String? search;

  @override
  bool operator ==(Object other) =>
      other is CatalogQuery &&
      other.addonId == addonId &&
      other.catalogKey == catalogKey &&
      other.skip == skip &&
      other.genre == genre &&
      other.search == search;
  @override
  int get hashCode => Object.hash(addonId, catalogKey, skip, genre, search);
}

final catalogProvider = FutureProvider.autoDispose
    .family<List<MetaItem>, CatalogQuery>((ref, q) async {
      final services = ref.watch(servicesProvider);
      final addons = ref.watch(addonsProvider);
      final addon = addons.where((a) => a.id == q.addonId).firstOrNull;
      if (addon == null) return const [];
      final catalog = addon.manifest.catalogs
          .where((c) => c.key == q.catalogKey)
          .firstOrNull;
      if (catalog == null) return const [];
      final cancel = CancelToken();
      ref.onDispose(() => cancel.cancel());
      final extra = <String, String>{
        if (q.genre != null) 'genre': q.genre!,
        if (q.search != null) 'search': q.search!,
        if (q.skip > 0) 'skip': '${q.skip}',
      };
      final page = await services.addonClient.catalog(
        addon.base,
        catalog,
        extra: extra,
        cancel: cancel,
      );
      return page.items;
    });

class MetaKey {
  const MetaKey(this.type, this.id);
  final String type;
  final String id;
  @override
  bool operator ==(Object other) =>
      other is MetaKey && other.type == type && other.id == id;
  @override
  int get hashCode => Object.hash(type, id);
}

/// The full details of a title from the first addon that has them; null when none answers (the caller keeps the preview).
final metaProvider = FutureProvider.autoDispose.family<MetaItem?, MetaKey>((
  ref,
  key,
) async {
  final services = ref.watch(servicesProvider);
  final addons = ref.watch(addonsProvider);
  final providers = addons
      .where((a) => a.enabled && a.manifest.provides('meta', key.type, key.id))
      .toList();
  final cancel = CancelToken();
  ref.onDispose(() => cancel.cancel());
  for (final addon in providers) {
    try {
      final meta = await services.addonClient.meta(
        addon.base,
        key.type,
        key.id,
        cancel: cancel,
      );
      if (meta != null) return meta;
    } on AddonException catch (e) {
      AppLog.instance.add('meta', '${addon.displayName}: ${e.message}');
    }
  }
  return null;
});

class StreamsKey {
  const StreamsKey(this.type, this.videoId);
  final String type;
  final String videoId;
  @override
  bool operator ==(Object other) =>
      other is StreamsKey && other.type == type && other.videoId == videoId;
  @override
  int get hashCode => Object.hash(type, videoId);
}

class StreamsState {
  const StreamsState({
    this.streams = const [],
    this.subtitles = const [],
    this.pending = const [],
    this.errors = const {},
  });
  final List<AddonStream> streams;
  final List<AddonSubtitle> subtitles;
  final List<String> pending;
  final Map<String, String> errors;
  bool get loading => pending.isNotEmpty;
}

/// Asks every addon that can answer, in parallel, and yields a growing list as each one replies; one slow or broken addon never
/// blocks the others.
final streamsProvider = StreamProvider.autoDispose
    .family<StreamsState, StreamsKey>((ref, key) {
      final services = ref.watch(servicesProvider);
      final addons = ref.watch(addonsProvider);
      final controller = StreamController<StreamsState>();
      final cancel = CancelToken();
      ref.onDispose(() {
        cancel.cancel();
        controller.close();
      });
      final streamAddons = addons
          .where(
            (a) =>
                a.enabled &&
                a.manifest.provides('stream', key.type, key.videoId),
          )
          .toList();
      final subtitleAddons = addons
          .where(
            (a) =>
                a.enabled &&
                a.manifest.provides('subtitles', key.type, key.videoId),
          )
          .toList();
      final results = <String, List<AddonStream>>{};
      final subs = <AddonSubtitle>[];
      final errors = <String, String>{};
      final pending = <String>{
        ...streamAddons.map((a) => a.displayName),
        ...subtitleAddons.map((a) => '${a.displayName} (sottotitoli)'),
      };

      void emit() {
        if (controller.isClosed) return;
        final ordered = <AddonStream>[
          for (final a in streamAddons) ...?results[a.id],
        ];
        controller.add(
          StreamsState(
            streams: ordered,
            subtitles: List.of(subs),
            pending: pending.toList(),
            errors: Map.of(errors),
          ),
        );
      }

      emit();
      for (final addon in streamAddons) {
        unawaited(
          services.addonClient
              .streams(
                addon.base,
                key.type,
                key.videoId,
                addonId: addon.id,
                addonName: addon.displayName,
                cancel: cancel,
              )
              .then((list) {
                results[addon.id] = list;
              })
              .catchError((Object e) {
                errors[addon.displayName] = e is AddonException
                    ? e.message
                    : 'Errore sconosciuto';
              })
              .whenComplete(() {
                pending.remove(addon.displayName);
                emit();
              }),
        );
      }
      for (final addon in subtitleAddons) {
        final label = '${addon.displayName} (sottotitoli)';
        unawaited(
          services.addonClient
              .subtitles(
                addon.base,
                key.type,
                key.videoId,
                addonName: addon.displayName,
                cancel: cancel,
              )
              .then((list) {
                subs.addAll(list);
              })
              .catchError((Object e) {
                errors[label] = e is AddonException
                    ? e.message
                    : 'Errore sconosciuto';
              })
              .whenComplete(() {
                pending.remove(label);
                emit();
              }),
        );
      }
      return controller.stream;
    });

class SearchGroup {
  const SearchGroup(this.addonName, this.catalogName, this.type, this.items);
  final String addonName;
  final String catalogName;
  final String type;
  final List<MetaItem> items;
}

class SearchState {
  const SearchState({
    this.groups = const [],
    this.pending = 0,
    this.errors = const {},
    this.total = 0,
  });
  final List<SearchGroup> groups;
  final int pending;
  final Map<String, String> errors;
  final int total;
  bool get loading => pending > 0;
}

final searchProvider = StreamProvider.autoDispose.family<SearchState, String>((
  ref,
  query,
) {
  final services = ref.watch(servicesProvider);
  final addons = ref.watch(addonsProvider);
  final controller = StreamController<SearchState>();
  final cancel = CancelToken();
  ref.onDispose(() {
    cancel.cancel();
    controller.close();
  });
  final jobs = <(InstalledAddon, ManifestCatalog)>[
    for (final a in addons.where((a) => a.enabled))
      for (final c in a.manifest.catalogs.where((c) => c.isSearchable)) (a, c),
  ];
  final groups = <int, SearchGroup>{};
  final errors = <String, String>{};
  var pending = jobs.length;

  void emit() {
    if (controller.isClosed) return;
    final ordered = (groups.keys.toList()..sort())
        .map((i) => groups[i]!)
        .toList();
    controller.add(
      SearchState(
        groups: ordered,
        pending: pending,
        errors: Map.of(errors),
        total: jobs.length,
      ),
    );
  }

  emit();
  for (var i = 0; i < jobs.length; i++) {
    final (addon, catalog) = jobs[i];
    unawaited(
      services.addonClient
          .catalog(
            addon.base,
            catalog,
            extra: {'search': query},
            cancel: cancel,
          )
          .then((page) {
            if (page.items.isNotEmpty)
              groups[i] = SearchGroup(
                addon.displayName,
                catalog.name,
                catalog.type,
                page.items,
              );
          })
          .catchError((Object e) {
            errors['${addon.displayName} · ${catalog.name}'] =
                e is AddonException ? e.message : 'Errore sconosciuto';
          })
          .whenComplete(() {
            pending--;
            emit();
          }),
    );
  }
  return controller.stream;
});

final tmdbDetailsProvider = FutureProvider.autoDispose
    .family<RichDetails?, String>((ref, imdbId) async {
      final services = ref.watch(servicesProvider);
      if (!imdbId.startsWith('tt') || !ref.read(settingsProvider).tmdbEnabled) {
        return null;
      }
      final lang = ref.read(settingsProvider).language;
      return services.tmdb.details(
        imdbId.split(':').first,
        language: lang == 'it'
            ? 'it-IT'
            : (lang == 'en' ? 'en-US' : '$lang-${lang.toUpperCase()}'),
      );
    });

String _iso3(String iso1) =>
    const {
      'it': 'ita',
      'en': 'eng',
      'fr': 'fra',
      'es': 'spa',
      'de': 'deu',
      'pt': 'por',
      'ja': 'jpn',
    }[iso1] ??
    'eng';

String? _imdbOf(String id) {
  final base = id.split(':').first;
  return RegExp(r'^tt[0-9]{6,10}$').hasMatch(base) ? base : null;
}

/// Titles with the same leading actors: the most popular entries in the filmographies of the first three of the cast, without the
/// title itself. [key] is `tmdbId:actor,actor,actor`.
final sameActorsProvider = FutureProvider.autoDispose
    .family<List<SimilarTitle>, String>((ref, key) async {
      final parts = key.split(':');
      final self = int.tryParse(parts.first);
      final actors = parts.last
          .split(',')
          .map(int.tryParse)
          .whereType<int>()
          .toList();
      if (actors.isEmpty) return const [];
      final services = ref.watch(servicesProvider);
      final lang = ref.read(settingsProvider).language;
      final lists = await Future.wait([
        for (final a in actors)
          services.tmdb
              .filmography(a, language: lang == 'it' ? 'it-IT' : 'en-US')
              .then((v) => v, onError: (_) => const <PersonCredit>[]),
      ]);
      final seen = <int>{if (self != null) self};
      final all = <PersonCredit>[
        for (final l in lists)
          for (final c in l)
            if (c.poster != null && seen.add(c.tmdbId)) c,
      ]..sort((a, b) => b.popularity.compareTo(a.popularity));
      return [
        for (final c in all.take(24))
          SimilarTitle(
            tmdbId: c.tmdbId,
            title: c.title,
            isMovie: c.isMovie,
            year: c.year,
            poster: c.poster,
          ),
      ];
    });

/// Ratings from several services (MDBList) for a title; empty when there is no key or no answer.
final ratingsProvider = FutureProvider.autoDispose
    .family<List<MdbRating>, String>((ref, metaId) async {
      final services = ref.watch(servicesProvider);
      final imdb = _imdbOf(metaId);
      if (imdb == null || !ref.read(settingsProvider).showRatings) {
        return const [];
      }
      if (((await services.secrets.serviceKey(ServiceKey.mdblist)) ?? '')
          .isEmpty) {
        return const [];
      }
      final found = await services.tmdb.findByImdb(imdb);
      if (found == null) return const [];
      return services.mdblist.ratings(found.id, isMovie: found.isMovie);
    });

/// Episode titles and overviews translated by TheTVDB, by "season:episode". Empty without a key.
final tvdbEpisodesProvider = FutureProvider.autoDispose
    .family<Map<String, TvdbEpisode>, String>((ref, metaId) async {
      final services = ref.watch(servicesProvider);
      final settings = ref.read(settingsProvider);
      final imdb = _imdbOf(metaId);
      if (imdb == null || !settings.tvdbEpisodes) return const {};
      if (((await services.secrets.serviceKey(ServiceKey.tvdb)) ?? '')
          .isEmpty) {
        return const {};
      }
      final seriesId = await services.tvdb.seriesIdForImdb(imdb);
      if (seriesId == null) return const {};
      final episodes = await services.tvdb.episodes(
        seriesId,
        _iso3(settings.language),
      );
      return {for (final e in episodes) '${e.season}:${e.number}': e};
    });

/// The transparent logo of a title: fanart.tv first (films by IMDb code, then by TMDB code; series by TheTVDB code), then TMDB's
/// own artwork, as the iOS app does. A logo found once is remembered on the device and its picture is kept in the image cache,
/// so the next time it is there at once; a title without one is not asked again until the app restarts.
final logoProvider =
    FutureProvider.family<String?, ({String metaId, bool isMovie})>((
      ref,
      key,
    ) async {
      final services = ref.watch(servicesProvider);
      final imdb = _imdbOf(key.metaId);
      if (imdb == null) return null;
      final storeKey = 'logo.v1.${key.metaId}';
      final saved = await services.store.read(storeKey);
      if (saved != null && saved.isNotEmpty) {
        unawaited(
          AetherImageCache.manager
              .downloadFile(saved)
              .then((_) {}, onError: (_) {}),
        );
        return saved;
      }
      final lang = ref.read(settingsProvider).language;
      String? url;
      try {
        if (((await services.secrets.serviceKey(ServiceKey.fanart)) ?? '')
            .isNotEmpty) {
          if (key.isMovie) {
            url = await services.fanart.logoUrl(FanartKind.movie, imdb, lang);
            if (url == null) {
              final found = await services.tmdb.findByImdb(imdb);
              if (found != null) {
                url = await services.fanart.logoUrl(
                  FanartKind.movie,
                  '${found.id}',
                  lang,
                );
              }
            }
          } else {
            final found = await services.tmdb.findByImdb(imdb);
            final tvdb = found == null
                ? null
                : await services.tmdb.tvdbIdOf(found.id);
            if (tvdb != null) {
              url = await services.fanart.logoUrl(FanartKind.tv, '$tvdb', lang);
            }
          }
        }
        url ??= await services.tmdb.logoUrl(imdb, language: lang);
      } on Object {
        return null;
      }
      if (url != null) {
        await services.store.write(storeKey, url);
        unawaited(
          AetherImageCache.manager
              .downloadFile(url)
              .then((_) {}, onError: (_) {}),
        );
      }
      return url;
    });

/// Alternative posters of a title (TMDB), for the «Cambia locandina» sheet.
final alternatePostersProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, metaId) async {
      final imdb = _imdbOf(metaId);
      if (imdb == null) return const [];
      final lang = ref.read(settingsProvider).language;
      try {
        return await ref
            .read(servicesProvider)
            .tmdb
            .posters(imdb, language: lang);
      } on Object {
        return const [];
      }
    });
