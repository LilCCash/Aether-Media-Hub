import 'dart:io';

import 'package:aether_flutter/app/providers.dart';
import 'package:aether_flutter/app/services.dart';
import 'package:aether_flutter/app/transitions.dart';
import 'package:aether_flutter/data/prefs_ext.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/data/stores.dart';
import 'package:aether_flutter/design/tokens.dart';
import 'package:aether_flutter/design/widgets.dart';
import 'package:aether_flutter/features/downloads/download_manager.dart';
import 'package:aether_flutter/features/downloads/downloads_view.dart';
import 'package:aether_flutter/features/settings/settings_pages2.dart';
import 'package:aether_flutter/features/settings/settings_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

Widget look(Widget child) => AetherLook(
  accent: Colors.blue,
  glassIntensity: 0.4,
  reduceEffects: true,
  amoled: false,
  cinematic: false,
  child: child,
);

void main() {
  late Directory dir;
  setUpAll(() => PosterImage.disableNetwork = true);
  setUp(() => dir = Directory.systemTemp.createTempSync('aether_ui2'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppServices> services({MemorySecretStore? secrets}) =>
      AppServices.build(
        store: MemoryStore(),
        secrets: secrets ?? MemorySecretStore(),
        downloadsDir: dir,
        dio: fakeDio((o) => (status: 200, body: 'OK')),
      );

  Future<void> pumpApp(WidgetTester t, AppServices s, Widget home) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s)],
        child: MaterialApp(
          builder: (c, child) => look(child!),
          home: Scaffold(body: home),
        ),
      ),
    );
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });
  }

  testWidgets(
    'dragging from the left edge pops the page; a short drag in the middle does not',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: Text('home')),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const EdgeSwipeBack(
            child: Scaffold(body: Center(child: Text('detail'))),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);
      await t.dragFrom(const Offset(300, 400), const Offset(250, 0));
      await t.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget); // not from the edge: ignored
      await t.dragFrom(const Offset(8, 400), const Offset(350, 0));
      await t.pumpAndSettle();
      expect(find.text('detail'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    },
  );

  testWidgets(
    'downloads of a series are grouped by series and season, with progress per season',
    (t) async {
      final s = await t.runAsync(services);
      final dl = s!.downloads;
      await t.runAsync(() async {
        for (final e in [1, 2]) {
          await dl.enqueue(
            metaId: 'tt1',
            videoId: 'tt1:1:$e',
            type: 'series',
            title: 'Show · S01E0$e',
            url: 'https://x.example/$e.mkv',
            season: 1,
            episode: e,
          );
        }
        await dl.enqueue(
          metaId: 'tt1',
          videoId: 'tt1:2:1',
          type: 'series',
          title: 'Show · S02E01',
          url: 'https://x.example/3.mkv',
          season: 2,
          episode: 1,
        );
        await dl.enqueue(
          metaId: 'tt2',
          videoId: 'tt2',
          type: 'movie',
          title: 'Un film',
          url: 'https://x.example/f.mkv',
        );
        for (
          var i = 0;
          i < 100 && dl.items.any((d) => d.status != DownloadStatus.done);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await pumpApp(t, s, const DownloadsBody());
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('Show'), findsOneWidget); // one group for the series
      expect(find.text('Un film'), findsOneWidget);
      expect(find.textContaining('2 stagioni'), findsOneWidget);
      await t.tap(find.text('Show'));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Stagione 1'), findsOneWidget);
      expect(find.text('Stagione 2'), findsOneWidget);
      expect(find.textContaining('2/2 episodi'), findsOneWidget);
    },
  );

  testWidgets(
    'a service shows its state, and a good check is green with a tick',
    (t) async {
      final secrets = MemorySecretStore();
      await secrets.setServiceKey(ServiceKey.mdblist, 'KEY');
      final s = await t.runAsync(() => services(secrets: secrets));
      await pumpApp(
        t,
        s!,
        SingleChildScrollView(
          child: ServiceTile(
            title: 'MDBList',
            icon: Icons.star_rate_rounded,
            description: 'desc',
            service: ServiceKey.mdblist,
            verify: (ref) async =>
                (ok: true, message: 'MDBList accetta la chiave.'),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Chiave salvata'), findsOneWidget);
      await t.tap(find.text('MDBList'));
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Verifica'));
      await t.pumpAndSettle();
      await t.tap(find.text('Verifica'));
      await t.pumpAndSettle();
      expect(find.text('MDBList accetta la chiave.'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsWidgets);
    },
  );

  test('style presets set palette, background, frame and corners together; the result is valid', () {
    for (final p in kStylePresets) {
      final r = p.apply(const AppSettings());
      expect(r.cardChrome, isIn(['standard', 'outline', 'shadow', 'glow']));
      expect(r.backdropStyle, isIn(['aurora', 'flow', 'spotlight', 'plain']));
      expect(r.cornerStyle, isIn(['sharp', 'standard', 'rounded', 'bubble']));
    }
    final neon = kStylePresets
        .firstWhere((p) => p.name == 'Neon')
        .apply(const AppSettings());
    expect(neon.palette, 'midnight');
    expect(neon.cardChrome, 'glow');
    expect(neon.cornerStyle, 'bubble');
    final minimal = kStylePresets
        .firstWhere((p) => p.name == 'Minimale')
        .apply(const AppSettings());
    expect(minimal.amoled, isTrue);
    expect(minimal.compact, isTrue);
  });

  test('title transition setting and page kind names', () {
    expect(const AppSettings().titleTransition, 'auto');
    expect(
      const AppSettings().withExt('titleTransition', 'zoom').titleTransition,
      'zoom',
    );
    expect(
      const AppSettings().withExt('titleTransition', 'bogus').titleTransition,
      'auto',
    );
    expect(transitionKindOf('fade'), PageTransitionKind.fade);
    expect(transitionKindOf(null), PageTransitionKind.auto);
  });
}
