import 'dart:convert';

import '../app/services.dart';
import '../core/util/lenient.dart';
import 'settings.dart';
import 'stores.dart';

/// Export / import of the viewer's data as one JSON document. Service keys and addon addresses (which can carry the viewer's own
/// configuration) are secrets: they go in only when the viewer asks, and the file is then clearly a secret too.
class BackupService {
  BackupService(this.services);
  final AppServices services;

  static const format = 'app.aether.backup';

  Future<String> export({
    required AppSettings settings,
    bool includeKeys = false,
    bool includeAddonAddresses = false,
  }) async {
    final keys = <String, String>{};
    if (includeKeys) {
      for (final k in ServiceKey.values) {
        final v = await services.secrets.serviceKey(k);
        if (v != null && v.isNotEmpty) keys[k.name] = v;
      }
    }
    final doc = {
      'format': format,
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'settings': settings.toJson(),
      'library': services.library.exportJson(),
      if (includeAddonAddresses)
        'addons': services.addons.addons.map((a) => a.base.toString()).toList(),
      if (includeKeys) 'serviceKeys': keys,
    };
    return const JsonEncoder.withIndent('  ').convert(doc);
  }

  /// Reads a backup and applies it. Returns what was restored; throws [FormatException] for something that is not a backup.
  Future<RestoreSummary> restore(
    String text, {
    required Future<void> Function(AppSettings) applySettings,
  }) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException(
        'Il testo non è un backup di Aether (JSON non valido).',
      );
    }
    final doc = asMap(decoded);
    if (doc == null || asString(doc['format']) != format)
      throw const FormatException('Questo non è un backup di Aether.');
    var settingsRestored = false;
    if (doc['settings'] != null) {
      await applySettings(AppSettings.fromJson(doc['settings']));
      settingsRestored = true;
    }
    final before =
        services.library.history.length +
        services.library.favorites.length +
        services.library.watchlist.length;
    if (doc['library'] != null)
      await services.library.importJson(doc['library']);
    final after =
        services.library.history.length +
        services.library.favorites.length +
        services.library.watchlist.length;
    var keys = 0;
    final keyMap = asMap(doc['serviceKeys']);
    if (keyMap != null) {
      for (final k in ServiceKey.values) {
        final v = asNonEmptyString(keyMap[k.name]);
        if (v != null) {
          await services.secrets.setServiceKey(k, v);
          keys++;
        }
      }
    }
    final addonAddresses = asStringList(doc['addons']);
    var addons = 0;
    final problems = <String>[];
    for (final address in addonAddresses) {
      try {
        await services.addons.install(await services.addons.preview(address));
        addons++;
      } on Object catch (e) {
        problems.add('${Uri.tryParse(address)?.host ?? 'addon'}: $e');
      }
    }
    return RestoreSummary(
      settings: settingsRestored,
      libraryItems: after - before,
      keys: keys,
      addons: addons,
      addonProblems: problems,
    );
  }
}

class RestoreSummary {
  const RestoreSummary({
    required this.settings,
    required this.libraryItems,
    required this.keys,
    required this.addons,
    required this.addonProblems,
  });
  final bool settings;
  final int libraryItems;
  final int keys;
  final int addons;
  final List<String> addonProblems;
}
