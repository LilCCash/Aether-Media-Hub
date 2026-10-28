import '../util/lenient.dart';

/// One resource an addon declares (`catalog`, `meta`, `stream`, `subtitles`, ...), optionally restricted by type / id prefix.
class ManifestResource {
  const ManifestResource({required this.name, this.types = const [], this.idPrefixes = const []});

  final String name;
  final List<String> types;
  final List<String> idPrefixes;

  static ManifestResource? parse(Object? raw) {
    if (raw is String) return raw.trim().isEmpty ? null : ManifestResource(name: raw.trim());
    final map = asMap(raw);
    final name = asNonEmptyString(map?['name']);
    if (map == null || name == null) return null;
    return ManifestResource(name: name, types: asStringList(map['types']), idPrefixes: asStringList(map['idPrefixes']));
  }

  Map<String, Object?> toJson() => {'name': name, if (types.isNotEmpty) 'types': types, if (idPrefixes.isNotEmpty) 'idPrefixes': idPrefixes};
}

/// An extra property of a catalog (`search`, `genre`, `skip`, ...).
class ExtraProperty {
  const ExtraProperty({required this.name, this.isRequired = false, this.options = const []});

  final String name;
  final bool isRequired;
  final List<String> options;

  static ExtraProperty? parse(Object? raw) {
    final map = asMap(raw);
    final name = asNonEmptyString(map?['name']);
    if (map == null || name == null) return null;
    return ExtraProperty(name: name, isRequired: asBool(map['isRequired']), options: asStringList(map['options']));
  }

  Map<String, Object?> toJson() => {'name': name, 'isRequired': isRequired, if (options.isNotEmpty) 'options': options};
}

class ManifestCatalog {
  const ManifestCatalog({required this.type, required this.id, required this.name, this.extra = const []});

  final String type;
  final String id;
  final String name;
  final List<ExtraProperty> extra;

  /// Identity inside one addon: the same `id` can exist for two types.
  String get key => '$type/$id';

  bool supports(String extraName) => extra.any((e) => e.name == extraName);

  List<String> get genres => extra.where((e) => e.name == 'genre').expand((e) => e.options).toList();

  /// A plain feed can be listed with no extra at all (nothing required).
  bool get isBrowsable => extra.every((e) => !e.isRequired || e.name == 'skip');

  /// It can answer a text search (declares `search`, and requires nothing else).
  bool get isSearchable => supports('search') && extra.every((e) => !e.isRequired || e.name == 'search' || e.name == 'skip');

  static ManifestCatalog? parse(Object? raw) {
    final map = asMap(raw);
    final type = asNonEmptyString(map?['type']);
    final id = asNonEmptyString(map?['id']);
    if (map == null || type == null || id == null) return null;
    final extra = <ExtraProperty>[];
    for (final item in asList(map['extra'])) {
      final parsed = ExtraProperty.parse(item);
      if (parsed != null) extra.add(parsed);
    }
    // Legacy manifests: `extraSupported` / `extraRequired` name lists.
    if (extra.isEmpty) {
      final required = asStringList(map['extraRequired']).toSet();
      for (final name in asStringList(map['extraSupported'])) {
        extra.add(ExtraProperty(name: name, isRequired: required.contains(name)));
      }
    }
    return ManifestCatalog(type: type, id: id, name: asNonEmptyString(map['name']) ?? id, extra: extra);
  }

  Map<String, Object?> toJson() => {'type': type, 'id': id, 'name': name, 'extra': extra.map((e) => e.toJson()).toList()};
}

class BehaviorHints {
  const BehaviorHints({this.configurable = false, this.configurationRequired = false, this.adult = false, this.p2p = false});

  final bool configurable;
  final bool configurationRequired;
  final bool adult;
  final bool p2p;

  static BehaviorHints parse(Object? raw) {
    final map = asMap(raw);
    if (map == null) return const BehaviorHints();
    return BehaviorHints(
      configurable: asBool(map['configurable']),
      configurationRequired: asBool(map['configurationRequired']),
      adult: asBool(map['adult']),
      p2p: asBool(map['p2p']),
    );
  }

  Map<String, Object?> toJson() => {'configurable': configurable, 'configurationRequired': configurationRequired, 'adult': adult, 'p2p': p2p};
}

/// Stremio addon manifest (https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/manifest.md).
class AddonManifest {
  const AddonManifest({
    required this.id,
    required this.name,
    this.version = '0.0.0',
    this.description,
    this.logo,
    this.background,
    this.types = const [],
    this.idPrefixes = const [],
    this.resources = const [],
    this.catalogs = const [],
    this.behaviorHints = const BehaviorHints(),
  });

  final String id;
  final String name;
  final String version;
  final String? description;
  final String? logo;
  final String? background;
  final List<String> types;
  final List<String> idPrefixes;
  final List<ManifestResource> resources;
  final List<ManifestCatalog> catalogs;
  final BehaviorHints behaviorHints;

  /// Throws [FormatException] with a readable reason when the document is not a usable manifest.
  static AddonManifest parse(Object? raw) {
    final map = asMap(raw);
    if (map == null) throw const FormatException('Il manifest non è un oggetto JSON.');
    final id = asNonEmptyString(map['id']);
    final name = asNonEmptyString(map['name']);
    if (id == null) throw const FormatException('Nel manifest manca «id».');
    if (name == null) throw const FormatException('Nel manifest manca «name».');
    final resources = <ManifestResource>[];
    for (final item in asList(map['resources'])) {
      final parsed = ManifestResource.parse(item);
      if (parsed != null) resources.add(parsed);
    }
    final catalogs = <ManifestCatalog>[];
    for (final item in asList(map['catalogs'])) {
      final parsed = ManifestCatalog.parse(item);
      if (parsed != null) catalogs.add(parsed);
    }
    if (resources.isEmpty && catalogs.isEmpty) {
      throw const FormatException('Il manifest non dichiara né risorse né cataloghi.');
    }
    return AddonManifest(
      id: id,
      name: name,
      version: asNonEmptyString(map['version']) ?? '0.0.0',
      description: asNonEmptyString(map['description']),
      logo: asNonEmptyString(map['logo']),
      background: asNonEmptyString(map['background']),
      types: asStringList(map['types']),
      idPrefixes: asStringList(map['idPrefixes']),
      resources: resources,
      catalogs: catalogs,
      behaviorHints: BehaviorHints.parse(map['behaviorHints']),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        if (description != null) 'description': description,
        if (logo != null) 'logo': logo,
        if (background != null) 'background': background,
        'types': types,
        if (idPrefixes.isNotEmpty) 'idPrefixes': idPrefixes,
        'resources': resources.map((r) => r.toJson()).toList(),
        'catalogs': catalogs.map((c) => c.toJson()).toList(),
        'behaviorHints': behaviorHints.toJson(),
      };

  ManifestResource? resource(String name) {
    for (final r in resources) {
      if (r.name == name) return r;
    }
    return null;
  }

  /// Whether the addon can answer `resource` for this content `type` and `id`
  /// (resource-level `types` / `idPrefixes` win over the manifest-level ones).
  bool provides(String resourceName, String type, String id) {
    final resource = this.resource(resourceName);
    if (resource == null) return false;
    final types = resource.types.isNotEmpty ? resource.types : this.types;
    if (types.isNotEmpty && !types.contains(type)) return false;
    final prefixes = resource.idPrefixes.isNotEmpty ? resource.idPrefixes : idPrefixes;
    if (prefixes.isNotEmpty && !prefixes.any(id.startsWith)) return false;
    return true;
  }
}
