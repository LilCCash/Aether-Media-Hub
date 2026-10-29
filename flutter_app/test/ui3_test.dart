import 'package:aether_flutter/core/metadata/tmdb_client.dart';
import 'package:aether_flutter/data/prefs_ext.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/features/detail/detail_screen.dart';
import 'package:aether_flutter/features/player/subtitle_style.dart';
import 'package:aether_flutter/features/settings/settings_widgets.dart';
import 'package:aether_flutter/features/downloads/season_downloader.dart';
import 'package:aether_flutter/design/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a subtitle line is centred and keeps the colour that was chosen',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 40,
                  right: 40,
                  bottom: 20,
                  child: Center(
                    child: SubtitleText(
                      text: 'Ciao',
                      scale: 1,
                      color: const Color(0xFFFFFFFF),
                      bold: false,
                      outline: true,
                      outlineColor: const Color(0xFF000000),
                      background: const Color(0x00000000),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final text = t.widget<Text>(find.text('Ciao'));
      expect(text.style!.color, const Color(0xFFFFFFFF));
      final c = t.getCenter(find.text('Ciao')).dx;
      expect(
        (c - t.view.physicalSize.width / t.view.devicePixelRatio / 2).abs(),
        lessThan(1),
      );
    },
  );

  testWidgets('a group filter shows only the groups it lists', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: AetherLook(
          accent: Colors.blue,
          glassIntensity: 0.4,
          reduceEffects: true,
          amoled: false,
          cinematic: false,
          child: Scaffold(
            body: GroupFilter(
              titles: const {'Alfa'},
              child: Column(
                children: const [
                  SettingsGroup(title: 'Alfa', children: [Text('uno')]),
                  SettingsGroup(title: 'Beta', children: [Text('due')]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Alfa'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
    // the sections are open: their rows are on screen
    expect(find.text('uno'), findsOneWidget);
  });

  test('TMDB facts follow their switches', () {
    const r = RichDetails(
      status: 'Released',
      runtime: 125,
      budget: 100000000,
      providers: ['Netflix'],
      keywords: ['spazio'],
      certification: 'T',
    );
    final all = factRows(r, const AppSettings());
    expect(
      all.map((e) => e.$1),
      containsAll([
        'Durata',
        'Dove guardarlo',
        'Parole chiave',
        'Classificazione',
      ]),
    );
    final off = factRows(
      r,
      const AppSettings()
          .withExt('modFacts', false)
          .withExt('modProviders', false)
          .withExt('modKeywords', false)
          .withExt('modCertification', false),
    );
    expect(off, isEmpty);
  });

  test('season jobs are kept by title and season', () {
    final jobs = SeasonJobs();
    expect(jobs.busy('tt1', 1), isFalse);
    expect(SeasonJobs.keyOf('tt1', 1), isNot(SeasonJobs.keyOf('tt1', 2)));
  });
}
