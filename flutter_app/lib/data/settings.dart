import 'dart:convert';

import '../core/streams/badge_pack.dart';
import '../core/util/lenient.dart';
import 'stores.dart';

const Object _keep = Object();

/// Everything the viewer can change. Decoding is lenient: a missing or damaged field falls back to its default.
class AppSettings {
  const AppSettings({
    this.language = 'it',
    this.audioLanguage = 'ita',
    this.subtitleLanguage = 'ita',
    this.subtitlesEnabledByDefault = true,
    this.subtitleScale = 1.0,
    this.subtitleOffsetMs = 0,
    this.removeHearingImpaired = false,
    this.playbackSpeed = 1.0,
    this.autoplayNext = true,
    this.resumePlayback = true,
    this.allowLocalNetwork = false,
    this.hideAdultCatalogs = true,
    this.glassIntensity = 1.0,
    this.reduceEffects = false,
    this.amoled = false,
    this.accentHex = '#7C8CFF',
    this.cinematic = true,
    this.onboardingDone = false,
    this.hiddenHomeCatalogs = const [],
    this.catalogTitles = const {},
    this.catalogOrder = const [],
    this.showContinueWatching = true,
    this.preferredStreamLanguage = 'Italiano',
    this.debridProvider = 'torbox',
    this.skipIntro = true,
    this.showRatings = true,
    this.tvdbEpisodes = true,
    this.customBadges = const [],
    this.customBadgesUrl,
  });

  final String language;
  final String audioLanguage;
  final String subtitleLanguage;
  final bool subtitlesEnabledByDefault;
  final double subtitleScale;
  final int subtitleOffsetMs;
  final bool removeHearingImpaired;
  final double playbackSpeed;
  final bool autoplayNext;
  final bool resumePlayback;
  final bool allowLocalNetwork;
  final bool hideAdultCatalogs;
  final double glassIntensity;
  final bool reduceEffects;
  final bool amoled;
  final String accentHex;
  final bool cinematic;
  final bool onboardingDone;
  final List<String> hiddenHomeCatalogs;
  final Map<String, String> catalogTitles;
  final List<String> catalogOrder;
  final bool showContinueWatching;
  final String preferredStreamLanguage;
  final String debridProvider; // 'torbox' | 'realdebrid'
  final bool skipIntro;
  final bool showRatings;
  final bool tvdbEpisodes;
  final List<CustomBadgeRule> customBadges;
  final String? customBadgesUrl;

  AppSettings copyWith({
    String? language,
    String? audioLanguage,
    String? subtitleLanguage,
    bool? subtitlesEnabledByDefault,
    double? subtitleScale,
    int? subtitleOffsetMs,
    bool? removeHearingImpaired,
    double? playbackSpeed,
    bool? autoplayNext,
    bool? resumePlayback,
    bool? allowLocalNetwork,
    bool? hideAdultCatalogs,
    double? glassIntensity,
    bool? reduceEffects,
    bool? amoled,
    String? accentHex,
    bool? cinematic,
    bool? onboardingDone,
    List<String>? hiddenHomeCatalogs,
    Map<String, String>? catalogTitles,
    List<String>? catalogOrder,
    bool? showContinueWatching,
    String? preferredStreamLanguage,
    String? debridProvider,
    bool? skipIntro,
    bool? showRatings,
    bool? tvdbEpisodes,
    List<CustomBadgeRule>? customBadges,
    Object? customBadgesUrl = _keep,
  }) => AppSettings(
    language: language ?? this.language,
    audioLanguage: audioLanguage ?? this.audioLanguage,
    subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
    subtitlesEnabledByDefault:
        subtitlesEnabledByDefault ?? this.subtitlesEnabledByDefault,
    subtitleScale: subtitleScale ?? this.subtitleScale,
    subtitleOffsetMs: subtitleOffsetMs ?? this.subtitleOffsetMs,
    removeHearingImpaired: removeHearingImpaired ?? this.removeHearingImpaired,
    playbackSpeed: playbackSpeed ?? this.playbackSpeed,
    autoplayNext: autoplayNext ?? this.autoplayNext,
    resumePlayback: resumePlayback ?? this.resumePlayback,
    allowLocalNetwork: allowLocalNetwork ?? this.allowLocalNetwork,
    hideAdultCatalogs: hideAdultCatalogs ?? this.hideAdultCatalogs,
    glassIntensity: glassIntensity ?? this.glassIntensity,
    reduceEffects: reduceEffects ?? this.reduceEffects,
    amoled: amoled ?? this.amoled,
    accentHex: accentHex ?? this.accentHex,
    cinematic: cinematic ?? this.cinematic,
    onboardingDone: onboardingDone ?? this.onboardingDone,
    hiddenHomeCatalogs: hiddenHomeCatalogs ?? this.hiddenHomeCatalogs,
    catalogTitles: catalogTitles ?? this.catalogTitles,
    catalogOrder: catalogOrder ?? this.catalogOrder,
    showContinueWatching: showContinueWatching ?? this.showContinueWatching,
    preferredStreamLanguage:
        preferredStreamLanguage ?? this.preferredStreamLanguage,
    debridProvider: debridProvider ?? this.debridProvider,
    skipIntro: skipIntro ?? this.skipIntro,
    showRatings: showRatings ?? this.showRatings,
    tvdbEpisodes: tvdbEpisodes ?? this.tvdbEpisodes,
    customBadges: customBadges ?? this.customBadges,
    customBadgesUrl: identical(customBadgesUrl, _keep)
        ? this.customBadgesUrl
        : customBadgesUrl as String?,
  );

