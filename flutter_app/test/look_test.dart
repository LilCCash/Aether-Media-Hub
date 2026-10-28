import 'dart:convert';

import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/design/palettes.dart';
import 'package:aether_flutter/features/home/home_screen.dart' show greeting;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('palettes: Aether keeps the chosen accent, the others bring two washes; unknown names fall back', () {
    expect(AetherPalette.aether.primary, isNull);
    expect(AetherPalette.ocean.primary, isNotNull);
    expect(AetherPalette.ocean.secondary, isNotNull);
    expect(AetherPalette.byName('nope'), AetherPalette.aether);
    expect(TitleFont.byName('serif').family, 'serif');
    expect(TitleFont.byName(null), TitleFont.standard);
  });

  test('look settings survive a round trip and damaged values fall back', () {
    final s = const AppSettings().copyWith(
      palette: 'sunset',
      titleFont: 'mono',
      greetingName: 'Giulia',
      debridProvider: 'realdebrid',
      skipIntro: false,
    );
    final back = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())));
    expect(back.palette, 'sunset');
    expect(back.titleFont, 'mono');
    expect(back.greetingName, 'Giulia');
    expect(back.debridProvider, 'realdebrid');
    expect(back.skipIntro, isFalse);
    final bad = AppSettings.fromJson({
      'palette': 'x',
      'titleFont': 5,
      'greetingName': '  ',
      'debridProvider': 'zzz',
    });
    expect(bad.palette, 'aether');
    expect(bad.titleFont, 'standard');
    expect(bad.greetingName, isNull);
    expect(bad.debridProvider, 'torbox');
    expect(back.copyWith(greetingName: null).greetingName, isNull);
    expect(
      AppSettings.fromJson({'greetingName': 'x' * 80}).greetingName!.length,
      24,
    );
  });

  test('the greeting follows the hour', () {
    expect(greeting(DateTime(2026, 1, 1, 8)), 'Buongiorno');
    expect(greeting(DateTime(2026, 1, 1, 15)), 'Buon pomeriggio');
    expect(greeting(DateTime(2026, 1, 1, 20)), 'Buonasera');
    expect(greeting(DateTime(2026, 1, 1, 2)), 'Buonanotte');
  });
}
