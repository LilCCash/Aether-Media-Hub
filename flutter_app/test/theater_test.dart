import 'dart:convert';
import 'dart:typed_data';

import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/features/theater/theater_prefs.dart';
import 'package:aether_flutter/features/theater/theater_sound.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Theater preferences: defaults, round trip inside the settings, out-of-range values fall back', () {
    const d = TheaterPrefs();
    expect(d.intro, isTrue);
    expect(d.accent, TheaterPalette.gold);
    final s = const AppSettings().copyWith(
      theater: d.copyWith(
        palette: 3,
        cardSize: 2,
        portraitCards: true,
        sound: false,
      ),
    );
    final back = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())))
        .theater;
    expect(back.accent, TheaterPalette.emerald);
    expect(back.cardSize, 2);
    expect(back.portraitCards, isTrue);
    expect(back.sound, isFalse);
    final bad = TheaterPrefs.fromJson({
      'palette': 99,
      'background': -1,
      'cardSize': 'x',
    });
    expect(bad.palette, 0);
    expect(bad.background, 1);
    expect(bad.cardSize, 1);
    expect(TheaterPrefs.fromJson(null).intro, isTrue);
  });

  test('card geometry follows size and shape', () {
    const small = TheaterPrefs(cardSize: 0);
    const large = TheaterPrefs(cardSize: 2, portraitCards: true);
    expect(small.rowHeight, lessThan(const TheaterPrefs().rowHeight));
    expect(large.cardWidth, lessThan(large.rowHeight));
    expect(small.cardWidth, greaterThan(small.rowHeight));
  });

  test('the entrance sound is a valid 16-bit mono WAV, audible, never clipped past full scale', () {
    final wav = TheaterSound.wave(seconds: 1, hit: 0.4);
    final b = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 16)), 'WAVEfmt ');
    expect(b.getUint16(20, Endian.little), 1); // PCM
    expect(b.getUint16(22, Endian.little), 1); // mono
    expect(b.getUint32(24, Endian.little), 44100);
    expect(b.getUint32(40, Endian.little), 44100 * 2);
    expect(wav.length, 44 + 44100 * 2);
    var peak = 0;
    for (var i = 44; i < wav.length; i += 2) {
      peak = peak < b.getInt16(i, Endian.little).abs()
          ? b.getInt16(i, Endian.little).abs()
          : peak;
    }
    expect(peak, greaterThan(1000));
    expect(peak, lessThanOrEqualTo(32767));
  });
}
