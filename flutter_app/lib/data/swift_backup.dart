import '../core/util/lenient.dart';
import 'prefs_ext.dart';
import 'settings.dart';

/// The backup file of the iPhone app written in Swift (`.json`, marker `app.aether.backup`), read by this app: library, watch progress,
/// addons with their addresses, service keys and the main settings. It is turned into this app's own backup document first.
class SwiftBackup {
  static const marker = 'app.aether.backup';

  static bool isSwift(Map<String, Object?> doc) =>
      asString(doc['marker']) == marker;

  /// This app's backup document made from [doc]. Throws [FormatException] when the file comes from a newer version.
  static Map<String, Object?> toFlutter(Map<String, Object?> doc) {
    final version = asInt(doc['formatVersion']) ?? 1;
    if (version > 1) {
      throw FormatException(
        'Backup creato da una versione più recente (formato $version).',
      );
    }
    final library = asMap(doc['library']) ?? const <String, Object?>{};
    final entries = <Map<String, Object?>>[
      for (final e in asList(library['entries']))
        if (asMap(e) != null && asBool(asMap(e)!['isRemoved']) != true)
          asMap(e)!,
    ]..sort((a, b) => _date(a['modifiedAt']).compareTo(_date(b['modifiedAt'])));
    Map<String, Object?> meta(Map<String, Object?> e) => {
      'id': asString(e['id']),
      'type': asString(e['type']) ?? 'movie',
      'name': asString(e['name']) ?? asString(e['id']),
      'poster': asNonEmptyString(e['poster']),
      'background': asNonEmptyString(e['background']),
      'logo': asNonEmptyString(e['logo']),
      'releaseInfo': asNonEmptyString(e['releaseInfo']),
      'imdbRating': asNonEmptyString(e['imdbRating']),
      if (asString(e['posterShape']) == 'landscape') 'posterShape': 'landscape',
    };
    final progress = <Map<String, Object?>>[];
    for (final p in asList(library['progress'])) {
      final m = asMap(p);
      if (m == null) continue;
      final position = asDouble(m['position']) ?? 0;
      final duration = asDouble(m['duration']) ?? 0;
      // A finished or dismissed title is saved as finished, so it does not come back in «Continua a guardare».
      final done =
          asBool(m['isCompleted']) == true || asBool(m['isDismissed']) == true;
      final durationMs = (duration * 1000).round();
      progress.add({
        'metaId': asString(m['metaID']),
        'videoId': asString(m['videoID']),
        'type': asString(m['type']) ?? 'movie',
        'name': asString(m['title']) ?? asString(m['metaID']),
        'poster': asNonEmptyString(m['poster']),
        'season': asInt(m['season']),
        'episode': asInt(m['episode']),
        'episodeTitle': asNonEmptyString(m['episodeTitle']),
        'positionMs': done && durationMs > 0
            ? durationMs
            : (position * 1000).round(),
        'durationMs': durationMs,
        'updatedAt':
            asString(m['updatedAt']) ??
            DateTime.fromMillisecondsSinceEpoch(0).toIso8601String(),
      });
    }
    final addons = <Map<String, Object?>>[];
    for (final a in asList(doc['addons'])) {
      final m = asMap(a);
      final addon = asMap(m?['addon']);
      if (m == null || addon == null) continue;
      final manifest = asMap(addon['manifest']);
      addons.add({
        'url': asNonEmptyString(m['url']),
        'name':
            asNonEmptyString(addon['nameOverride']) ??
            asNonEmptyString(manifest?['name']),
        'nameOverride': asNonEmptyString(addon['nameOverride']),
        'enabled': asBool(addon['isEnabled'], fallback: true),
      });
    }
    return {
      'format': 'app.aether.backup',
      'version': 1,
      'library': {
        'favorites': [
          for (final e in entries)
            if (asBool(e['isFavorite']) == true) meta(e),
        ],
        'watchlist': [
          for (final e in entries)
            if (asBool(e['inWatchlist']) == true) meta(e),
        ],
        'progress': progress,
      },
      if (doc['serviceKeys'] != null) 'serviceKeys': doc['serviceKeys'],
      'addons': addons,
      if (doc['settings'] != null) 'swiftSettings': doc['settings'],
    };
  }

