import 'package:aether_flutter/app/hooks.dart';
import 'package:aether_flutter/data/library_repository.dart';
import 'package:aether_flutter/data/prefs_ext.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/design/light_theme.dart';
import 'package:aether_flutter/features/calendar/calendar_screen.dart';
import 'package:aether_flutter/features/settings/settings_more.dart';
import 'package:aether_flutter/features/stats/stats_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
