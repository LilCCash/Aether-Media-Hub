import 'package:aether_flutter/app/hooks.dart';
import 'package:aether_flutter/data/library_repository.dart';
import 'package:aether_flutter/data/prefs_ext.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/data/swift_backup.dart';
import 'package:aether_flutter/design/light_theme.dart';
import 'package:aether_flutter/features/calendar/calendar_screen.dart';
import 'package:aether_flutter/features/settings/settings_more.dart';
import 'package:aether_flutter/features/stats/stats_screen.dart';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

void main() {
  swiftBackupTests();
  test('i link aether:// portano alla pagina giusta', () {
    expect(
      locationForLink(Uri.parse('aether://title/series/tt123')),
      '/title/series/tt123',
    );
    expect(locationForLink(Uri.parse('aether://calendar')), '/calendar');
    expect(locationForLink(Uri.parse('https://x.y/z')), isNull);
  });

  test('il filtro del tema chiaro è un’involuzione', () {
    // Applied twice it gives back the colour (M·(M·c + o) + o = c).
    for (final c in const [
      [0.0, 0.0, 0.0],
      [255.0, 128.0, 10.0],
      [30.0, 200.0, 90.0],
    ]) {
      List<double> apply(List<double> v) => [
        for (var r = 0; r < 3; r++)
          kLightMatrix[r * 5] * v[0] +
              kLightMatrix[r * 5 + 1] * v[1] +
              kLightMatrix[r * 5 + 2] * v[2] +
              kLightMatrix[r * 5 + 4],
      ];
      final twice = apply(apply(c));
      for (var i = 0; i < 3; i++) {
        expect(twice[i], closeTo(c[i], 0.5));
      }
    }
  });

  test('un tema esportato si reimporta e un testo qualunque no', () {
    final s = const AppSettings().copyWith(
      palette: 'ocean',
      accentHex: '#112233',
    );
    final text = ThemeExtrasPage.export(s.withExt('themeMode', 'light'));
    final back = ThemeExtrasPage.import(const AppSettings(), text)!;
    expect(back.palette, s.palette);
    expect(back.accentHex, '#112233');
    expect(back.ext['themeMode'], 'light');
    expect(ThemeExtrasPage.import(const AppSettings(), 'ciao'), isNull);
  });

  test('un episodio senza orario conta dalla mattina del giorno', () {
    final d = CalendarEntry.moment(DateTime.utc(2026, 3, 5));
    expect((d.year, d.month, d.day, d.hour), (2026, 3, 5, 9));
  });

  test('le statistiche sommano il tempo e distinguono film ed episodi', () {
    final now = DateTime.now();
    WatchProgress p(String id, String type, int pos, int dur, DateTime at) =>
        WatchProgress(
          metaId: id,
          videoId: id,
          type: type,
          name: id,
          positionMs: pos,
          durationMs: dur,
          updatedAt: at,
        );
    final s = WatchStats([
      p('a', 'movie', 3600000, 3600000, now),
      p('b', 'series', 600000, 1800000, now.subtract(const Duration(days: 1))),
    ]);
    expect(s.films, 1);
    expect(s.episodes, 1);
    expect(s.totalMs, 4200000);
    expect(s.last7[6], 3600000);
    expect(s.last7[5], 600000);
    expect(WatchStats.duration(4200000), '1 h 10 min');
  });
}

void swiftBackupTests() {
  const text = '''
{"marker":"app.aether.backup","formatVersion":1,"createdAt":"2026-10-20T10:00:00Z","appVersion":"1.2","includesAddonURLs":true,
 "library":{"schemaVersion":1,
  "entries":[
   {"id":"tt1","type":"movie","name":"Film","poster":"https://p/1.jpg","posterShape":"poster","inWatchlist":true,"isFavorite":false,
    "addedAt":"2026-10-01T10:00:00Z","modifiedAt":"2026-10-02T10:00:00Z","isRemoved":false},
   {"id":"tt2","type":"series","name":"Serie","inWatchlist":false,"isFavorite":true,"addedAt":"2026-10-01T10:00:00Z",
    "modifiedAt":"2026-10-03T10:00:00Z","isRemoved":false},
   {"id":"tt3","type":"movie","name":"Tolto","inWatchlist":false,"isFavorite":false,"addedAt":"2026-10-01T10:00:00Z",
    "modifiedAt":"2026-10-04T10:00:00Z","isRemoved":true}],
  "progress":[
   {"id":"tt2|tt2:1:2","metaID":"tt2","videoID":"tt2:1:2","type":"series","title":"Serie","season":1,"episode":2,
    "position":600.5,"duration":1500,"updatedAt":"2026-10-05T10:00:00Z","isCompleted":false,"isDismissed":false},
   {"id":"tt1|tt1","metaID":"tt1","videoID":"tt1","type":"movie","title":"Film","position":100,"duration":7200,
    "updatedAt":"2026-10-06T10:00:00Z","isCompleted":true,"isDismissed":false}],
  "searchHistory":[]},
 "settings":{"version":3,"playback":{"autoResume":false,"preferredAudioLanguage":"it","preferredSubtitleLanguage":"off","skipForwardSeconds":30},
   "appearance":{"theme":"light","amoled":true},"content":{"hideAdultCatalogs":false}},
 "addons":[{"addon":{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","manifest":{"name":"Cinemeta"},"isEnabled":false,"nameOverride":"Mio"},
            "url":"https://example.com/abc/manifest.json"},
           {"addon":{"id":"A621E1F8-C36C-495A-93FC-0C247A3E6E5F","manifest":{"name":"Senza"},"isEnabled":true},"url":null}],
 "serviceKeys":{"torbox":"tb-key","tmdb":"tm-key","tvdbPin":"1234"}}
''';

  test('un backup dell’app Swift diventa un backup di questa app', () {
    final doc = SwiftBackup.toFlutter(
      Map<String, Object?>.from(jsonDecode(text) as Map),
    );
    final lib = doc['library']! as Map;
    expect((lib['watchlist'] as List).length, 1);
    expect((lib['favorites'] as List).length, 1);
    final progress = (lib['progress'] as List).cast<Map>();
    expect(progress.first['positionMs'], 600500);
    expect(progress.first['durationMs'], 1500000);
    // finished: saved as watched to the end
    expect(progress.last['positionMs'], progress.last['durationMs']);
    final addons = (doc['addons'] as List).cast<Map>();
    expect(addons.first['url'], 'https://example.com/abc/manifest.json');
    expect(addons.first['enabled'], false);
    expect(addons.first['nameOverride'], 'Mio');
    expect(addons.last['url'], isNull);
    expect((doc['serviceKeys'] as Map)['torbox'], 'tb-key');
  });

  test('le impostazioni in comune passano dall’app Swift', () {
    final doc = SwiftBackup.toFlutter(
      Map<String, Object?>.from(jsonDecode(text) as Map),
    );
    final s = SwiftBackup.applySettings(
      const AppSettings(),
      doc['swiftSettings'],
    );
    expect(s.resumePlayback, false);
    expect(s.audioLanguage, 'ita');
    expect(s.subtitlesEnabledByDefault, false);
    expect(s.skipForwardSec, 30);
    expect(s.amoled, true);
    expect(s.themeMode, 'light');
    expect(s.hideAdultCatalogs, false);
  });
}
