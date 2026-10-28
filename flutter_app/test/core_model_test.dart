import 'dart:convert';

import 'package:aether_flutter/core/addons/network_policy.dart';
import 'package:aether_flutter/core/model/manifest.dart';
import 'package:aether_flutter/core/model/meta.dart';
import 'package:aether_flutter/core/model/stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('manifest', () {
    test('parses resources as strings and objects, catalogs and extras', () {
      final m = AddonManifest.parse(
        jsonDecode('''
      {"id":"org.test","name":"Test","version":"1.2.3","types":["movie","series"],"idPrefixes":["tt"],
       "resources":["catalog",{"name":"stream","types":["movie"],"idPrefixes":["tt"]},{"name":"meta"}],
       "catalogs":[{"type":"movie","id":"top","name":"Top","extra":[{"name":"genre","options":["Azione","Dramma"]},{"name":"skip"}]},
                   {"type":"movie","id":"search","name":"Cerca","extra":[{"name":"search","isRequired":true}]}],
       "behaviorHints":{"configurable":true,"p2p":true}}'''),
      );
      expect(m.name, 'Test');
      expect(m.resources.map((r) => r.name), ['catalog', 'stream', 'meta']);
      expect(m.catalogs.first.genres, ['Azione', 'Dramma']);
      expect(m.catalogs.first.isBrowsable, isTrue);
      expect(m.catalogs[1].isBrowsable, isFalse);
      expect(m.catalogs[1].isSearchable, isTrue);
      expect(m.behaviorHints.configurable, isTrue);
      expect(AddonManifest.parse(m.toJson()).catalogs.length, 2);
    });

    test('legacy extraSupported / extraRequired are understood', () {
      final m = AddonManifest.parse({
        'id': 'x',
        'name': 'x',
        'resources': ['catalog'],
        'catalogs': [
          {
            'type': 'movie',
            'id': 'a',
            'extraSupported': ['search', 'skip'],
            'extraRequired': ['search'],
          },
        ],
      });
      expect(m.catalogs.single.isSearchable, isTrue);
      expect(m.catalogs.single.isBrowsable, isFalse);
    });

    test('provides respects resource-level types and id prefixes', () {
      final m = AddonManifest.parse({
        'id': 'x',
        'name': 'x',
        'types': ['movie', 'series'],
        'idPrefixes': ['tt'],
        'resources': [
          {
            'name': 'stream',
            'types': ['movie'],
            'idPrefixes': ['tt'],
          },
          'meta',
        ],
      });
      expect(m.provides('stream', 'movie', 'tt1'), isTrue);
      expect(m.provides('stream', 'series', 'tt1'), isFalse);
      expect(m.provides('stream', 'movie', 'kitsu:1'), isFalse);
      expect(m.provides('meta', 'series', 'tt1'), isTrue);
      expect(m.provides('subtitles', 'movie', 'tt1'), isFalse);
    });

    test('invalid manifests give readable errors', () {
      expect(() => AddonManifest.parse('nope'), throwsFormatException);
      expect(
        () => AddonManifest.parse({
          'name': 'x',
          'resources': ['catalog'],
        }),
        throwsFormatException,
      );
      expect(
        () => AddonManifest.parse({'id': 'x', 'name': 'x'}),
        throwsFormatException,
      );
    });
  });

  group('meta and stream', () {
    test('series are detected and seasons sorted', () {
      final m = MetaItem.parse({
        'id': 'tt1',
        'type': 'series',
        'name': 'S',
        'genres': ['A'],
        'videos': [
          {'id': 'tt1:2:1', 'season': 2, 'episode': 1, 'title': 'b'},
          {'id': 'tt1:1:2', 'season': 1, 'episode': 2, 'title': 'a2'},
          {'id': 'tt1:1:1', 'season': 1, 'episode': 1, 'name': 'a1'},
        ],
      })!;
      expect(m.isSeries, isTrue);
      expect(m.seasons, [1, 2]);
      expect(m.episodesOf(1).map((e) => e.title), ['a1', 'a2']);
      expect(m.episodesOf(1).first.label, 'S01E01');
    });

    test('malformed fields never throw', () {
      final m = MetaItem.parse({
        'id': 'tt2',
        'name': 5,
        'genres': 'x',
        'videos': 'oops',
        'imdbRating': 7.5,
      });
      expect(m, isNotNull);
      expect(m!.imdbRating, '7.5');
      expect(m.genres, ['x']);
      expect(MetaItem.parse({'name': 'no id'}), isNull);
    });

    test('streams: direct, torrent, headers and trackers', () {
      final s = AddonStream.parse({
        'infoHash': 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
        'fileIdx': 2,
        'sources': ['tracker:udp://t.example:80', 'dht:x'],
        'name': 'Torrentio\n1080p',
        'title': 'Film 1080p',
        'behaviorHints': {
          'bingeGroup': 'g',
          'videoSize': 123,
          'proxyHeaders': {
            'request': {'User-Agent': 'u'},
          },
        },
      }, addonName: 'T')!;
      expect(s.isTorrent, isTrue);
      expect(s.infoHash, 'abcdef0123456789abcdef0123456789abcdef01');
      expect(s.magnet, contains('xt=urn:btih:abcdef'));
      expect(s.magnet, contains('tr=udp'));
      expect(s.proxyHeaders['User-Agent'], 'u');
      expect(AddonStream.parse({'name': 'nothing playable'}), isNull);
      expect(AddonStream.parse({'url': 'https://x/y.mp4'})!.isDirect, isTrue);
    });
  });

  group('network policy and addon urls', () {
    const policy = NetworkPolicy();
    const lan = NetworkPolicy(allowLocalNetwork: true);

    test('blocks loopback always, private networks unless allowed', () {
      expect(
        policy.reject(Uri.parse('https://addon.example/manifest.json')),
        isNull,
      );
      expect(policy.reject(Uri.parse('http://localhost:8080/x')), isNotNull);
      expect(policy.reject(Uri.parse('http://127.0.0.1/x')), isNotNull);
      expect(lan.reject(Uri.parse('http://127.0.0.1/x')), isNotNull);
      expect(
        policy.reject(Uri.parse('http://192.168.1.5:7000/manifest.json')),
        isNotNull,
      );
      expect(
        lan.reject(Uri.parse('http://192.168.1.5:7000/manifest.json')),
        isNull,
      );
      expect(policy.reject(Uri.parse('http://nas.local/m')), isNotNull);
      expect(policy.reject(Uri.parse('ftp://x.example/a')), isNotNull);
      expect(
        policy.reject(Uri.parse('https://user:pw@x.example/a')),
        isNotNull,
      );
    });

    test('accepts stremio:// and aether:// links and strips manifest.json', () {
      expect(
        AddonUrl.parseBase('stremio://v3-cinemeta.strem.io/manifest.json')
            .toString(),
        'https://v3-cinemeta.strem.io',
      );
      expect(
        AddonUrl.parseBase('https://x.example/cfg/abc/manifest.json')!.path,
        '/cfg/abc',
      );
      expect(AddonUrl.parseBase('https://x.example/cfg/')!.path, '/cfg');
      expect(
        AddonUrl.parseBase(
          'aether://addon?url=https%3A%2F%2Fx.example%2Fm%2Fmanifest.json',
        )!.path,
        '/m',
      );
      expect(AddonUrl.parseBase('not a url'), isNull);
      expect(
        AddonUrl.manifest(Uri.parse('https://x.example/cfg')).path,
        '/cfg/manifest.json',
      );
    });
  });
}
