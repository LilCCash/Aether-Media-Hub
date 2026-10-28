import 'dart:convert';

import 'package:dio/dio.dart' show RequestOptions;

import 'package:aether_flutter/core/debrid/torbox_client.dart';
import 'package:aether_flutter/core/metadata/tmdb_client.dart';
import 'package:aether_flutter/core/model/meta.dart';
import 'package:aether_flutter/core/model/stream.dart';
import 'package:aether_flutter/core/streams/stream_analyzer.dart';
import 'package:aether_flutter/core/subtitles/subtitle_loader.dart';
import 'package:aether_flutter/core/subtitles/subtitle_parser.dart';
import 'package:aether_flutter/core/util/app_log.dart';
import 'package:aether_flutter/data/library_repository.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/data/stores.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

AddonStream _s(String text, {String? url = 'https://c/a.mkv', String? hash}) =>
    AddonStream(
      url: hash == null ? url : null,
      infoHash: hash,
      name: text,
      addonName: 'A',
    );

void main() {
  group('stream analyzer & ranker', () {
    test('reads quality, codec, hdr, audio, language, size, format and release from names', () {
      final info = StreamAnalyzer.analyze(
        AddonStream(
          url: 'https://c/Film.2160p.REMUX.HEVC.DV.HDR10.TrueHD.Atmos.ITA.ENG.mkv',
          name: 'Addon\n💾 54.3 GB',
        ),
      );
      expect(info.quality, VideoQuality.p2160);
      expect(info.codec, 'HEVC');
      expect(info.hdr, containsAll([HdrFormat.dolbyVision, HdrFormat.hdr10]));
      expect(info.audio, 'Dolby Atmos');
      expect(info.languages, containsAll(['Italiano', 'Inglese']));
      expect(info.release, 'Remux');
      expect(info.format, 'MKV');
      expect(info.sizeLabel, '54.3 GB');
    });

    test('no false positives on ordinary words', () {
      final info = StreamAnalyzer.analyze(_s('Thirty Dvorak Standard Story'));
      expect(info.quality, VideoQuality.unknown);
      expect(info.hdr, isEmpty);
      expect(info.languages, isEmpty);
    });

    test('direct playable first, torrents only with debrid, cam last, preferred language boosts', () {
      final list = [
        _s('1080p WEB-DL ENG'),
        _s('2160p WEB-DL ENG', hash: 'a' * 40),
        _s('1080p WEB-DL ITA'),
        _s('720p HDCAM'),
        const AddonStream(externalUrl: 'https://x', name: 'open site'),
      ];
      final noDebrid = const StreamRanker(preferredLanguage: 'Italiano')
          .rank(list);
      expect(noDebrid.first.stream.name, '1080p WEB-DL ITA');
      expect(noDebrid.last.playability, StreamPlayability.external);
      expect(
        noDebrid.map((r) => r.playability),
        isNot(contains(StreamPlayability.unsupported)),
      );
      final withDebrid = const StreamRanker(
        preferredLanguage: 'Italiano',
        debridConfigured: true,
      ).rank(list);
      final torrentIndex = withDebrid.indexWhere((r) => r.stream.isTorrent);
      final noDebridTorrentIndex = noDebrid.indexWhere(
        (r) => r.stream.isTorrent,
      );
      expect(torrentIndex, lessThan(noDebridTorrentIndex));
    });

    test('ties keep the order of the addons', () {
      final r = const StreamRanker().rank([
        _s('1080p A'),
        _s('1080p B'),
        _s('1080p C'),
      ]);
      expect(r.map((e) => e.stream.name), ['1080p A', '1080p B', '1080p C']);
    });
  });

  group('subtitles', () {
    const srt =
        '﻿1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Ciao</i>\r\nmondo\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\n[porta che sbatte]\r\nJOHN: Ehi\r\n';

    test('parses SRT with BOM, CRLF and markup', () {
      final cues = SubtitleParser.parse(srt);
      expect(cues.length, 2);
      expect(cues.first.text, 'Ciao\nmondo');
      expect(cues.first.start, const Duration(seconds: 1));
      expect(cues.first.end, const Duration(milliseconds: 3500));
    });

    test('parses WebVTT with optional hours and ASS dialogue text', () {
      final vtt = SubtitleParser.parse(
        'WEBVTT\n\n00:01.000 --> 00:02.000\nUno\n\n00:00:03.000 --> 00:00:04.000 align:start\nDue\n',
      );
      expect(vtt.map((c) => c.text), ['Uno', 'Due']);
      final ass = SubtitleParser.parse(
        '[Script Info]\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\i1}Ciao\\Nmondo{\\i0}\n',
      );
      expect(ass.single.text, 'Ciao\nmondo');
      expect(ass.single.end, const Duration(milliseconds: 2500));
    });

    test('hearing impaired cleanup', () {
      expect(
        SubtitleParser.clean_(
          '[porta che sbatte]\nJOHN: Ehi\n♪ canzone ♪',
          removeHearingImpaired: true,
        ),
        'Ehi',
      );
    });

    test('cueAt finds the cue and applies the offset', () {
      final cues = SubtitleParser.parse(srt);
      expect(
        SubtitleParser.cueAt(cues, const Duration(seconds: 2))!.text,
        contains('Ciao'),
      );
      expect(
        SubtitleParser.cueAt(cues, const Duration(milliseconds: 3600)),
        isNull,
      );
      expect(
        SubtitleParser.cueAt(
          cues,
          const Duration(seconds: 6),
          offset: const Duration(seconds: 2),
        )!.text,
        contains('Ehi'),
      );
      expect(SubtitleParser.cueAt(cues, Duration.zero), isNull);
    });

    test(
      'loader reads utf8 and latin1, rejects errors, html and blocked hosts',
      () async {
        var body = srt;
        var status = 200;
        final loader = SubtitleLoader(
          dio: fakeDio((o) => (status: status, body: body)),
        );
        expect((await loader.load('https://s.example/a.srt')).length, 2);
        status = 404;
        await expectLater(
          loader.load('https://s.example/a.srt'),
          throwsFormatException,
        );
        status = 200;
        body = '<html>no</html>';
        await expectLater(
          loader.load('https://s.example/a.srt'),
          throwsFormatException,
        );
        await expectLater(
          loader.load('http://127.0.0.1/a.srt'),
          throwsFormatException,
        );
      },
    );
  });

  group('library', () {
    test('favorites, watchlist and progress persist; continue watching skips finished', () async {
      final store = MemoryStore();
      var lib = LibraryRepository(store);
      await lib.load();
      const film = MetaItem(
        id: 'tt1',
        type: 'movie',
        name: 'Film',
        poster: 'p',
      );
      expect(await lib.toggleFavorite(film), isTrue);
      expect(await lib.toggleWatchlist(film), isTrue);
      await lib.saveProgress(
        WatchProgress(
          metaId: 'tt1',
          videoId: 'tt1',
          type: 'movie',
          name: 'Film',
          positionMs: 600000,
          durationMs: 7200000,
          updatedAt: DateTime(2026, 1, 2),
        ),
      );
      await lib.saveProgress(
        WatchProgress(
          metaId: 'tt2',
          videoId: 'tt2',
          type: 'movie',
          name: 'Done',
          positionMs: 7000000,
          durationMs: 7200000,
          updatedAt: DateTime(2026, 1, 3),
        ),
      );
      await lib.saveProgress(
        WatchProgress(
          metaId: 'tt3',
          videoId: 'tt3:1:1',
          type: 'series',
          name: 'Serie',
          season: 1,
          episode: 1,
          positionMs: 2000,
          durationMs: 3000000,
          updatedAt: DateTime(2026, 1, 4),
        ),
      );
      lib = LibraryRepository(store);
      await lib.load();
      expect(lib.isFavorite('tt1'), isTrue);
      expect(lib.isInWatchlist('tt1'), isTrue);
      expect(lib.continueWatching.map((p) => p.metaId), [
        'tt1',
      ]); // tt2 finished, tt3 < 10 s
      expect(lib.history.first.metaId, 'tt3');
      expect(lib.isWatched('tt2'), isTrue);
      await lib.markWatched(
        'tt3',
        'tt3:1:1',
        type: 'series',
        name: 'Serie',
        season: 1,
        episode: 1,
      );
      expect(lib.isWatched('tt3:1:1'), isTrue);
      await lib.clearHistory();
      expect(lib.history, isEmpty);
    });

    test(
      'a damaged file starts empty, backup merge keeps the newest progress',
      () async {
        final store = MemoryStore()..data['library.v1'] = '{not json';
        final lib = LibraryRepository(store);
        await lib.load();
        expect(lib.history, isEmpty);
        final newer = WatchProgress(
          metaId: 'a',
          videoId: 'a',
          type: 'movie',
          name: 'a',
          positionMs: 5,
          durationMs: 10,
          updatedAt: DateTime(2026, 2, 1),
        );
        await lib.saveProgress(newer);
        await lib.importJson({
          'progress': [
            WatchProgress(
              metaId: 'a',
              videoId: 'a',
              type: 'movie',
              name: 'a',
              positionMs: 1,
              durationMs: 10,
              updatedAt: DateTime(2026, 1, 1),
            ).toJson(),
          ],
        });
        expect(lib.progressOf('a')!.positionMs, 5);
      },
    );
  });

  group('settings', () {
    test('round trip and tolerant decoding', () async {
      final store = MemoryStore();
      final repo = SettingsRepository(store);
      await repo.save(
        const AppSettings(
          amoled: true,
          subtitleScale: 1.4,
          hiddenHomeCatalogs: ['a/b'],
        ),
      );
      final loaded = await repo.load();
      expect(loaded.amoled, isTrue);
      expect(loaded.subtitleScale, 1.4);
      final bad = AppSettings.fromJson({
        'subtitleScale': 99,
        'accentHex': 'red',
        'glassIntensity': 'x',
        'subtitleOffsetMs': 1e9,
        'catalogTitles': {'a': 5, 'b': ''},
      });
      expect(bad.subtitleScale, 2.0);
      expect(bad.accentHex, '#7C8CFF');
      expect(bad.glassIntensity, 1.0);
      expect(bad.subtitleOffsetMs, 30000);
      expect(bad.catalogTitles, {'a': '5'});
      store.data[SettingsRepository.key] = 'garbage';
      expect((await repo.load()).cinematic, isTrue);
    });
  });

  group('torbox', () {
    TorBoxClient client(FakeHandler h, {String? key = 'SECRET-KEY'}) =>
        TorBoxClient(keyProvider: () async => key, dio: fakeDio(h));

    test('checkcached batches by 100, sends the key as a header and reads list/object answers', () async {
      final hashes = List.generate(
        250,
        (i) => i.toRadixString(16).padLeft(40, '0'),
      );
      final calls = <RequestOptions>[];
      final c = client((o) {
        calls.add(o);
        final sent = (jsonDecode(o.data as String) as Map)['hashes'] as List;
        return (
          status: 200,
          body: jsonEncode({
            'success': true,
            'data': [
              if (sent.contains(hashes[3])) {'hash': hashes[3].toUpperCase()},
            ],
          }),
        );
      });
      final result = await c.checkCached(hashes);
      expect(calls.length, 3);
      expect(calls.first.headers['Authorization'], 'Bearer SECRET-KEY');
      expect(calls.first.uri.toString(), isNot(contains('SECRET')));
      expect(result[hashes[3]], isTrue);
      expect(result[hashes[4]], isFalse);
      expect(result.length, 250);
    });

    test('errors map to readable failures without leaking the key', () async {
      Future<DebridException> fail(int status, String body) async {
        try {
          await client((o) => (status: status, body: body)).check();
        } on DebridException catch (e) {
          return e;
        }
        throw StateError('no error');
      }

      expect(
        (await fail(403, '{"success":false,"error":"AUTH_ERROR"}')).failure,
        DebridFailure.invalidKey,
      );
      expect((await fail(429, '')).failure, DebridFailure.rateLimited);
      expect(
        (await fail(502, '<html>bad gateway</html>')).failure,
        DebridFailure.unavailable,
      );
      expect(
        (await fail(
          200,
          '{"success":false,"error":"PLAN_RESTRICTED_FEATURE"}',
        )).failure,
        DebridFailure.planRequired,
      );
      final noKey = TorBoxClient(
        keyProvider: () async => null,
        dio: fakeDio((o) => (status: 200, body: '{}')),
      );
      await expectLater(
        noKey.check(),
        throwsA(
          isA<DebridException>().having(
            (e) => e.failure,
            'f',
            DebridFailure.notConfigured,
          ),
        ),
      );
      expect((await fail(403, '{}')).message, isNot(contains('SECRET')));
    });

    test('add only if cached: 409 means not cached; ready torrents give a https link', () async {
      var step = 0;
      final c = client((o) {
        final p = o.uri.path;
        if (p.endsWith('createtorrent'))
          return step == 0
              ? (status: 409, body: '{"success":false}')
              : (status: 200, body: '{"success":true,"data":{"torrent_id":7}}');
        if (p.endsWith('mylist')) {
          return (
            status: 200,
            body: '{"success":true,"data":{"id":7,"hash":"AB","name":"n","download_finished":true,"download_present":true,"files":[{"id":0,"name":"a/small.nfo","size":10},{"id":1,"name":"a/movie.mkv","size":900},{"id":2,"name":"a/sample.mkv","size":5}]}}',
          );
        }
        return (
          status: 200,
          body: '{"success":true,"data":"https://cdn.example/dl/xyz"}',
        );
      });
      await expectLater(
        c.addMagnet('magnet:?xt=urn:btih:ab'),
        throwsA(
          isA<DebridException>().having(
            (e) => e.failure,
            'f',
            DebridFailure.notCached,
          ),
        ),
      );
      step = 1;
      expect(await c.addMagnet('magnet:?xt=urn:btih:ab'), 7);
      final t = (await c.torrent(7))!;
      expect(t.ready, isTrue);
      expect(TorBoxClient.chooseFile(t.files)!.name, 'a/movie.mkv');
      expect(TorBoxClient.chooseFile(t.files, episodeHint: 'sample')!.id, 2);
      expect((await c.requestLink(7, 1)).host, 'cdn.example');
    });

    test('requestdl refuses non-https links', () async {
      final c = client(
        (o) => (
          status: 200,
          body: '{"success":true,"data":"http://cdn.example/x"}',
        ),
      );
      await expectLater(c.requestLink(1, 1), throwsA(isA<DebridException>()));
    });

    test(
      'episodeHint formats S01E02',
      () => expect(TorBoxClient.episodeHint(1, 2), 'S01E02'),
    );
  });

  group('tmdb', () {
    test('details parse cast, trailers, companies; v4 tokens use a bearer header; keys never in the log', () async {
      final seen = <RequestOptions>[];
      final c = TmdbClient(
        keyProvider: () async => 'eyJtoken',
        dio: fakeDio((o) {
          seen.add(o);
          if (o.uri.path.contains('/find/'))
            return (status: 200, body: '{"movie_results":[{"id":603}]}');
          return (
            status: 200,
            body: jsonEncode({
              'overview': 'o',
              'budget': 5,
              'belongs_to_collection': {'name': 'Saga'},
              'credits': {
                'cast': [
                  {
                    'id': 1,
                    'name': 'Attore',
                    'character': 'Ruolo',
                    'profile_path': '/p.jpg',
                  },
                ],
              },
              'videos': {
                'results': [
                  {'site': 'YouTube', 'type': 'Trailer', 'key': 'abc'},
                  {'site': 'Vimeo', 'type': 'Trailer', 'key': 'no'},
                ],
              },
              'production_companies': [
                {'name': 'Studio'},
              ],
            }),
          );
        }),
      );
      final d = (await c.details('tt0133093'))!;
      expect(d.cast.single.photo, 'https://image.tmdb.org/t/p/w185/p.jpg');
      expect(d.trailers, ['abc']);
      expect(d.companies, ['Studio']);
      expect(d.collectionName, 'Saga');
      expect(seen.first.headers['Authorization'], 'Bearer eyJtoken');
      expect(seen.first.uri.queryParameters.containsKey('api_key'), isFalse);
    });

    test(
      'filmography is sorted by popularity; no key means nothing is requested',
      () async {
        final c = TmdbClient(
          keyProvider: () async => 'k123',
          dio: fakeDio(
            (o) => (
              status: 200,
              body: jsonEncode({
                'cast': [
                  {
                    'id': 1,
                    'media_type': 'movie',
                    'title': 'B',
                    'character': 'x',
                    'release_date': '2001-02-03',
                    'popularity': 1,
                  },
                  {
                    'id': 2,
                    'media_type': 'tv',
                    'name': 'A',
                    'first_air_date': '2010-01-01',
                    'popularity': 9,
                  },
                ],
              }),
            ),
          ),
        );
        final f = await c.filmography(5);
        expect(f.map((e) => e.title), ['A', 'B']);
        expect(f.last.year, '2001');
        final none = TmdbClient(
          keyProvider: () async => null,
          dio: fakeDio((o) => throw StateError('must not be called')),
        );
        expect(await none.details('tt1'), isNull);
      },
    );
  });

  test('the log redacts keys, bearer tokens, credentials and addon paths', () {
    final redacted = AppLog.redact(
      'GET https://api.x/y?api_key=ABC123&token=ZZZ Bearer abc.def https://u:pw@h.example/a https://addon.example/CONFIG123/manifest.json',
    );
    expect(redacted, isNot(contains('ABC123')));
    expect(redacted, isNot(contains('ZZZ')));
    expect(redacted, isNot(contains('abc.def')));
    expect(redacted, isNot(contains('pw@')));
    expect(redacted, isNot(contains('CONFIG123')));
  });
}
