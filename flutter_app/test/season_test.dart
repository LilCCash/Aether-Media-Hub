import 'package:aether_flutter/core/model/stream.dart';
import 'package:aether_flutter/core/streams/stream_analyzer.dart';
import 'package:aether_flutter/data/prefs_ext.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/features/downloads/season_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

AddonStream s(String name, {String? addon, int? size}) => AddonStream(
  url: 'https://cdn/$name.mkv',
  name: name,
  addonId: addon,
  videoSize: size,
);

void main() {
  final ranker = const StreamRanker();
  final all = ranker.rank([
    s('Show.S01E01.2160p.ITA.WEB-DL', size: 9000000000),
    s('Show.S01E01.1080p.ITA.WEB-DL', size: 3000000000),
    s('Show.S01E01.1080p.ENG.WEB-DL', size: 1500000000),
    s('Show.S01E01.720p.ITA.WEB-DL', size: 900000000),
    AddonStream(infoHash: 'a' * 40, name: 'Show.S01E01.1080p.ITA'),
  ]);

  test('the season policy: language pool, strict quality cap, lighter first, torrents only with debrid', () {
    final c = seasonCandidates(
      all,
      debrid: false,
      capHeight: 1080,
      preferSmaller: true,
      language: 'Italiano',
    );
    expect(c.map((e) => e.stream.name), [
      'Show.S01E01.720p.ITA.WEB-DL',
      'Show.S01E01.1080p.ITA.WEB-DL',
    ]); // 4K is above the cap, English is outside the language pool, the torrent needs debrid
    final withDebrid = seasonCandidates(
      all,
      debrid: true,
      capHeight: 1080,
      preferSmaller: true,
      language: 'Italiano',
    );
    expect(withDebrid.any((e) => e.stream.isTorrent), isTrue);
  });

  test('a wanted language is kept strictly; best score when weight does not matter', () {
    final c = seasonCandidates(
      all,
      debrid: false,
      capHeight: 0,
      preferSmaller: false,
      language: 'Francese',
    );
    expect(c, isEmpty); // nothing in French: the episode is left out
    final it = seasonCandidates(
      all,
      debrid: false,
      capHeight: 0,
      preferSmaller: false,
      language: 'Italiano',
    );
    expect(it.every((e) => e.info.languages.contains('Italiano')), isTrue);
    expect(it.first.stream.name, 'Show.S01E01.2160p.ITA.WEB-DL');
    final consistent = seasonCandidates(
      all,
      debrid: false,
      capHeight: 0,
      preferSmaller: false,
      targetHeight: 1080,
    );
    expect(
      consistent.every(
        (e) => (e.info.quality.index) <= VideoQuality.p1080.index,
      ),
      isTrue,
    );
    expect(
      seasonCandidates(all, debrid: false, capHeight: 480, preferSmaller: true),
      isEmpty,
    );
  });

  test('summary wording and the season options with their defaults', () {
    expect(
      const SeasonDownloadSummary(
        queued: 8,
        alreadyPresent: 1,
        skipped: 2,
      ).message,
      'Download stagione: 8 episodi accodati, 1 già presenti, 2 non disponibili o non compatibili.',
    );
    expect(
      const SeasonDownloadSummary(empty: true).message,
      contains('già disponibili'),
    );
    const d = AppSettings();
    expect(d.seasonQuality, 0);
    expect(d.seasonLanguage, 'preferred');
    expect(d.seasonSizePolicy, 'preferSmaller');
    final e = d
        .withExt('seasonQuality', 4000)
        .withExt('seasonSizePolicy', 'zzz');
    expect(e.seasonQuality, 0); // out of the allowed set → default
    expect(e.seasonSizePolicy, 'preferSmaller');
    expect(d.withExt('maxDownloads', 99).maxDownloads, 5);
  });
}
