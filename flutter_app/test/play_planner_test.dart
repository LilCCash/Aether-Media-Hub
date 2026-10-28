import 'dart:io';

import 'package:aether_flutter/app/services.dart';
import 'package:aether_flutter/core/model/meta.dart';
import 'package:aether_flutter/core/model/stream.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/data/stores.dart';
import 'package:aether_flutter/features/play/play_planner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

const _manifest =
    '{"id":"org.s","name":"S","resources":["stream","meta"],"types":["series","movie"],"idPrefixes":["tt"],"catalogs":[]}';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aether_pp'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppServices> services(FakeHandler h) async {
    final s = await AppServices.build(
      store: MemoryStore(),
      secrets: MemorySecretStore(),
      downloadsDir: dir,
      dio: fakeDio(h),
    );
    await s.addons.install(await s.addons.preview('https://x.example/one'));
    return s;
  }

  const meta = MetaItem(
    id: 'tt1',
    type: 'series',
    name: 'Serie',
    videos: [
      Video(id: 'tt1:1:1', title: 'a', season: 1, episode: 1),
      Video(id: 'tt1:1:2', title: 'b', season: 1, episode: 2),
      Video(id: 'tt1:2:1', title: 'c', season: 2, episode: 1),
    ],
  );

  test('direct sources open as they are, with the addon headers; external ones are refused', () async {
    final s = await services((o) => (status: 200, body: _manifest));
    final p = PlayPlanner(s, const AppSettings());
    final source = await p.sourceFor(
      const AddonStream(
        url: 'https://cdn.example/a.mkv',
        proxyHeaders: {'User-Agent': 'u'},
      ),
    );
    expect(source.uri, 'https://cdn.example/a.mkv');
    expect(source.headers['User-Agent'], 'u');
    await expectLater(
      p.sourceFor(const AddonStream(externalUrl: 'https://x')),
      throwsA(anything),
    );
  });

  test('next episode: crosses the season, prefers the same binge group, skips what needs a download', () async {
    final s = await services((o) {
      if (o.uri.path.endsWith('manifest.json'))
        return (status: 200, body: _manifest);
      if (o.uri.path.contains('tt1%3A1%3A2')) {
        return (
          status: 200,
          body: '{"streams":[{"url":"https://cdn/e2-720.mp4","name":"720p","behaviorHints":{"bingeGroup":"g1"}},{"url":"https://cdn/e2-1080.mp4","name":"1080p","behaviorHints":{"bingeGroup":"g2"}}]}',
        );
      }
      if (o.uri.path.contains('tt1%3A2%3A1'))
        return (
          status: 200,
          body:
              '{"streams":[{"infoHash":"${'b' * 40}","name":"2160p torrent"}]}',
        );
      return (status: 200, body: '{"streams":[]}');
    });
    final p = PlayPlanner(s, const AppSettings());
    final played = const AddonStream(
      url: 'https://cdn/e1.mp4',
      bingeGroup: 'g1',
    );
    final next = (await p.nextEpisode(meta, meta.videos[0], played))!;
    expect(
      next.source.uri,
      'https://cdn/e2-720.mp4',
    ); // same group beats better quality
    expect(next.episode, 2);
    // After episode 2 comes season 2, whose only source is a torrent and TorBox is not configured: nothing starts on its own.
    expect(await p.nextEpisode(meta, meta.videos[1], played), isNull);
    // After the last episode there is nothing.
    expect(await p.nextEpisode(meta, meta.videos[2], played), isNull);
  });

  test('subtitles from the stream and from addons are merged without duplicates and labelled in Italian', () async {
    final s = await services((o) => (status: 200, body: _manifest));
    final p = PlayPlanner(s, const AppSettings());
    final list = p.subtitlesFor(
      const AddonStream(
        url: 'https://c/a.mp4',
        subtitles: [
          AddonSubtitle(id: '1', url: 'https://s/1.srt', lang: 'ita'),
        ],
      ),
      const [
        AddonSubtitle(id: '2', url: 'https://s/1.srt', lang: 'ita'),
        AddonSubtitle(
          id: '3',
          url: 'https://s/2.srt',
          lang: 'eng',
          addonName: 'OS',
        ),
      ],
    );
    expect(list.map((e) => e.label), ['Italiano', 'Inglese · OS']);
  });

  test('a finished download is offered as the offline source', () async {
    final s = await services(
      (o) => (
        status: 200,
        body: o.uri.path.endsWith('manifest.json') ? _manifest : 'DATA',
      ),
    );
    final item = await s.downloads.enqueue(
      metaId: 'tt9',
      videoId: 'tt9',
      type: 'movie',
      title: 'x',
      url: 'https://cdn.example/x.mp4',
    );
    for (var i = 0; i < 100 && s.downloads.localPath('tt9') == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final p = PlayPlanner(s, const AppSettings());
    expect(p.offlineSource('tt9')!.isLocalFile, isTrue);
    expect(p.offlineSource('none'), isNull);
    expect(item.id, isNotEmpty);
  });
}
