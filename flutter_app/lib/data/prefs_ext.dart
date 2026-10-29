import '../core/util/lenient.dart';
import 'settings.dart';

/// The options kept in [AppSettings.ext]. Every getter validates: a missing or out-of-range value reads as its default.
/// To add an option: add a getter here and, in the settings screens, a `Pref…` row with the same key.
extension PrefsExt on AppSettings {
  bool _b(String k, bool d) => asBool(ext[k], fallback: d);
  int _i(String k, int d, int lo, int hi) =>
      (asInt(ext[k]) ?? d).clamp(lo, hi).toInt();
  double _d(String k, double d, double lo, double hi) =>
      (asDouble(ext[k]) ?? d).clamp(lo, hi).toDouble();
  String _s(String k, String d, Set<String> allowed) {
    final v = asString(ext[k]);
    return (v != null && allowed.contains(v)) ? v : d;
  }

  AppSettings withExt(String key, Object? value) {
    final m = {...ext};
    if (value == null) {
      m.remove(key);
    } else {
      m[key] = value;
    }
    return copyWith(ext: m);
  }

  // ── Player: next episode, credits, sources, picture ──
  bool get skipCredits => _b('skipCredits', true);
  bool get autoNextAtCredits => _b('autoNextAtCredits', false);
  int get creditsSec => _i('creditsSec', 90, 20, 300);
  bool get nextPreview => _b('nextPreview', true);
  bool get autoSwitchSource => _b('autoSwitchSource', true);
  bool get nowPlaying => _b('nowPlaying', true);
  bool get remuxMkv => _b('remuxMkv', true);
  String get toneMapping => _s('toneMapping', 'auto', {
    'auto',
    'bt.2390',
    'hable',
    'mobius',
    'reinhard',
    'spline',
    'clip',
  });
  bool get hdrComputePeak => _b('hdrComputePeak', true);
  int get targetPeak => _i('targetPeak', 0, 0, 1000);

  // ── Content: calendar and notifications ──
  bool get hideTalkShows => _b('hideTalkShows', false);
  bool get notifyNewEpisodes => _b('notifyNewEpisodes', false);
  int get notifyLeadMin => _i('notifyLeadMin', 0, 0, 1440);
  bool get notifyWatchlist => _b('notifyWatchlist', true);
  int get calendarDays => _i('calendarDays', 30, 7, 90);

  // ── Downloads ──
  bool get notifyDownloads => _b('notifyDownloads', true);
  bool get backgroundDownloads => _b('backgroundDownloads', true);

  // ── Look ──
  /// `dark`, `light` (experimental: the dark design is inverted) or `auto` (the system's choice).
  String get themeMode => _s('themeMode', 'dark', {'dark', 'light', 'auto'});
  bool get animatedBackdrop => _b('animatedBackdrop', false);
  bool get alternatePosters => _b('alternatePosters', true);
  Map<String, String> get posterOverrides => {
    for (final e in (asMap(ext['posterOverrides']) ?? const {}).entries)
      if (asString(e.value) != null) e.key: asString(e.value)!,
  };

  // ── Title page ──
  bool get modSameActors => _b('modSameActors', true);

  // ── Trakt / Simkl ──
  bool get traktScrobble => _b('traktScrobble', true);
  bool get traktSyncHistory => _b('traktSyncHistory', true);
  bool get traktSyncWatchlist => _b('traktSyncWatchlist', true);
  bool get simklSync => _b('simklSync', true);

  // ── Sources ──
  /// `byAddon`: addons in the order set in the Addon page, best first inside each; `byQuality`: one list, best first.
  String get streamOrdering =>
      _s('streamOrdering', 'byAddon', {'byAddon', 'byQuality'});
  int get qualityCap =>
      const {0, 2160, 1080, 720}.contains(asInt(ext['qualityCap']))
      ? asInt(ext['qualityCap'])!
      : 0;
  bool get autoSelectStream => _b('autoSelectStream', false);
  bool get showAddonLogo => _b('showAddonLogo', true);
  String get badgeStyle =>
      _s('badgeStyle', 'filled', {'filled', 'outline', 'plain'});
  List<String> get hiddenBadges => asStringList(ext['hiddenBadges']);

