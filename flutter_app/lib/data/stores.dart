import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Plain, non-secret persistence (settings, library, addon list without addresses).
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class PrefsStore implements KeyValueStore {
  PrefsStore(this._prefs);
  final SharedPreferences _prefs;

  @override
  Future<String?> read(String key) async => _prefs.getString(key);
  @override
  Future<void> write(String key, String value) async =>
      _prefs.setString(key, value);
  @override
  Future<void> remove(String key) async => _prefs.remove(key);
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
}

/// Secrets: service keys and addon addresses (they can carry the user's own configuration). Keychain on iOS, Keystore-backed
/// encrypted preferences on Android. Never logged, never part of a backup unless the user asks for it.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class PlatformSecretStore implements SecretStore {
  PlatformSecretStore()
    : _storage = const FlutterSecureStorage(
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> remove(String key) => _storage.delete(key: key);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
}

/// The services the user can connect with their own key.
enum ServiceKey {
  torbox,
  realdebrid,
  tmdb,
  tvdb,
  tvdbPin,
  mdblist,
  fanart,
  traktClient,
  traktSecret,
  traktToken,
  simklClient,
  simklToken,
}

extension ServiceKeyStorage on SecretStore {
  Future<String?> serviceKey(ServiceKey k) => read('service.${k.name}');
  Future<void> setServiceKey(ServiceKey k, String? value) async {
    final v = value?.trim();
    if (v == null || v.isEmpty) {
      await remove('service.${k.name}');
    } else {
      await write('service.${k.name}', v);
    }
  }
}
