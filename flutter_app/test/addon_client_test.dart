import 'dart:convert';

import 'package:aether_flutter/core/addons/addon_client.dart';
import 'package:aether_flutter/core/addons/addon_repository.dart';
import 'package:aether_flutter/core/addons/network_policy.dart';
import 'package:aether_flutter/core/model/manifest.dart';
import 'package:aether_flutter/data/stores.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

const _manifest = '{"id":"org.fake","name":"Fake","version":"1.0.0","resources":["catalog","stream","meta","subtitles"],"types":["movie","series"],"idPrefixes":["tt"],'
    '"catalogs":[{"type":"movie","id":"top","name":"Top","extra":[{"name":"skip"}]}]}';

void main() {
  test('resource uri encodes type, id and extra', () {
    final uri = AddonClient.resourceUri(Uri.parse('https://x.example/cfg'), 'catalog', 'movie', 'top', extra: {'search': 'a b', 'skip': '20'});
    expect(uri.toString(), 'https://x.example/cfg/catalog/movie/top/search=a%20b&skip=20.json');
    final stream = AddonClient.resourceUri(Uri.parse('https://x.example'), 'stream', 'series', 'tt1:1:2');
    expect(stream.path, '/stream/series/tt1%3A1%3A2.json');
  });

  test('catalog, meta, streams and subtitles are read', () async {
    final dio = fakeDio((o) {
      final p = o.uri.path;
      if (p.endsWith('/manifest.json')) return (status: 200, body: _manifest);
      if (p.contains('/catalog/')) return (status: 200, body: '{"metas":[{"id":"tt1","type":"movie","name":"A"},{"nope":1}],"cacheMaxAge":120}');
      if (p.contains('/meta/')) return (status: 200, body: '{"meta":{"id":"tt1","type":"movie","name":"A","description":"d"}}');
      if (p.contains('/stream/')) return (status: 200, body: '{"streams":[{"url":"https://c/a.mp4","name":"x"},{"bad":true}]}');
      return (status: 200, body: '{"subtitles":[{"id":"1","url":"https://s/a.srt","lang":"ita"}]}');
    });
    final client = AddonClient(dio: dio);
    final base = Uri.parse('https://x.example');
    final manifest = await client.fetchManifest(base);
    expect(manifest.name, 'Fake');
    final page = await client.catalog(base, manifest.catalogs.first);
    expect(page.items.map((e) => e.id), ['tt1']);
    expect(page.cacheMaxAge, 120);
    expect((await client.meta(base, 'movie', 'tt1'))!.description, 'd');
    expect((await client.streams(base, 'movie', 'tt1')).length, 1);
    expect((await client.subtitles(base, 'movie', 'tt1')).single.lang, 'ita');
  });

  test('errors are readable: http status, bad json, blocked host', () async {
    final base = Uri.parse('https://x.example');
    var status = 500;
    var body = '';
    final client = AddonClient(dio: fakeDio((o) => (status: status, body: body)));
    await expectLater(client.fetchManifest(base), throwsA(isA<AddonException>().having((e) => e.retryable, 'retryable', true)));
    status = 200;
    body = '<html>';
    await expectLater(client.fetchManifest(base), throwsA(isA<AddonException>().having((e) => e.message, 'm', contains('JSON'))));
    body = '{"id":"x"}';
    await expectLater(client.fetchManifest(base), throwsA(isA<AddonException>().having((e) => e.message, 'm', contains('Manifest non valido'))));
    await expectLater(client.fetchManifest(Uri.parse('http://127.0.0.1:1')), throwsA(isA<AddonException>()));
  });

  test('responses are cached by cacheMaxAge', () async {
    var calls = 0;
    final client = AddonClient(dio: fakeDio((o) {
      calls++;
      return (status: 200, body: '{"metas":[],"cacheMaxAge":300}');
    }));
    final cat = ManifestCatalog.parse({'type': 'movie', 'id': 'a', 'name': 'a'})!;
    final base = Uri.parse('https://x.example');
    await client.catalog(base, cat);
    await client.catalog(base, cat);
    expect(calls, 1);
  });

  test('cancelled requests report cancellation', () async {
    final client = AddonClient(dio: Dio());
    final token = CancelToken()..cancel();
    await expectLater(client.fetchManifest(Uri.parse('https://x.example'), cancel: token), throwsA(isA<AddonException>()));
  });

  group('repository', () {
    late MemoryStore store;
    late MemorySecretStore secrets;
    late AddonRepository repo;

    AddonRepository make() => AddonRepository(store: store, secrets: secrets, client: AddonClient(dio: fakeDio((o) => (status: 200, body: _manifest))));

    setUp(() {
      store = MemoryStore();
      secrets = MemorySecretStore();
      repo = make();
    });

    test('install keeps the address in the secret store only, and survives a restart', () async {
      final preview = await repo.preview('stremio://x.example/secretcfg/manifest.json');
      final addon = await repo.install(preview);
      expect(await secrets.read('addon.${addon.id}.url'), 'https://x.example/secretcfg');
      expect(store.data.values.join(), isNot(contains('secretcfg')));
      final again = make();
      await again.load();
      expect(again.addons.single.manifest.id, 'org.fake');
      expect(again.addons.single.base.path, '/secretcfg');
    });

    test('duplicates are not installed twice; toggle, rename, order and remove work', () async {
      final a = await repo.install(await repo.preview('https://x.example/one'));
      final b = await repo.install(await repo.preview('https://y.example/two'));
      expect((await repo.preview('https://x.example/one')).alreadyInstalled, isTrue);
      expect(repo.addons.length, 2);
      await repo.setEnabled(a.id, false);
      expect(repo.enabled.map((e) => e.id), [b.id]);
      await repo.move(b.id, -1);
      expect(repo.addons.first.id, b.id);
      await repo.rename(b.id, 'Mio');
      expect(repo.addons.first.displayName, 'Mio');
      await repo.setCatalogVisible(b.id, b.manifest.catalogs.first, false);
      expect(repo.addons.first.isCatalogVisible(b.manifest.catalogs.first), isFalse);
      await repo.remove(a.id);
      expect(repo.addons.length, 1);
      expect(await secrets.read('addon.${a.id}.url'), isNull);
      final again = make();
      await again.load();
      expect(again.addons.first.nameOverride, 'Mio');
      expect(again.addons.first.hiddenCatalogs, {'movie/top'});
    });

    test('preview warns about p2p / adult / http and rejects garbage', () async {
      final warn = AddonRepository(
        store: store,
        secrets: secrets,
        client: AddonClient(dio: fakeDio((o) => (status: 200, body: jsonEncode({'id': 'p', 'name': 'P', 'resources': ['stream'], 'behaviorHints': {'p2p': true, 'adult': true}})))),
        );
      final p = await warn.preview('http://x.example/m');
      expect(p.warnings.length, 3);
      await expectLater(repo.preview('boh'), throwsA(isA<AddonException>()));
    });

    test('providers() follows priority and resource rules', () async {
      await repo.install(await repo.preview('https://x.example/one'));
      expect(repo.providers('stream', 'movie', 'tt1').length, 1);
      expect(repo.providers('stream', 'movie', 'kitsu:1'), isEmpty);
      expect(repo.providers('addon_catalog', 'movie', 'tt1'), isEmpty);
    });
  });

  test('NetworkPolicy setter is honored by the client', () async {
    final client = AddonClient(dio: fakeDio((o) => (status: 200, body: _manifest)));
    final lan = Uri.parse('http://192.168.1.2:7000');
    await expectLater(client.fetchManifest(lan), throwsA(isA<AddonException>()));
    client.policy = const NetworkPolicy(allowLocalNetwork: true);
    expect((await client.fetchManifest(lan)).id, 'org.fake');
  });
}
