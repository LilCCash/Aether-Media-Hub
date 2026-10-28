import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/addons/addon_client.dart';
import '../core/addons/addon_repository.dart';
import '../core/addons/network_policy.dart';
import '../core/debrid/torbox_client.dart';
import '../core/metadata/tmdb_client.dart';
import '../core/subtitles/subtitle_loader.dart';
import '../data/library_repository.dart';
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
  final SubtitleLoader subtitleLoader;
  final DownloadManager downloads;
  final AppSettings initialSettings;

  static Future<AppServices> create() async {
    final prefs = await SharedPreferences.getInstance();
    return build(store: PrefsStore(prefs), secrets: PlatformSecretStore(), downloadsDir: Directory('${(await getApplicationDocumentsDirectory()).path}/downloads'));
  }

  static Future<AppServices> build({required KeyValueStore store, required SecretStore secrets, required Directory downloadsDir, Dio? dio}) async {
    final settingsRepo = SettingsRepository(store);
    final settings = await settingsRepo.load();
    final policy = NetworkPolicy(allowLocalNetwork: settings.allowLocalNetwork);
    final client = AddonClient(dio: dio, policy: policy);
    final addons = AddonRepository(store: store, secrets: secrets, client: client);
    await addons.load();
    final library = LibraryRepository(store);
    await library.load();
    final downloads = DownloadManager(store: store, directory: downloadsDir, dio: dio, policy: policy);
    await downloads.load();
    return AppServices(
      store: store,
      secrets: secrets,
      addonClient: client,
      addons: addons,
      library: library,
      settingsRepo: settingsRepo,
      torbox: TorBoxClient(keyProvider: () => secrets.serviceKey(ServiceKey.torbox), dio: dio),
      tmdb: TmdbClient(keyProvider: () => secrets.serviceKey(ServiceKey.tmdb), dio: dio),
      subtitleLoader: SubtitleLoader(dio: dio, policy: policy),
      downloads: downloads,
      initialSettings: settings,
    );
  }
}
