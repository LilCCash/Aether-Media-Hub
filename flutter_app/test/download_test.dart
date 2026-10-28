import 'dart:io';

import 'package:aether_flutter/data/stores.dart';
import 'package:aether_flutter/features/downloads/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aether_dl'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> settle(DownloadManager m, String id, DownloadStatus s) async {
    for (var i = 0; i < 100; i++) {
      if (m.items.firstWhere((e) => e.id == id).status == s) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('download did not reach $s: ${m.items.map((e) => e.status)}');
  }

  test('downloads a file, persists it and exposes the local path', () async {
    final store = MemoryStore();
    final m = DownloadManager(
      store: store,
      directory: dir,
      dio: fakeDio((o) => (status: 200, body: 'HELLOWORLD')),
    );
    final item = await m.enqueue(
      metaId: 'tt1',
      videoId: 'tt1',
      type: 'movie',
      title: 'Film',
      url: 'https://cdn.example/a/film.mkv',
    );
    await settle(m, item.id, DownloadStatus.done);
    expect(File(m.pathOf(item)).readAsStringSync(), 'HELLOWORLD');
    expect(m.pathOf(item), endsWith('.mkv'));
    expect(m.localPath('tt1'), m.pathOf(item));
    final again = DownloadManager(store: store, directory: dir);
    await again.load();
    expect(again.localPath('tt1'), isNotNull);
    await again.remove(item.id);
    expect(File(m.pathOf(item)).existsSync(), isFalse);
  });

  test(
    'a partial file resumes with a Range request when the server supports it',
    () async {
      final seen = <String?>[];
      final m = DownloadManager(
        store: MemoryStore(),
        directory: dir,
        dio: fakeDio((o) {
          seen.add(o.headers['Range'] as String?);
          return o.headers.containsKey('Range')
              ? (status: 206, body: 'WORLD')
              : (status: 200, body: 'HELLOWORLD');
        }),
      );
      final item = await m.enqueue(
        metaId: 'a',
        videoId: 'a',
        type: 'movie',
        title: 'a',
        url: 'https://cdn.example/a.mp4',
      );
      await settle(m, item.id, DownloadStatus.done);
      // Simulate an interrupted download: only the first half is on disk.
      File(m.pathOf(item)).renameSync('${m.pathOf(item)}.part');
      File('${m.pathOf(item)}.part').writeAsStringSync('HELLO');
      item.status = DownloadStatus.paused;
      await m.resume(item.id);
      await settle(m, item.id, DownloadStatus.done);
      expect(seen.last, 'bytes=5-');
      expect(File(m.pathOf(item)).readAsStringSync(), 'HELLOWORLD');
    },
  );

  test(
    'server errors fail with a message; local addresses are refused',
    () async {
      final m = DownloadManager(
        store: MemoryStore(),
        directory: dir,
        dio: fakeDio((o) => (status: 404, body: '')),
      );
      final item = await m.enqueue(
        metaId: 'a',
        videoId: 'a',
        type: 'movie',
        title: 'a',
        url: 'https://cdn.example/a.mp4',
      );
      await settle(m, item.id, DownloadStatus.failed);
      expect(item.error, contains('404'));
      expect(
        () => m.enqueue(
          metaId: 'b',
          videoId: 'b',
          type: 'movie',
          title: 'b',
          url: 'http://127.0.0.1/a.mp4',
        ),
        throwsFormatException,
      );
    },
  );
}