  Map<String, Object?> toJson() => {
    'language': language,
    'audioLanguage': audioLanguage,
    'subtitleLanguage': subtitleLanguage,
    'subtitlesEnabledByDefault': subtitlesEnabledByDefault,
    'subtitleScale': subtitleScale,
    'subtitleOffsetMs': subtitleOffsetMs,
    'removeHearingImpaired': removeHearingImpaired,
    'playbackSpeed': playbackSpeed,
    'autoplayNext': autoplayNext,
    'resumePlayback': resumePlayback,
    'allowLocalNetwork': allowLocalNetwork,
    'hideAdultCatalogs': hideAdultCatalogs,
    'glassIntensity': glassIntensity,
    'reduceEffects': reduceEffects,
    'amoled': amoled,
    'accentHex': accentHex,
    'cinematic': cinematic,
    'onboardingDone': onboardingDone,
    'hiddenHomeCatalogs': hiddenHomeCatalogs,
    'catalogTitles': catalogTitles,
    'catalogOrder': catalogOrder,
    'showContinueWatching': showContinueWatching,
    'preferredStreamLanguage': preferredStreamLanguage,
    'debridProvider': debridProvider,
    'skipIntro': skipIntro,
    'showRatings': showRatings,
    'tvdbEpisodes': tvdbEpisodes,
    'customBadges': [for (final b in customBadges) b.toJson()],
    'customBadgesUrl': customBadgesUrl,
  };

  factory AppSettings.fromJson(Object? raw) {
    final m = asMap(raw) ?? const {};
    const d = AppSettings();
    double clampD(Object? v, double fallback, double lo, double hi) {
      final x = asDouble(v);
      return (x == null || !x.isFinite) ? fallback : x.clamp(lo, hi).toDouble();
    }

    final hex = asNonEmptyString(m['accentHex']);
    final titles = <String, String>{};
    asMap(m['catalogTitles'])?.forEach((k, v) {
      final t = asNonEmptyString(v);
      if (t != null) titles[k] = t.length > 40 ? t.substring(0, 40) : t;
    });
    return AppSettings(
      language: asNonEmptyString(m['language']) ?? d.language,
      audioLanguage: asNonEmptyString(m['audioLanguage']) ?? d.audioLanguage,
      subtitleLanguage:
          asNonEmptyString(m['subtitleLanguage']) ?? d.subtitleLanguage,
      subtitlesEnabledByDefault: asBool(
        m['subtitlesEnabledByDefault'],
        fallback: d.subtitlesEnabledByDefault,
      ),
      subtitleScale: clampD(m['subtitleScale'], d.subtitleScale, 0.6, 2.0),
      subtitleOffsetMs: (asInt(m['subtitleOffsetMs']) ?? 0).clamp(
        -30000,
        30000,
      ),
      removeHearingImpaired: asBool(m['removeHearingImpaired']),
      playbackSpeed: clampD(m['playbackSpeed'], 1.0, 0.25, 3.0),
      autoplayNext: asBool(m['autoplayNext'], fallback: d.autoplayNext),
      resumePlayback: asBool(m['resumePlayback'], fallback: d.resumePlayback),
      allowLocalNetwork: asBool(m['allowLocalNetwork']),
      hideAdultCatalogs: asBool(
        m['hideAdultCatalogs'],
        fallback: d.hideAdultCatalogs,
      ),
      glassIntensity: clampD(m['glassIntensity'], 1.0, 0.0, 1.0),
      reduceEffects: asBool(m['reduceEffects']),
      amoled: asBool(m['amoled']),
      accentHex: (hex != null && RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(hex))
          ? hex
          : d.accentHex,
      cinematic: asBool(m['cinematic'], fallback: d.cinematic),
      onboardingDone: asBool(m['onboardingDone']),
      hiddenHomeCatalogs: asStringList(m['hiddenHomeCatalogs']),
      catalogTitles: titles,
      catalogOrder: asStringList(m['catalogOrder']),
      showContinueWatching: asBool(
        m['showContinueWatching'],
        fallback: d.showContinueWatching,
      ),
      preferredStreamLanguage:
          asNonEmptyString(m['preferredStreamLanguage']) ??
          d.preferredStreamLanguage,
      debridProvider: m['debridProvider'] == 'realdebrid'
          ? 'realdebrid'
          : 'torbox',
      skipIntro: asBool(m['skipIntro'], fallback: d.skipIntro),
      showRatings: asBool(m['showRatings'], fallback: d.showRatings),
      tvdbEpisodes: asBool(m['tvdbEpisodes'], fallback: d.tvdbEpisodes),
      customBadges: [
        for (final b in asList(
          m['customBadges'],
        ).take(CustomBadgePack.maxRules))
          ?CustomBadgeRule.fromJson(b),
      ],
      customBadgesUrl: asNonEmptyString(m['customBadgesUrl']),
    );
  }
}

class SettingsRepository {
  SettingsRepository(this._store);
  static const key = 'settings.v1';
  final KeyValueStore _store;

  Future<AppSettings> load() async {
    final raw = await _store.read(key);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) =>
      _store.write(key, jsonEncode(settings.toJson()));
}
