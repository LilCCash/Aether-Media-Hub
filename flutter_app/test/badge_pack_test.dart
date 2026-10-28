import 'dart:convert';

import 'package:aether_flutter/core/addons/network_policy.dart';
import 'package:aether_flutter/core/model/stream.dart';
import 'package:aether_flutter/core/streams/badge_pack.dart';
import 'package:aether_flutter/core/streams/badge_pack_loader.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

void main() {
  const fusion = '''
{"filters":[
 {"name":"Remux","pattern":"remux","imageURL":"https://img.example/remux.png","tagColor":"#33FF9500","borderColor":"FF9500","textColor":"#FFAA00","isEnabled":true},
 {"name":"HDR","pattern":"\\\\b(hdr10\\\\+?|dolby\\\\s?vision)\\\\b","tagColor":"2040A0"},
 {"name":"Off","pattern":"x","isEnabled":false},
 {"name":"Bad image","pattern":"zzzz","imageURL":"http://insecure.example/a.png"},
 {"pattern":"no label"},
 {"name":"Broken regex","pattern":"([a-"},
 "junk"
]}''';

  test('the Fusion/Nuvio format: patterns, colours with alpha, https pictures only, disabled and incomplete entries skipped', () {
    final rules = CustomBadgePack.parse(fusion);
    expect(rules.map((r) => r.label), ['Remux', 'HDR', 'Bad image', 'Broken regex']);
    final remux = rules.first;
    expect(remux.imageUrl, 'https://img.example/remux.png');
    expect(remux.fillHex, '#FF9500');
    expect(remux.fillAlpha, closeTo(0x33 / 255, 0.001));
    expect(remux.borderHex, '#FF9500');
    expect(remux.colorHex, '#FFAA00');
    expect(rules[2].imageUrl, isNull);
  });

  test('matching: words are case-insensitive, patterns are regular expressions, a broken one never matches or throws', () {
    final rules = CustomBadgePack.parse(fusion);
    const s = AddonStream(
      name: 'Torrentio 4K',
      description: 'Movie.2160p.BluRay.REMUX.Dolby Vision',
    );
    final got = CustomBadgePack.badgesFor(s, rules).map((r) => r.label);
    expect(got, ['Remux', 'HDR']);
    expect(
      CustomBadgePack.badgesFor(const AddonStream(name: 'plain'), rules),
      isEmpty,
    );
  });

  test('the simple list and the wrapped forms are understood; garbage and oversized input give nothing', () {
    expect(
      CustomBadgePack.parse('[{"label":"Remux","match":["remux","bdremux"],"color":"#FF9500"}]')
          .single
          .match,
      ['remux', 'bdremux'],
    );
    expect(
      CustomBadgePack.parse('{"badges":[{"label":"A","keywords":"x"}]}').length,
      1,
    );
    expect(CustomBadgePack.parse('not json'), isEmpty);
    expect(CustomBadgePack.parse('x' * (CustomBadgePack.maxBytes + 1)), isEmpty);
  });

  test('imported rules survive a settings round trip', () {
    final rules = CustomBadgePack.parse(fusion);
    final s = const AppSettings().copyWith(
      customBadges: rules,
      customBadgesUrl: 'https://x.example/b.json',
    );
    final back = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())));
    expect(back.customBadges.length, rules.length);
    expect(back.customBadges.first.imageUrl, rules.first.imageUrl);
    expect(back.customBadgesUrl, 'https://x.example/b.json');
    expect(back.copyWith(customBadgesUrl: null).customBadgesUrl, isNull);
  });

  test('the loader refuses http, local addresses and files without badges, and reads a good one', () async {
    var asked = 0;
    final loader = BadgePackLoader(
      policy: const NetworkPolicy(),
      dio: fakeDio((o) {
        asked++;
        return o.uri.path.endsWith('empty.json')
            ? (status: 200, body: '[]')
            : (status: 200, body: fusion);
      }),
    );
    for (final bad in [
      'http://x.example/a.json',
      'https://localhost/a.json',
      'https://127.0.0.1/a.json',
      'https://user:pw@x.example/a.json',
      'ftp://x.example/a',
    ]) {
      await expectLater(loader.load(bad), throwsFormatException);
    }
    expect(asked, 0);
    await expectLater(
      loader.load('https://x.example/empty.json'),
      throwsFormatException,
    );
    expect((await loader.load('https://x.example/b.json')).length, 4);
  });
}
