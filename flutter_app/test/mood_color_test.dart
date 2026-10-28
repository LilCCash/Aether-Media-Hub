import 'dart:typed_data';

import 'package:aether_flutter/core/util/mood_color.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a red picture gives a reddish, readable glow; transparent pixels are ignored; empty gives the accent', () {
    final red = Uint8List.fromList([
      for (var i = 0; i < 16; i++) ...[220, 20, 30, 255],
    ]);
    final c = moodColorFromRgba(red);
    final hsv = HSVColor.fromColor(c);
    expect(hsv.hue < 20 || hsv.hue > 340, isTrue);
    expect(hsv.value, inInclusiveRange(0.45, 0.86));
    final mixed = Uint8List.fromList([0, 0, 255, 0, ...red]);
    expect(
      HSVColor.fromColor(moodColorFromRgba(mixed)).hue < 20 ||
          HSVColor.fromColor(moodColorFromRgba(mixed)).hue > 340,
      isTrue,
    );
    expect(moodColorFromRgba(Uint8List(0)), const Color(0xFF7C8CFF));
  });
}
