import 'package:aether_flutter/core/streams/release_language.dart';
import 'package:aether_flutter/features/player/playback_engine.dart';
import 'package:aether_flutter/features/player/source_check.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

void main() {
  test('subtitle-only tags do not make a release Italian', () {
    expect(ReleaseLanguage.languages('Film 2024 ENG SUB ITA 1080p WEB-DL'), [
      'Inglese',
    ]);
    expect(
      ReleaseLanguage.languages('Film.2024.ITA.ENG.1080p'),
      containsAll(['Italiano', 'Inglese']),
    );
    expect(ReleaseLanguage.languages('Film 2024 MULTI 1080p'), ['Multi']);
    expect(ReleaseLanguage.languages('The IT Crowd S01E01'), isEmpty);
    expect(ReleaseLanguage.languages('Film 2024 IT 1080p WEB'), ['Italiano']);
  });

  test('a debrid error answer is explained and a real video passes', () async {
    final bad = fakeDio(
      (o) => (
        status: 401,
        body: 'EasyJack Debrid playback unavailable: StremThru torbox HTTP 401',
      ),
    );
    final why = await checkSource(
      const PlaybackSource(uri: 'https://x.example/v.mkv'),
      dio: bad,
    );
    expect(why, contains('HTTP 401'));
    expect(why, contains('non autorizzato'));

    final text = fakeDio(
      (o) => (status: 200, body: 'Debrid playback unavailable'),
    );
    expect(
      await checkSource(
        const PlaybackSource(uri: 'https://x.example/v.mkv'),
        dio: text,
      ),
      isNotNull,
    );

    final ok = fakeDio(
      (o) => (status: 206, body: '\u0001\u0002\u0003\u0004' * 800),
    );
    expect(
      await checkSource(
        const PlaybackSource(uri: 'https://x.example/v.mkv'),
        dio: ok,
      ),
      isNull,
    );
    expect(
      await checkSource(
        const PlaybackSource(uri: '/data/v.mkv', isLocalFile: true),
        dio: bad,
      ),
      isNull,
    );
  });
}
