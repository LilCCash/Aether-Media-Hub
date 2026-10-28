import '../util/lenient.dart';

class AddonSubtitle {
  const AddonSubtitle({required this.id, required this.url, required this.lang, this.addonName});

  final String id;
  final String url;
  final String lang;
  final String? addonName;

  static AddonSubtitle? parse(Object? raw, {String? addonName}) {
    final map = asMap(raw);
    final url = asNonEmptyString(map?['url']);
    if (map == null || url == null) return null;
    return AddonSubtitle(id: asNonEmptyString(map['id']) ?? url, url: url, lang: asNonEmptyString(map['lang']) ?? 'und', addonName: addonName);
  }
}

/// A source for a title as an addon describes it (https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/stream.md).
class AddonStream {
  const AddonStream({
    this.url,
    this.infoHash,
    this.fileIdx,
    this.ytId,
    this.externalUrl,
    this.name,
    this.description,
    this.trackers = const [],
    this.bingeGroup,
    this.filename,
    this.videoSize,
    this.notWebReady = false,
    this.proxyHeaders = const {},
    this.subtitles = const [],
    this.addonId,
    this.addonName,
  });

  final String? url;
  final String? infoHash;
  final int? fileIdx;
  final String? ytId;
  final String? externalUrl;
  final String? name;
  final String? description;
  final List<String> trackers;
  final String? bingeGroup;
  final String? filename;
  final int? videoSize;
  final bool notWebReady;
  final Map<String, String> proxyHeaders;
  final List<AddonSubtitle> subtitles;
  final String? addonId;
  final String? addonName;

  bool get isDirect => url != null && (url!.startsWith('http://') || url!.startsWith('https://'));
  bool get isTorrent => infoHash != null && infoHash!.isNotEmpty;

  /// Text the analyzer reads: addons put the interesting words in `name`, `title` or `description`.
  String get searchText => [name, description, filename, _urlFileName].whereType<String>().join(' ');

  String? get _urlFileName {
    final raw = url;
    if (raw == null) return null;
    final segments = Uri.tryParse(raw)?.pathSegments ?? const <String>[];
    if (segments.isEmpty) return null;
    return segments.last.isEmpty ? null : segments.last;
  }

  String get magnet {
    final hash = infoHash ?? '';
    final tr = trackers.map((t) => '&tr=${Uri.encodeQueryComponent(t)}').join();
    return 'magnet:?xt=urn:btih:$hash$tr';
  }

  static AddonStream? parse(Object? raw, {String? addonId, String? addonName}) {
    final map = asMap(raw);
    if (map == null) return null;
    final url = asNonEmptyString(map['url']);
    final hash = asNonEmptyString(map['infoHash']);
    final yt = asNonEmptyString(map['ytId']);
    final external = asNonEmptyString(map['externalUrl']);
    if (url == null && hash == null && yt == null && external == null) return null;
    final hints = asMap(map['behaviorHints']) ?? const {};
    final headers = <String, String>{};
    final request = asMap(asMap(hints['proxyHeaders'])?['request']);
    request?.forEach((k, v) {
      final value = asNonEmptyString(v);
      if (value != null) headers[k] = value;
    });
    final trackers = <String>[];
    for (final item in asStringList(map['sources'])) {
      if (item.startsWith('tracker:')) trackers.add(item.substring(8));
    }
    final subs = <AddonSubtitle>[];
    for (final item in asList(map['subtitles'])) {
      final s = AddonSubtitle.parse(item, addonName: addonName);
      if (s != null) subs.add(s);
    }
    return AddonStream(
      url: url,
      infoHash: hash?.toLowerCase(),
      fileIdx: asInt(map['fileIdx']),
      ytId: yt,
      externalUrl: external,
      name: asNonEmptyString(map['name']),
      description: asNonEmptyString(map['description']) ?? asNonEmptyString(map['title']),
      trackers: trackers,
      bingeGroup: asNonEmptyString(hints['bingeGroup']),
      filename: asNonEmptyString(hints['filename']),
      videoSize: asInt(hints['videoSize']),
      notWebReady: asBool(hints['notWebReady']),
      proxyHeaders: headers,
      subtitles: subs,
      addonId: addonId,
      addonName: addonName,
    );
  }
}
