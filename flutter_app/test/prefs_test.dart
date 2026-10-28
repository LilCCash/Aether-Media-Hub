import 'dart:convert';

import 'package:aether_flutter/core/model/stream.dart';
import 'package:aether_flutter/core/streams/stream_analyzer.dart';
import 'package:aether_flutter/data/prefs_ext.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('options in ext: defaults, validation, and a round trip through JSON', () {
    const d = AppSettings();
    expect(d.streamOrdering, 'byAddon');
    expect(d.modCast && d.modTrailers && d.tmdbEnabled, isTrue);
    expect(d.ratingSources, contains('imdb'));
    final s = d
        .withExt('skipBackSec', 999)
        .withExt('subColor', 'not-a-colour')
        .withExt('cardChrome', 'neon')
        .withExt('ratingSources', ['imdb', 'trakt'])
        .withExt('hiddenBadges', ['audio'])
        .withExt('modCast', false);
    expect(s.skipBackSec, 60);
    expect(s.subColor, '#FFFFFF');
    expect(s.cardChrome, 'standard');
    final back = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())));
    expect(back.ratingSources, ['imdb', 'trakt']);
    expect(back.hiddenBadges, ['audio']);
    expect(back.modCast, isFalse);
    expect(back.withExt('modCast', null).modCast, isTrue);
    // a damaged ext never breaks loading
    expect(AppSettings.fromJson({'ext': 'junk'}).ext, isEmpty);
    expect(AppSettings.fromJson({'ext': {'a': {'b': 1}, 'ok': true}}).ext, {'ok': true});
  });

  test('Home sections: order and visibility are kept, unknown ones dropped, missing ones appended', () {
    final s = const AppSettings().withExt('homeSections', ['catalogs:1', 'bogus:1', 'hero:0']);
    expect(s.homeSections.map((e) => '${e.id}:${e.visible}'), [
      'catalogs:true',
      'hero:false',
      'continue:true',
      'nextUp:true',
      'watchlist:true',
    ]);
    final moved = s.withHomeSections(s.homeSections.reversed.toList());
    expect(moved.homeSections.first.id, 'watchlist');
    expect(moved.withExt('homeSections', null).homeSections.first.id, 'hero');
  });

  test('source order: by addon follows the addon list, then quality inside each; by quality mixes them', () {
    const a = AddonStream(url: 'https://a/1.mkv', name: 'Show 720p', addonId: 'A');
    const b = AddonStream(url: 'https://b/1.mkv', name: 'Show 2160p', addonId: 'B');
    const a2 = AddonStream(url: 'https://a/2.mkv', name: 'Show 1080p', addonId: 'A');
    final byAddon = const StreamRanker(addonOrder: ['A', 'B']).rank([a, b, a2]);
    expect(byAddon.map((r) => r.stream.addonId), ['A', 'A', 'B']);
    expect(byAddon.first.stream.name, 'Show 1080p'); // best of addon A first
    final flipped = const StreamRanker(addonOrder: ['B', 'A']).rank([a, b, a2]);
    expect(flipped.first.stream.addonId, 'B');
    final mixed = const StreamRanker().rank([a, b, a2]);
    expect(mixed.first.stream.name, 'Show 2160p');
  });

  test('the quality limit pushes bigger sources down without hiding them', () {
    const hi = AddonStream(url: 'https://a/1.mkv', name: 'Show 2160p');
    const lo = AddonStream(url: 'https://a/2.mkv', name: 'Show 1080p');
    final r = const StreamRanker(maxHeight: 1080).rank([hi, lo]);
    expect(r.first.stream.name, 'Show 1080p');
    expect(r.length, 2);
  });
}
