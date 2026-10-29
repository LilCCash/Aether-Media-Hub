import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/stores.dart';
import '../model/manifest.dart';
import '../util/app_log.dart';
import 'addon_client.dart';
import 'network_policy.dart';

class InstalledAddon {
  InstalledAddon({
    required this.id,
    required this.base,
    required this.manifest,
    this.enabled = true,
    this.nameOverride,
    Set<String>? hiddenCatalogs,
  }) : hiddenCatalogs = hiddenCatalogs ?? <String>{};

  final String id;
  final Uri base;
  final AddonManifest manifest;
  final bool enabled;
  final String? nameOverride;
  final Set<String> hiddenCatalogs;

  String get displayName => nameOverride ?? manifest.name;

  InstalledAddon copyWith({
    AddonManifest? manifest,
    bool? enabled,
    String? nameOverride,
    bool clearName = false,
    Set<String>? hiddenCatalogs,
  }) => InstalledAddon(
    id: id,
    base: base,
    manifest: manifest ?? this.manifest,
    enabled: enabled ?? this.enabled,
    nameOverride: clearName ? null : (nameOverride ?? this.nameOverride),
    hiddenCatalogs: hiddenCatalogs ?? this.hiddenCatalogs,
  );

  bool isCatalogVisible(ManifestCatalog c) => !hiddenCatalogs.contains(c.key);
}

/// What the user sees before confirming an installation.
class AddonPreview {
  const AddonPreview({
    required this.base,
    required this.manifest,
    required this.warnings,
    this.alreadyInstalled = false,
  });
  final Uri base;
  final AddonManifest manifest;
  final List<String> warnings;
  final bool alreadyInstalled;
}

/// Installed addons, in priority order. Addresses (which can embed the user's configuration) live in the [SecretStore];
/// everything else in the [KeyValueStore].
class AddonRepository {
  AddonRepository({
    required KeyValueStore store,
    required SecretStore secrets,
    required AddonClient client,
  }) : _store = store,
       _secrets = secrets,
       _client = client;

  static const _listKey = 'addons.v1';
  final KeyValueStore _store;
  final SecretStore _secrets;
  final AddonClient _client;
  List<InstalledAddon> _addons = [];

  List<InstalledAddon> get addons => List.unmodifiable(_addons);
  List<InstalledAddon> get enabled => _addons.where((a) => a.enabled).toList();

  Future<void> load() async {
    final raw = await _store.read(_listKey);
    if (raw == null) return;
    final result = <InstalledAddon>[];
    try {
      for (final item in jsonDecode(raw) as List) {
        final map = item as Map;
        final id = map['id'] as String;
        final address = await _secrets.read('addon.$id.url');
        if (address == null) continue;
        final base = Uri.tryParse(address);
        if (base == null) continue;
        try {
          result.add(
            InstalledAddon(
              id: id,
              base: base,
              manifest: AddonManifest.parse(map['manifest']),
              enabled: map['enabled'] as bool? ?? true,
              nameOverride: map['nameOverride'] as String?,
              hiddenCatalogs: ((map['hiddenCatalogs'] as List?) ?? const [])
                  .cast<String>()
                  .toSet(),
            ),
          );
        } on FormatException {
          AppLog.instance.add(
            'addon',
            'Addon $id ignorato: manifest salvato non valido',
          );
        }
      }
    } on Object catch (e) {
      AppLog.instance.add(
        'addon',
        'Elenco addon illeggibile: ${e.runtimeType}',
      );
    }
    _addons = result;
  }

  Future<void> _save() async {
    await _store.write(
      _listKey,
      jsonEncode(
        _addons
            .map(
              (a) => {
                'id': a.id,
                'manifest': a.manifest.toJson(),
                'enabled': a.enabled,
                if (a.nameOverride != null) 'nameOverride': a.nameOverride,
                'hiddenCatalogs': a.hiddenCatalogs.toList(),
              },
            )
            .toList(),
      ),
    );
  }

  /// Downloads and checks the manifest without installing anything.
  Future<AddonPreview> preview(String input, {CancelToken? cancel}) async {
    final base = AddonUrl.parseBase(input);
    if (base == null) {
      throw const AddonException(
        'Non riconosco questo indirizzo: incolla il link del manifest dell’addon.',
      );
    }
    final manifest = await _client.fetchManifest(base, cancel: cancel);
    final warnings = <String>[];
    if (base.scheme == 'http') {
      warnings.add('L’indirizzo non è cifrato (http).');
    }
    if (manifest.behaviorHints.adult) {
      warnings.add('L’addon dichiara contenuti per adulti.');
    }
    if (manifest.behaviorHints.p2p) {
      warnings.add(
        'L’addon usa il peer-to-peer (torrent): serve un servizio debrid per riprodurre.',
      );
    }
    if (manifest.behaviorHints.configurationRequired) {
      warnings.add('L’addon richiede una configurazione prima dell’uso.');
    }
    final existing = _addons.any(
      (a) => a.manifest.id == manifest.id && a.base == base,
    );
    return AddonPreview(
      base: base,
      manifest: manifest,
      warnings: warnings,
      alreadyInstalled: existing,
    );
  }

  Future<InstalledAddon> install(AddonPreview preview) async {
    final duplicate = _addons.where(
      (a) => a.manifest.id == preview.manifest.id && a.base == preview.base,
    );
    if (duplicate.isNotEmpty) return duplicate.first;
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_addons.length}';
    await _secrets.write('addon.$id.url', preview.base.toString());
    final addon = InstalledAddon(
      id: id,
      base: preview.base,
      manifest: preview.manifest,
    );
    _addons = [..._addons, addon];
    await _save();
    return addon;
  }

  Future<void> setEnabled(String id, bool value) =>
      _update(id, (a) => a.copyWith(enabled: value));
  Future<void> rename(String id, String? name) => _update(
    id,
    (a) => (name == null || name.trim().isEmpty)
        ? a.copyWith(clearName: true)
        : a.copyWith(nameOverride: name.trim()),
  );

  Future<void> setCatalogVisible(
    String id,
    ManifestCatalog catalog,
    bool visible,
  ) => _update(id, (a) {
    final hidden = {...a.hiddenCatalogs};
    visible ? hidden.remove(catalog.key) : hidden.add(catalog.key);
    return a.copyWith(hiddenCatalogs: hidden);
  });

  Future<void> remove(String id) async {
    _addons = _addons.where((a) => a.id != id).toList();
    await _secrets.remove('addon.$id.url');
    await _save();
  }

  /// Moves an addon one place earlier (-1) or later (+1): earlier addons have priority.
  Future<void> move(String id, int delta) async {
    final index = _addons.indexWhere((a) => a.id == id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= _addons.length) return;
    final list = [..._addons];
    final item = list.removeAt(index);
    list.insert(target, item);
    _addons = list;
    await _save();
  }

  /// Asks the addon for its manifest again (updated catalogs, version).
  Future<void> refresh(String id, {CancelToken? cancel}) async {
    final addon = _addons.firstWhere((a) => a.id == id);
    final manifest = await _client.fetchManifest(addon.base, cancel: cancel);
    await _update(id, (a) => a.copyWith(manifest: manifest));
  }

  Future<void> _update(
    String id,
    InstalledAddon Function(InstalledAddon) change,
  ) async {
    _addons = _addons.map((a) => a.id == id ? change(a) : a).toList();
    await _save();
  }

  /// Addons that can answer `resource` for this content, in priority order.
  List<InstalledAddon> providers(String resource, String type, String id) =>
      enabled.where((a) => a.manifest.provides(resource, type, id)).toList();
}
