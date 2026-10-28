import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/addons/addon_client.dart';
import '../core/util/app_log.dart';
import '../core/addons/addon_repository.dart';
import '../core/addons/network_policy.dart';
import '../core/debrid/debrid_provider.dart';
import '../core/debrid/debrid_resolver.dart';
import '../core/debrid/real_debrid_client.dart';
import '../core/debrid/torbox_client.dart';
import '../core/metadata/fanart_client.dart';
import '../core/metadata/mdblist_client.dart';
import '../core/metadata/tvdb_client.dart';
import '../core/segments/skip_segments.dart';
import '../core/metadata/tmdb_client.dart';
import '../core/streams/badge_pack_loader.dart';
import '../core/subtitles/subtitle_loader.dart';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../data/library_repository.dart';
import '../data/prefs_ext.dart';
import '../data/settings.dart';
import '../data/stores.dart';
import '../features/downloads/download_manager.dart';

/// Everything that talks to storage or the network, created once at start-up. The UI reads it through providers; tests build
/// their own with in-memory stores and fake HTTP.
class AppServices {
  AppServices({
    required this.store,
    required this.secrets,
    required this.addonClient,
    required this.addons,
    required this.library,
    required this.settingsRepo,
    required this.torbox,
    required this.tmdb,
    required this.realDebrid,
    required this.tvdb,
    required this.mdblist,
    required this.fanart,
    required this.skipSegments,
    required this.badgeLoader,
    required this.subtitleLoader,
    required this.downloads,
    required this.initialSettings,
  });

  final KeyValueStore store;
  final SecretStore secrets;
  final AddonClient addonClient;
  final AddonRepository addons;
  final LibraryRepository library;
  final SettingsRepository settingsRepo;
  final TorBoxClient torbox;
  final TmdbClient tmdb;
  final RealDebridClient realDebrid;
  final TvdbClient tvdb;
  final MdbListClient mdblist;
  final FanartClient fanart;
  final SkipSegmentsService skipSegments;
  final BadgePackLoader badgeLoader;
  final SubtitleLoader subtitleLoader;
  final DownloadManager downloads;
  final AppSettings initialSettings;

  /// The debrid service to use: the one chosen in the settings when its key is stored, else the other one if that has a key.
  Future<DebridProvider?> activeDebrid(AppSettings settings) async {
    Future<bool> has(ServiceKey k) async =>
        ((await secrets.serviceKey(k)) ?? '').isNotEmpty;
    final order = settings.debridProvider == 'realdebrid'
        ? const [ServiceKey.realdebrid, ServiceKey.torbox]
        : const [ServiceKey.torbox, ServiceKey.realdebrid];
    for (final k in order) {
      if (await has(k)) {
        return k == ServiceKey.torbox ? DebridResolver(torbox) : realDebrid;
      }
    }
    return null;
  }

  /// «Elimina tutti i dati locali»: library, addons, downloads, search history, settings and every stored key.
  Future<void> wipe() async {
    await library.clearAll();
    for (final a in [...addons.addons]) {
      await addons.remove(a.id);
    }
    for (final d in [...downloads.items]) {
      await downloads.remove(d.id);
    }
    await store.remove('search.recent.v1');
    await store.remove(SettingsRepository.key);
    for (final k in ServiceKey.values) {
      await secrets.setServiceKey(k, null);
    }
  }

  static Future<AppServices> create() async {
    final prefs = await SharedPreferences.getInstance();
    return build(
      store: PrefsStore(prefs),
      secrets: PlatformSecretStore(),
      downloadsDir: Directory(
        '${(await getApplicationDocumentsDirectory()).path}/downloads',
      ),
    );
  }

  static Future<AppServices> build({
    required KeyValueStore store,
    required SecretStore secrets,
    required Directory downloadsDir,
    Dio? dio,
  }) async {
    final settingsRepo = SettingsRepository(store);
    final settings = await settingsRepo.load();
    final policy = NetworkPolicy(allowLocalNetwork: settings.allowLocalNetwork);
    final client = AddonClient(dio: dio, policy: policy);
    final addons = AddonRepository(
      store: store,
      secrets: secrets,
      client: client,
    );
    await addons.load();
    final library = LibraryRepository(store);
    await library.load();
    final downloads = DownloadManager(
      store: store,
      directory: downloadsDir,
      dio: dio,
      policy: policy,
    );
    await downloads.load();
    WatchProgress.threshold = settings.watchedThreshold;
    AppLog.instance.enabled = settings.keepLog;
    downloads.maxConcurrent = settings.maxDownloads;
    downloads.allowCellular = settings.downloadOverCellular;
    downloads.networkAllowed = () async {
      if (downloads.allowCellular) return true;
      try {
        final r = await Connectivity().checkConnectivity();
        return !r.contains(ConnectivityResult.mobile) ||
            r.contains(ConnectivityResult.wifi) ||
            r.contains(ConnectivityResult.ethernet);
      } on Object {
        return true;
      }
    };
    return AppServices(
      store: store,
      secrets: secrets,
      addonClient: client,
      addons: addons,
      library: library,
      settingsRepo: settingsRepo,
      torbox: TorBoxClient(
        keyProvider: () => secrets.serviceKey(ServiceKey.torbox),
        dio: dio,
      ),
      tmdb: TmdbClient(
        keyProvider: () => secrets.serviceKey(ServiceKey.tmdb),
        dio: dio,
      ),
      realDebrid: RealDebridClient(
        keyProvider: () => secrets.serviceKey(ServiceKey.realdebrid),
        dio: dio,
      ),
      tvdb: TvdbClient(
        keyProvider: () => secrets.serviceKey(ServiceKey.tvdb),
        pinProvider: () => secrets.serviceKey(ServiceKey.tvdbPin),
        dio: dio,
      ),
      mdblist: MdbListClient(
        keyProvider: () => secrets.serviceKey(ServiceKey.mdblist),
        dio: dio,
      ),
      fanart: FanartClient(
        keyProvider: () => secrets.serviceKey(ServiceKey.fanart),
        dio: dio,
      ),
      skipSegments: SkipSegmentsService(IntroDbClient(dio: dio)),
      badgeLoader: BadgePackLoader(dio: dio, policy: policy),
      subtitleLoader: SubtitleLoader(dio: dio, policy: policy),
      downloads: downloads,
      initialSettings: settings,
    );
  }
}
