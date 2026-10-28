import 'dart:io';

import 'package:dio/dio.dart' show RequestOptions;

import 'package:aether_flutter/app/app.dart';
import 'package:aether_flutter/app/providers.dart';
import 'package:aether_flutter/app/services.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/data/stores.dart';
import 'package:aether_flutter/design/tokens.dart';
import 'package:aether_flutter/design/widgets.dart';
import 'package:aether_flutter/features/player/player_screen.dart';
import 'package:aether_flutter/features/player/playback_engine.dart';
import 'package:aether_flutter/features/player/player_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'player_session_test.dart' show FakeEngine;
import 'support/fake_adapter.dart';

const _manifest =
    '{"id":"org.ui","name":"UI Addon","version":"1.0","resources":["catalog","meta","stream"],"types":["movie","series"],"idPrefixes":["tt"],'
    '"catalogs":[{"type":"movie","id":"top","name":"I più visti","extra":[{"name":"genre","options":["Azione"]},{"name":"skip"}]},{"type":"movie","id":"s","name":"Cerca","extra":[{"name":"search","isRequired":true}]}]}';

({int status, String body}) _server(RequestOptions o) {
  final p = o.uri.path;
  if (p.endsWith('/manifest.json')) return (status: 200, body: _manifest);
  if (p.contains('/catalog/'))
    return (
      status: 200,
      body: '{"metas":[{"id":"tt1","type":"movie","name":"Film Uno","poster":"https://img/1.jpg","background":"https://img/b1.jpg","imdbRating":"7.5","genres":["Azione"]},{"id":"tt2","type":"movie","name":"Film Due"}]}',
    );
  if (p.contains('/meta/'))
    return (
      status: 200,
      body: '{"meta":{"id":"tt1","type":"movie","name":"Film Uno","description":"Trama di prova del film.","genres":["Azione"]}}',
    );
  if (p.contains('/stream/'))
    return (
      status: 200,
      body:
          '{"streams":[{"url":"https://cdn/a.1080p.ITA.mkv","name":"Addon\\n1080p"},{"infoHash":"${'a' * 40}","name":"Torrent 2160p HDR"}]}',
    );
  return (status: 404, body: '{}');
}

