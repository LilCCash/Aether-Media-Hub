import 'dart:convert';

import 'package:aether_flutter/core/debrid/real_debrid_client.dart';
import 'package:aether_flutter/core/debrid/torbox_client.dart';
import 'package:aether_flutter/core/metadata/fanart_client.dart';
import 'package:aether_flutter/core/metadata/mdblist_client.dart';
import 'package:aether_flutter/core/metadata/tvdb_client.dart';
import 'package:aether_flutter/core/model/stream.dart';
import 'package:aether_flutter/core/segments/skip_segments.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

({int status, String body}) ok(Object json) =>
    (status: 200, body: jsonEncode(json));

void main() {
  group('fanart.tv', () {
    test('prefers the viewer language, then English, then likes; only fanart.tv https', () {
      final url = FanartClient.bestLogo([
        {'url': 'https://assets.fanart.tv/a.png', 'lang': 'en', 'likes': '9'},
        {'url': 'https://assets.fanart.tv/b.png', 'lang': 'it', 'likes': '1'},
        {'url': 'https://evil.example/c.png', 'lang': 'it', 'likes': '99'},
        {'url': 'http://assets.fanart.tv/d.png', 'lang': 'it', 'likes': '50'},
      ], 'it-IT');
      expect(url, 'https://assets.fanart.tv/b.png');
      expect(FanartClient.bestLogo([], 'it'), isNull);
    });

    test(
      'asks with the key, never without one, and a failure is "no logo"',
      () async {
        Uri? asked;
        final client = FanartClient(
          keyProvider: () async => 'KEY',
          dio: fakeDio((o) {
            asked = o.uri;
            return ok({
              'hdmovielogo': [
                {
                  'url': 'https://assets.fanart.tv/x.png',
                  'lang': 'en',
                  'likes': 3,
                },
              ],
            });
          }),
        );
        expect(
          await client.logoUrl(FanartKind.movie, 'tt0111161', 'en'),
          'https://assets.fanart.tv/x.png',
        );
        expect(asked!.path, endsWith('/movies/tt0111161'));
        expect(asked!.queryParameters['api_key'], 'KEY');
        expect(await client.logoUrl(FanartKind.movie, '../x', 'en'), isNull);

        final none = FanartClient(
          keyProvider: () async => null,
          dio: fakeDio((o) => fail('no request without a key')),
        );
        expect(await none.logoUrl(FanartKind.tv, '1', 'en'), isNull);
        final broken = FanartClient(
          keyProvider: () async => 'KEY',
          dio: fakeDio((o) => (status: 500, body: 'oops')),
        );
        expect(await broken.logoUrl(FanartKind.tv, '1', 'en'), isNull);
      },
    );
  });

  group('MDBList', () {
    test('ratings are written the way each service writes its scale and deduplicated', () {
      final r = MdbListClient.parse({
        'ratings': [
          {'source': 'imdb', 'value': 8.7, 'votes': 100},
          {'source': 'tomatoes', 'value': 91, 'score': 91},
          {'source': 'metacritic', 'value': 82},
          {'source': 'imdb', 'value': 1},
          {'source': 'trakt', 'score': 80.4},
          {'source': 'letterboxd'},
          'junk',
        ],
      });
      expect(r.map((e) => '${e.source}=${e.display}'), [
        'imdb=8.7',
        'tomatoes=91%',
        'metacritic=82',
        'trakt=80%',
      ]);
      expect(r.first.title, 'IMDb');
    });

    test('the key travels as apikey, a missing key makes no request', () async {
      Uri? asked;
      final client = MdbListClient(
        keyProvider: () async => 'K',
        dio: fakeDio((o) {
          asked = o.uri;
          return ok({
            'ratings': [
              {'source': 'imdb', 'value': 7.0},
            ],
          });
        }),
      );
      expect((await client.ratings(603, isMovie: true)).length, 1);
      expect(asked!.path, '/tmdb/movie/603');
      expect(asked!.queryParameters['apikey'], 'K');
      expect(
        await MdbListClient(
          keyProvider: () async => '',
          dio: fakeDio((o) => fail('no request')),
        ).ratings(1, isMovie: false),
        isEmpty,
      );
      expect(
        await MdbListClient(
          keyProvider: () async => 'K',
          dio: fakeDio((o) => (status: 401, body: '{}')),
        ).check(),
        contains('non accetta'),
      );
    });
  });

  group('TheTVDB', () {
    test('logs in once, retries after a 401, translates episodes', () async {
      var logins = 0;
      var first401 = true;
      final client = TvdbClient(
        keyProvider: () async => 'KEY',
        pinProvider: () async => '',
        dio: fakeDio((o) {
          if (o.path.endsWith('/login')) {
            logins++;
            return ok({
              'data': {'token': 'T$logins'},
            });
          }
          if (o.path.contains('/search/remoteid/')) {
            if (first401) {
              first401 = false;
              return (status: 401, body: '{}');
            }
            return ok({
              'data': [
                {
                  'series': {'id': 81189},
                },
              ],
            });
          }
          return ok({
            'data': {
              'episodes': [
                {
                  'seasonNumber': 1,
                  'number': 2,
                  'name': 'Titolo',
                  'overview': 'Trama',
                },
                {'seasonNumber': 1},
              ],
            },
            'links': {'next': null},
          });
        }),
      );
      expect(await client.seriesIdForImdb('tt0903747'), 81189);
      expect(logins, 2); // the first token was refused
      final eps = await client.episodes(81189, 'ita');
      expect(eps.single.name, 'Titolo');
      expect(eps.single.season, 1);
      expect(eps.single.number, 2);
      expect(logins, 2); // the new token is reused
    });

    test('a refused key reports a reason without echoing it', () async {
      final client = TvdbClient(
        keyProvider: () async => 'SECRET-KEY',
        pinProvider: () async => null,
        dio: fakeDio((o) => (status: 401, body: '{"status":"failure"}')),
      );
      final reason = await client.check();
      expect(reason, isNotNull);
      expect(reason, isNot(contains('SECRET-KEY')));
    });
  });

  group('IntroDB', () {
    test('parses seconds and milliseconds, rejects implausible lengths', () {
      final s = IntroDbClient.parse({
        'intro': {'start_sec': 10.0, 'end_sec': 95.5},
        'recap': {'start_ms': 0, 'end_ms': 2000}, // 2 s: too short
      });
      expect(s.intro!.start, 10);
      expect(s.intro!.end, 95.5);
      expect(s.recap, isNull);
      final ms = IntroDbClient.parse({
        'recap': {'start_ms': 1000, 'end_ms': 31000},
      });
      expect(ms.recap!.end, 31);
      expect(
        IntroDbClient.parse({
          'intro': {'start_sec': 0, 'end_sec': 5000},
        }).isEmpty,
        isTrue,
      );
    });

    test('the button window: from 1 s before the start to 1 s before the end; a cut of another length is ignored', () {
      const segs = EpisodeSkipSegments(
        intro: SkipSegment(SkipKind.intro, 30, 90),
      );
      expect(segs.active(28), isNull);
      expect(segs.active(29.5)?.kind, SkipKind.intro);
      expect(segs.active(60)?.kind, SkipKind.intro);
      expect(segs.active(89.5), isNull);
      expect(
        segs.active(60, duration: 40),
        isNull,
      ); // file shorter than the data says
      expect(segs.active(double.nan), isNull);
    });

    test('asks with a valid IMDb id only; 404 means nothing is known; the service caches', () async {
      var calls = 0;
      final client = IntroDbClient(
        dio: fakeDio((o) {
          calls++;
          expect(o.uri.queryParameters['imdb_id'], 'tt0903747');
          return o.uri.queryParameters['episode'] == '9'
              ? (status: 404, body: '{}')
              : ok({
                  'intro': {'start_sec': 5, 'end_sec': 60},
                });
        }),
      );
      expect(await client.segments('nope', 1, 1), isNull);
      expect(calls, 0);
      expect((await client.segments('tt0903747', 1, 9))!.isEmpty, isTrue);
      final service = SkipSegmentsService(client);
      expect((await service.segments('tt0903747', 1, 1))!.intro, isNotNull);
      await service.segments('tt0903747', 1, 1);
      expect(calls, 2); // the second answer came from memory
    });
  });

  group('Real-Debrid', () {
    final stream = AddonStream(infoHash: 'A' * 40, name: 'x');

    RealDebridClient make(
      List<String> log, {
      bool inAccount = false,
      String key = 'RD-SECRET',
    }) {
      var polls = 0;
      return RealDebridClient(
        keyProvider: () async => key,
        pollInterval: Duration.zero,
        dio: fakeDio((o) {
          log.add('${o.method} ${o.path}');
          expect(o.headers['Authorization'], 'Bearer $key');
          final p = o.path;
          if (p.endsWith('/torrents') && o.method == 'GET') {
            return ok(
              inAccount
                  ? [
                      {'id': 'T1', 'hash': 'a' * 40},
                    ]
                  : [],
            );
          }
          if (p.endsWith('/torrents/addMagnet')) {
            expect(o.data, isA<Map>());
            expect(
              (o.data as Map)['magnet'],
              startsWith('magnet:?xt=urn:btih:'),
            );
            return ok({'id': 'T1'});
          }
          if (p.contains('/torrents/selectFiles/')) {
            return (status: 204, body: '');
          }
          if (p.contains('/torrents/info/')) {
            polls++;
            if (polls == 1) {
              return ok({'status': 'waiting_files_selection'});
            }
            if (polls == 2) {
              return ok({'status': 'downloading', 'progress': 40});
            }
            return ok({
              'status': 'downloaded',
              'files': [
                {'id': 1, 'path': '/x/readme.txt', 'bytes': 10, 'selected': 1},
                {'id': 2, 'path': '/x/film.mkv', 'bytes': 9000, 'selected': 1},
              ],
              'links': ['https://rd/l1', 'https://rd/l2'],
            });
          }
          if (p.endsWith('/unrestrict/link')) {
            expect((o.data as Map)['link'], 'https://rd/l2');
            return ok({'download': 'https://dl.rd/film.mkv'});
          }
          return (status: 404, body: '{}');
        }),
      );
    }

    test(
      'without confirmation a torrent that is not in the account is not added',
      () async {
        final log = <String>[];
        await expectLater(
          make(log).resolve(stream),
          throwsA(
            isA<DebridException>().having(
              (e) => e.failure,
              'failure',
              DebridFailure.notCached,
            ),
          ),
        );
        expect(log.where((l) => l.contains('addMagnet')), isEmpty);
      },
    );

    test('with confirmation: adds, selects the files, waits, picks the video, unrestricts to https', () async {
      final log = <String>[];
      final progress = <String>[];
      final link = await make(log).resolve(
        stream,
        allowDownload: true,
        onStatus: (s) => progress.add(s.message),
      );
      expect(link.uri.toString(), 'https://dl.rd/film.mkv');
      expect(link.fileName, '/x/film.mkv');
      expect(log.where((l) => l.contains('addMagnet')).length, 1);
      expect(log.where((l) => l.contains('selectFiles')).length, 1);
      expect(progress.any((m) => m.contains('40%')), isTrue);
    });

    test(
      'a torrent already in the account is reused without adding it',
      () async {
        final log = <String>[];
        await make(log, inAccount: true).resolve(stream);
        expect(log.where((l) => l.contains('addMagnet')), isEmpty);
      },
    );

    test('has no cache probe and never leaks the token in an error', () async {
      expect(await make([]).cached(['a']), isNull);
      final client = RealDebridClient(
        keyProvider: () async => 'RD-SECRET',
        dio: fakeDio((o) => (status: 401, body: '{}')),
      );
      try {
        await client.check();
        fail('expected a failure');
      } on DebridException catch (e) {
        expect(e.failure, DebridFailure.invalidKey);
        expect(e.message, isNot(contains('RD-SECRET')));
      }
      expect(
        () => RealDebridClient(
          keyProvider: () async => null,
          dio: fakeDio((o) => fail('no request')),
        ).check(),
        throwsA(
          isA<DebridException>().having(
            (e) => e.failure,
            'failure',
            DebridFailure.notConfigured,
          ),
        ),
      );
    });
  });
}