  // ── Title page: TMDB modules and MDBList ratings ──
  bool get modCast => _b('modCast', true);
  bool get modTrailers => _b('modTrailers', true);
  bool get modCompanies => _b('modCompanies', true);
  bool get modFinancials => _b('modFinancials', true);
  bool get modFacts => _b('modFacts', true);
  bool get modSimilar => _b('modSimilar', true);
  bool get modCollection => _b('modCollection', true);
  bool get modCrew => _b('modCrew', true);
  bool get modKeywords => _b('modKeywords', true);
  bool get modProviders => _b('modProviders', true);
  bool get modCertification => _b('modCertification', true);
  bool get modRecommended => _b('modRecommended', true);
  bool get tmdbEnabled => _b('tmdbEnabled', true);
  List<String> get ratingSources => ext.containsKey('ratingSources')
      ? asStringList(ext['ratingSources'])
      : const ['imdb', 'tomatoes', 'metacritic', 'tmdb'];
  bool get posterRatings => _b('posterRatings', true);

  // ── Player ──
  int get skipBackSec => _i('skipBackSec', 10, 5, 60);
  int get skipForwardSec => _i('skipForwardSec', 10, 5, 60);
  int get controlsHideSec => _i('controlsHideSec', 4, 2, 15);
  int get resumeRewindSec => _i('resumeRewindSec', 0, 0, 30);
  int get nextCountdownSec => _i('nextCountdownSec', 8, 3, 30);

  /// iPhone: MP4, MOV and HLS play on the system player (Picture in Picture); off keeps everything on libmpv.
  bool get nativePlayer => _b('nativePlayer', true);

  /// iPhone: which player opens a video. `av` always uses the system player (picture in picture, AirPlay) and converts whatever it
  /// cannot read; `mpv` always uses libmpv; `auto` uses the system player for MP4, MOV and HLS and libmpv for the rest.
  String get playerEngine =>
      _s('playerEngine', nativePlayer ? 'auto' : 'mpv', {'auto', 'av', 'mpv'});

  /// How dense the tab bar's glass is: 0 clear, 1 tinted. Low by default, so the page shows through it.
  double get dockOpacity => _d('dockOpacity', 0.12, 0, 1);
  double get watchedThreshold => _d('watchedThreshold', 0.9, 0.5, 0.99);
  bool get holdToSpeed => _b('holdToSpeed', true);
  double get holdSpeed => _d('holdSpeed', 2.0, 1.25, 4.0);
  bool get gestures => _b('gestures', true);
  String get fallbackAudio => _s('fallbackAudio', 'off', _langs);
  String get fallbackSubtitle => _s('fallbackSubtitle', 'off', _langs);
  bool get backgroundAudio => _b('backgroundAudio', true);
  bool get autoPip => _b('autoPip', true);
  int get sleepTimerMin => _i('sleepTimerMin', 0, 0, 240);
  String get subColor => _hex('subColor', '#FFFFFF');
  String get subOutlineColor => _hex('subOutlineColor', '#000000');
  String get subBgColor => _hex('subBgColor', '#000000');
  double get subBgOpacity => _d('subBgOpacity', 0, 0, 1);
  bool get subBold => _b('subBold', false);
  bool get subOutline => _b('subOutline', true);
  double get subBottom => _d('subBottom', 8, 0, 40);
  bool get hwDecoding => _b('hwDecoding', true);
  bool get deband => _b('deband', false);
  int get imgBrightness => _i('imgBrightness', 0, -50, 50);
  int get imgContrast => _i('imgContrast', 0, -50, 50);
  int get imgSaturation => _i('imgSaturation', 0, -50, 50);
  int get imgGamma => _i('imgGamma', 0, -50, 50);
  int get bufferSec => _i('bufferSec', 0, 0, 120);

  // ── Discover ──
  List<String> get discoverHidden => asStringList(ext['discoverHidden']);

  /// The catalog opened first for a type ("addonId/catalogKey"), or null.
  String? discoverDefaultFor(String type) {
    for (final e in asStringList(ext['discoverDefaults'])) {
      final i = e.indexOf('=');
      if (i > 0 && e.substring(0, i) == type) return e.substring(i + 1);
    }
    return null;
  }

  AppSettings withDiscoverDefault(String type, String? key) {
    final list = [
      for (final e in asStringList(ext['discoverDefaults']))
        if (!e.startsWith('$type=')) e,
      if (key != null) '$type=$key',
    ];
    return withExt('discoverDefaults', list);
  }

  // ── Search / catalogs ──
  String get searchSort =>
      _s('searchSort', 'relevance', {'relevance', 'year', 'name'});
  bool get saveSearchHistory => _b('saveSearchHistory', true);
  bool get searchLibrary => _b('searchLibrary', true);
  int get catalogRefreshMin => _i('catalogRefreshMin', 10, 0, 240);
  bool get cacheMetadata => _b('cacheMetadata', true);