  static DateTime _date(Object? v) =>
      DateTime.tryParse(asString(v) ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  static String? _lang(Object? v) {
    final t = asString(v)?.toLowerCase();
    if (t == null || t == 'system' || t == 'off' || t.isEmpty) return null;
    const two = {
      'it': 'ita',
      'en': 'eng',
      'fr': 'fra',
      'es': 'spa',
      'de': 'deu',
      'pt': 'por',
      'ja': 'jpn',
    };
    if (two.containsKey(t)) return two[t];
    return two.values.contains(t) ? t : null;
  }

  /// The settings the two apps share, taken from the Swift app's settings over [base].
  static AppSettings applySettings(AppSettings base, Object? raw) {
    final m = asMap(raw);
    if (m == null) return base;
    final pb = asMap(m['playback']) ?? const <String, Object?>{};
    final ap = asMap(m['appearance']) ?? const <String, Object?>{};
    final ct = asMap(m['content']) ?? const <String, Object?>{};
    var s = base;
    final audio = _lang(pb['preferredAudioLanguage']);
    if (audio != null) s = s.copyWith(audioLanguage: audio);
    final subRaw = asString(pb['preferredSubtitleLanguage']);
    if (subRaw == 'off') {
      s = s.copyWith(subtitlesEnabledByDefault: false);
    } else {
      final sub = _lang(subRaw);
      if (sub != null) {
        s = s.copyWith(subtitleLanguage: sub, subtitlesEnabledByDefault: true);
      }
    }
    final ui = _lang(ct['preferredLanguage']);
    const two = {
      'ita': 'it',
      'eng': 'en',
      'fra': 'fr',
      'spa': 'es',
      'deu': 'de',
    };
    if (ui != null && two.containsKey(ui)) s = s.copyWith(language: two[ui]);
    if (pb['autoResume'] != null) {
      s = s.copyWith(resumePlayback: asBool(pb['autoResume'], fallback: true));
    }
    if (pb['autoplayNextEpisode'] != null) {
      s = s.copyWith(
        autoplayNext: asBool(pb['autoplayNextEpisode'], fallback: true),
      );
    }
    if (pb['stripHearingImpairedTags'] != null) {
      s = s.copyWith(
        removeHearingImpaired: asBool(pb['stripHearingImpairedTags']),
      );
    }
    if (ct['hideAdultCatalogs'] != null) {
      s = s.copyWith(
        hideAdultCatalogs: asBool(ct['hideAdultCatalogs'], fallback: true),
      );
    }
    if (ap['amoled'] != null) s = s.copyWith(amoled: asBool(ap['amoled']));
    if (ap['reduceVisualEffects'] != null) {
      s = s.copyWith(reduceEffects: asBool(ap['reduceVisualEffects']));
    }
    final theme = asString(ap['theme']);
    if (theme != null) {
      s = s.withExt('themeMode', switch (theme) {
        'light' => 'light',
        'dark' => 'dark',
        _ => 'auto',
      });
    }
    final ext = <String, Object?>{
      'skipBackSec': asInt(pb['skipBackSeconds']),
      'skipForwardSec': asInt(pb['skipForwardSeconds']),
      'watchedThreshold': asDouble(pb['watchedThreshold']),
      'holdToSpeed': pb['holdToSpeed'] == null
          ? null
          : asBool(pb['holdToSpeed']),
      'holdSpeed': asDouble(pb['holdSpeed']),
      'gestures': pb['gesturesEnabled'] == null
          ? null
          : asBool(pb['gesturesEnabled']),
      'autoPip': pb['autoPictureInPicture'] == null
          ? null
          : asBool(pb['autoPictureInPicture']),
      'backgroundAudio': pb['allowBackgroundAudio'] == null
          ? null
          : asBool(pb['allowBackgroundAudio']),
      'sleepTimerMin': asInt(pb['defaultSleepTimerMinutes']),
      'backdropIntensity': asDouble(ap['backdropIntensity']),
      'animations': ap['animationsEnabled'] == null
          ? null
          : asBool(ap['animationsEnabled']),
    };
    for (final e in ext.entries) {
      if (e.value != null) s = s.withExt(e.key, e.value);
    }
    final size = asString(ap['posterSize']);
    if (size == 'small' || size == 'medium' || size == 'large') {
      s = s.withExt('posterSize', size);
    }
    return s;
  }
}
