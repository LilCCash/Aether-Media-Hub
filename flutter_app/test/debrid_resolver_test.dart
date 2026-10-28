import 'dart:convert';

import 'package:aether_flutter/core/debrid/debrid_resolver.dart';
import 'package:aether_flutter/core/debrid/torbox_client.dart';
import 'package:aether_flutter/core/model/stream.dart';
import 'package:dio/dio.dart' show FormData;
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

AddonStream get _torrent => AddonStream(infoHash: 'a' * 40, name: 'x', fileIdx: 0);

TorBoxClient _client(FakeHandler h) => TorBoxClient(keyProvider: () async => 'K', dio: fakeDio(h));

void main() {
  const fast = Duration(milliseconds: 5);

  test('cached torrent: add only if cached, wait for the files, choose the right episode, get a link', () async {
    final paths = <String>[];
    var mylistCalls = 0;
    final resolver = DebridResolver(_client((o) {
      paths.add(o.uri.path.split('/').last);
      if (o.uri.path.endsWith('createtorrent')) return (status: 200, body: '{"success":true,"data":{"torrent_id":3}}');
      if (o.uri.path.endsWith('mylist')) {
        if (!o.uri.queryParameters.containsKey('id')) return (status: 200, body: '{"success":true,"data":[]}');
        mylistCalls++;
        final ready = mylistCalls >= 2;
        return (status: 200, body: jsonEncode({'success': true, 'data': {'id': 3, 'hash': 'a' * 40, 'download_finished': ready, 'download_present': ready, 'progress': 0.5, 'files': [
          {'id': 0, 'name': 'Show.S01E01.mkv', 'size': 100}, {'id': 1, 'name': 'Show.S01E02.mkv', 'size': 90}]}}));
      }
      return (status: 200, body: '{"success":true,"data":"https://cdn.example/dl"}');
    }), pollInterval: fast);
    final statuses = <String>[];
    final link = await resolver.resolve(_torrent, season: 1, episode: 2, onStatus: (s) => statuses.add(s.message));
    expect(link.fileName, 'Show.S01E02.mkv');
    expect(link.uri.host, 'cdn.example');
    expect(paths, contains('createtorrent'));
    expect(statuses, contains('Controllo TorBox…'));
  });

  test('not cached and no permission to download: stops with notCached and starts nothing', () async {
    var createdWithoutCacheFlag = false;
    final resolver = DebridResolver(_client((o) {
      if (o.uri.path.endsWith('mylist')) return (status: 200, body: '{"success":true,"data":[]}');
      final fields = {for (final f in (o.data as FormData).fields) f.key: f.value};
      if (fields['add_only_if_cached'] != 'true') createdWithoutCacheFlag = true;
      return (status: 409, body: '{"success":false}');
    }), pollInterval: fast);
    await expectLater(resolver.resolve(_torrent), throwsA(isA<DebridException>().having((e) => e.failure, 'failure', DebridFailure.notCached)));
    expect(createdWithoutCacheFlag, isFalse);
  });

  test('already in the account: reuses it without adding again', () async {
    var added = false;
    final resolver = DebridResolver(_client((o) {
      if (o.uri.path.endsWith('createtorrent')) added = true;
      if (o.uri.path.endsWith('mylist')) {
        return o.uri.queryParameters.containsKey('id')
            ? (status: 200, body: jsonEncode({'success': true, 'data': {'id': 9, 'download_finished': true, 'download_present': true, 'files': [{'id': 4, 'name': 'a.mp4', 'size': 5}]}}))
            : (status: 200, body: jsonEncode({'success': true, 'data': [{'id': 9, 'hash': 'A' * 40}]}));
      }
      return (status: 200, body: '{"success":true,"data":"https://cdn.example/x"}');
    }), pollInterval: fast);
    await resolver.resolve(_torrent);
    expect(added, isFalse);
  });

  test('cancellation and timeouts are reported', () async {
    final resolver = DebridResolver(_client((o) {
      if (o.uri.path.endsWith('createtorrent')) return (status: 200, body: '{"success":true,"data":{"torrent_id":1}}');
      return (status: 200, body: '{"success":true,"data":{"id":1,"download_finished":false,"download_present":false,"progress":0.1}}');
    }), pollInterval: fast, maxCachedWait: const Duration(milliseconds: 30));
    await expectLater(resolver.resolve(_torrent), throwsA(isA<DebridException>().having((e) => e.failure, 'f', DebridFailure.notReady)));
    expect(() => resolver.resolve(const AddonStream(url: 'https://x/a.mp4')), throwsA(isA<DebridException>()));
  });
}
