import 'dart:io';

import 'package:aether_flutter/data/stores.dart';
import 'package:aether_flutter/features/downloads/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aether_dlq'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> until(bool Function() ok, String what, {int tries = 200}) async {
    for (var i = 0; i < tries; i++) {
      if (ok()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('timeout: $what');
  }

  DownloadManager make(FakeHandler h) =>
      DownloadManager(store: MemoryStore(), directory: dir, dio: fakeDio(h));

  Future<DownloadItem> add(
    DownloadManager m,
    String id, {
    List<DownloadFallback> fallbacks = const [],
    Map<String, String> headers = const {},
  }) => m.enqueue(
    metaId: 'tt1',
    videoId: id,
    type: 'series',
    title: 'Show · S01E0$id',
    url: 'https://a.example/$id.mkv',
    season: 1,
    episode: int.parse(id),
    fallbacks: fallbacks,
    headers: headers,
  );

  test('when a source fails the next one of the same episode is tried; its headers are sent', () async {
    final seen = <String>[];
    final m = make((o) {
      seen.add('${o.uri.host}|${o.headers['X-Token']}');
      return o.uri.host == 'a.example'
          ? (status: 404, body: 'no')
          : (status: 200, body: 'OK');
    });
    final item = await add(
      m,
      '1',
      headers: {'X-Token': 'A'},
      fallbacks: const [
        DownloadFallback('https://b.example/1.mkv', headers: {'X-Token': 'B'}),
      ],
    );
    await until(() => item.status == DownloadStatus.done, 'fallback');
    expect(seen, ['a.example|A', 'b.example|B']);
    expect(item.url, 'https://b.example/1.mkv');
    expect(item.fallbacks, isEmpty);
  });

  test(
    'without alternatives a failure is reported with its HTTP code',
    () async {
      final m = make((o) => (status: 404, body: 'no'));
      final item = await add(m, '2');
      await until(() => item.status == DownloadStatus.failed, 'failure');
      expect(item.error, contains('404'));
    },
  );

  test('a 5xx is retried (twice at most) before giving up', () async {
    var calls = 0;
    final m = make((o) {
      calls++;
      return (status: 503, body: 'busy');
    });
    final item = await add(m, '3');
    await until(
      () => item.status == DownloadStatus.failed,
      'gave up',
      tries: 700,
    );
    expect(calls, 3); // the first try and two retries
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('only as many transfers run at once as the limit allows; the rest wait in the queue', () async {
    final m = make((o) => (status: 200, body: 'X' * 10));
    m.maxConcurrent = 1;
    m.networkAllowed = () async => true;
    final a = await add(m, '4');
    final b = await add(m, '5');
    expect(
      [a, b].where((d) => d.status == DownloadStatus.running).length,
      lessThanOrEqualTo(1),
    );
    await until(
      () => a.status == DownloadStatus.done && b.status == DownloadStatus.done,
      'both',
    );
  });

  test('on mobile data only, nothing starts until it is allowed', () async {
    var allowed = false;
    final m = make((o) => (status: 200, body: 'OK'));
    m.networkAllowed = () async => allowed;
    final item = await add(m, '6');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(item.status, DownloadStatus.queued);
    expect(item.error, contains('Wi-Fi'));
    allowed = true;
    await m.resume(item.id);
    await until(() => item.status == DownloadStatus.done, 'started');
  });
}