  // ── Downloads / storage ──
  int get maxDownloads => _i('maxDownloads', 2, 1, 5);
  bool get downloadOverCellular => _b('downloadOverCellular', false);
  bool get deleteAfterWatching => _b('deleteAfterWatching', false);
  int get seasonQuality =>
      const {0, 2160, 1080, 720}.contains(asInt(ext['seasonQuality']))
      ? asInt(ext['seasonQuality'])!
      : 0;

  /// `preferred` (the audio language of the settings), `any`, or an ISO 639-2 code.
  String get seasonLanguage => asString(ext['seasonLanguage']) ?? 'preferred';
  String get seasonSizePolicy =>
      _s('seasonSizePolicy', 'preferSmaller', {'preferSmaller', 'any'});
  List<String> get seasonDisabledAddons =>
      asStringList(ext['seasonDisabledAddons']);
  int get imageCacheMB => _i('imageCacheMB', 300, 50, 2000);

  // ── Look ──
  String get backdropStyle =>
      _s('backdropStyle', 'aurora', {'aurora', 'flow', 'spotlight', 'plain'});
  double get backdropIntensity => _d('backdropIntensity', 1, 0, 1.5);
  String get cardChrome =>
      _s('cardChrome', 'standard', {'standard', 'outline', 'shadow', 'glow'});
  String get cornerStyle =>
      _s('cornerStyle', 'standard', {'sharp', 'standard', 'rounded', 'bubble'});
  String get posterSize =>
      _s('posterSize', 'medium', {'small', 'medium', 'large'});
  String get density =>
      _s('density', 'comfortable', {'compact', 'comfortable'});
  bool get halos => _b('halos', true);
  bool get animations => _b('animations', true);
  String get heroStyle => _s('heroStyle', 'card', {'card', 'fullBleed'});
  bool get heroAutoScroll => _b('heroAutoScroll', true);
  String? get customBackgroundHex {
    final v = asString(ext['customBackgroundHex']);
    return (v != null && RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(v)) ? v : null;
  }

  /// Home sections in order, each with its visibility. Unknown ids are dropped, missing ones appended.
  List<HomeSection> get homeSections {
    final raw = asStringList(ext['homeSections']); // "id:1" / "id:0"
    final seen = <String>{};
    final out = <HomeSection>[];
    for (final e in raw) {
      final parts = e.split(':');
      if (parts.length == 2 &&
          kHomeSectionIds.contains(parts[0]) &&
          seen.add(parts[0])) {
        out.add(HomeSection(parts[0], parts[1] != '0'));
      }
    }
    for (final id in kHomeSectionIds) {
      if (!seen.contains(id)) out.add(HomeSection(id, true));
    }
    return out;
  }

  AppSettings withHomeSections(List<HomeSection> s) => withExt('homeSections', [
    for (final e in s) '${e.id}:${e.visible ? 1 : 0}',
  ]);

  /// How a title page appears: auto (zoom with Dynamic Cinematic, else slide), zoom, fade, slide, none.
  String get titleTransition =>
      _s('titleTransition', 'auto', {'auto', 'zoom', 'fade', 'slide', 'none'});

  // ── Interface ──
  bool get liquidGlass => _b('liquidGlass', true);
  bool get compact =>
      _s('density', 'comfortable', {'compact', 'comfortable'}) == 'compact';
  double get textScale => _d('textScale', 1.0, 0.85, 1.3);

  /// Font of the whole interface: system, serif or mono (families every phone has).
  String get uiFont => _s('uiFont', 'system', {'system', 'serif', 'mono'});

  // ── Settings screen ──
  bool get coloredIcons => _b('coloredIcons', true);

  // ── Diagnostics ──
  bool get keepLog => _b('keepLog', true);

  String _hex(String k, String d) {
    final v = asString(ext[k]);
    return (v != null && RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(v)) ? v : d;
  }
}

const kHomeSectionIds = ['hero', 'continue', 'nextUp', 'watchlist', 'catalogs'];
const kHomeSectionTitles = {
  'hero': 'In evidenza',
  'continue': 'Continua a guardare',
  'nextUp': 'Prossimi episodi',
  'watchlist': 'Watchlist',
  'catalogs': 'Cataloghi degli addon',
};

class HomeSection {
  const HomeSection(this.id, this.visible);
  final String id;
  final bool visible;
}

const _langs = {'off', 'ita', 'eng', 'fra', 'spa', 'deu', 'por', 'jpn'};