Future<void> frames(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Directory dir;
  setUpAll(() => PosterImage.disableNetwork = true);
  setUp(() => dir = Directory.systemTemp.createTempSync('aether_ui'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppServices> services({
    bool installed = true,
    AppSettings? settings,
  }) async {
    final store = MemoryStore();
    if (settings != null) await SettingsRepository(store).save(settings);
    final s = await AppServices.build(
      store: store,
      secrets: MemorySecretStore(),
      downloadsDir: dir,
      dio: fakeDio(_server),
    );
    if (installed)
      await s.addons.install(await s.addons.preview('https://x.example/cfg'));
    return s;
  }

  Future<void> boot(WidgetTester tester, AppServices s) async {
    tester.view.physicalSize = const Size(
      1080,
      2400,
    ); // a phone: 360 × 800 logical pixels
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(s)],
        child: const AetherApp(),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'first launch shows the welcome, lets the viewer install an addon and ends on the Home with its rows',
    (tester) async {
      final s = await tester.runAsync(() => services(installed: false));
      await boot(tester, s!);
      expect(find.text('Benvenuto in Aether'), findsOneWidget);
      await tester.tap(find.text('Inizia'));
      await frames(tester);
      expect(find.text('Il tuo primo addon'), findsOneWidget);
      await tester.tap(find.text('Controlla l’addon'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Installa'), findsOneWidget);
      await tester.tap(find.text('Installa'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await frames(tester);
      await tester.tap(find.text('Apri Aether'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await frames(tester, 10);
      expect(find.text('I più visti'), findsOneWidget);
      expect(s.settingsRepo, isNotNull);
      expect(
        ProviderScope.containerOf(tester.element(find.text('I più visti')))
            .read(settingsProvider)
            .onboardingDone,
        isTrue,
      );
    },
  );

  testWidgets(
    'with no addon the Home explains what to do instead of showing an empty page',
    (tester) async {
      final s = await tester.runAsync(
        () => services(
          installed: false,
          settings: const AppSettings(onboardingDone: true),
        ),
      );
      await boot(tester, s!);
      expect(find.text('Nessun addon installato'), findsOneWidget);
      expect(find.text('Aggiungi un addon'), findsOneWidget);
    },
  );

  testWidgets('every tab and every settings page opens without errors', (
    tester,
  ) async {
    final s = await tester.runAsync(
      () => services(settings: const AppSettings(onboardingDone: true)),
    );
    await boot(tester, s!);
    for (final tab in ['Scopri', 'Cerca', 'Libreria', 'Altro', 'Home']) {
      await tester.tap(find.text(tab).last);
      await frames(tester);
      expect(tester.takeException(), isNull, reason: tab);
    }
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
    for (final page in [
      'playback',
      'appearance',
      'content',
      'catalogs',
      'services',
      'data',
      'diagnostics',
      'about',
    ]) {
      router.push('/settings/$page');
      await frames(tester);
      expect(tester.takeException(), isNull, reason: page);
      router.pop();
      await frames(tester);
    }
    router.push('/offline-test');
    await frames(tester);
    expect(find.text('Player di prova'), findsOneWidget);
    expect(find.textContaining('MKV'), findsWidgets);
  });

  testWidgets(
    'settings changes are applied at once and persisted (AMOLED, catalog rename and hide)',
    (tester) async {
      final s = await tester.runAsync(
        () => services(settings: const AppSettings(onboardingDone: true)),
      );
      await boot(tester, s!);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      await tester.runAsync(
        () => container
            .read(settingsProvider.notifier)
            .update(
              (x) => x.copyWith(amoled: true, catalogTitles: {'k': 'Nome mio'}),
            ),
      );
      final saved = await tester.runAsync(() => s.settingsRepo.load());
      expect(saved!.amoled, isTrue);
      expect(saved.catalogTitles['k'], 'Nome mio');
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home rows: the addon catalog appears, a tap opens the title page with its description and the source picker',
    (tester) async {
      final s = await tester.runAsync(
        () => services(settings: const AppSettings(onboardingDone: true)),
      );
      await boot(tester, s!);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await frames(tester, 10);
      expect(find.text('I più visti'), findsOneWidget);
      await tester.tap(find.text('Film Uno').first);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await frames(tester, 10);
      expect(find.text('Film Uno'), findsWidgets);
      expect(find.text('Trama di prova del film.'), findsOneWidget);
      expect(find.text('Guarda'), findsOneWidget);
      await tester.tap(find.text('Guarda'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await frames(tester, 10);
      expect(find.text('Scegli la sorgente'), findsOneWidget);
      expect(find.text('1080p'), findsWidgets);
      expect(
        find.textContaining('serve TorBox'),
        findsOneWidget,
      ); // torrent without a key: said clearly
    },
  );

  group('player screen', () {
    PlayerArgs args() => const PlayerArgs(
      title: 'Film di prova',
      saveProgress: false,
      source: PlaybackSource(uri: '/tmp/x.mp4', isLocalFile: true),
      alternatives: [],
    );

    Future<FakeEngine> openPlayer(WidgetTester tester) async {
      final s = await tester.runAsync(
        () => services(settings: const AppSettings(onboardingDone: true)),
      );
      final engine = FakeEngine();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(s!)],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (c, _) => Scaffold(
                    body: Center(
                      child: TextButton(
                        onPressed: () => c.push('/p'),
                        child: const Text('apri'),
                      ),
                    ),
                  ),
                  routes: const [],
                ),
                GoRoute(
                  path: '/p',
                  builder: (_, __) =>
                      PlayerScreen(args: args(), engine: engine),
                ),
                GoRoute(
                  path: '/home',
                  builder: (_, __) => const Scaffold(body: Text('home')),
                ),
              ],
            ),
            builder: (c, child) => AetherLook(
              accent: Colors.blue,
              glassIntensity: 1,
              reduceEffects: true,
              amoled: false,
              cinematic: false,
              child: child!,
            ),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      });
      await tester.tap(find.text('apri'));
      await frames(tester);
      return engine;
    }

    testWidgets(
      'the back button closes the player and returns to the previous screen',
      (tester) async {
        await openPlayer(tester);
        expect(find.text('Film di prova'), findsOneWidget);
        await tester.tap(find.byTooltip('Chiudi il player'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await frames(tester);
        expect(find.text('apri'), findsOneWidget);
        expect(find.text('Film di prova'), findsNothing);
      },
    );

    testWidgets(
      'play / pause, seek buttons, speed and subtitle panels act on the engine',
      (tester) async {
        final engine = await openPlayer(tester);
        engine.emitDuration(const Duration(minutes: 10));
        engine.emitPosition(const Duration(minutes: 1));
        engine.emitPlaying(true);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byTooltip('Pausa'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(engine.calls, contains('pause'));
        await tester.tap(find.byTooltip('Avanti di 10 secondi'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(engine.calls, contains('seek:70'));
        await tester.tap(find.text('Velocità'));
        await frames(tester);
        await tester.tap(find.text('1.5×'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(engine.calls, contains('rate:1.5'));
        await tester.tap(find.byTooltip('Chiudi'));
        await frames(tester);
        await tester.tap(find.text('Sottotitoli'));
        await frames(tester);
        expect(find.text('Disattivati'), findsOneWidget);
      },
    );

    testWidgets('a playback error shows a clear message with retry and exit', (
      tester,
    ) async {
      final engine = await openPlayer(tester);
      engine.emitError('HTTP error 404 Not Found');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('non è più disponibile'), findsOneWidget);
      expect(find.text('Riprova'), findsOneWidget);
      expect(find.text('Esci'), findsOneWidget);
    });
  });
}
