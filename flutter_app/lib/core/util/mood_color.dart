import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/painting.dart';

/// The colour a picture "feels" like, used to tint the page behind a title (Dynamic Cinematic). Averages the opaque pixels of a
/// tiny RGBA thumbnail, then keeps the hue and lifts saturation / limits brightness so a glow over dark ink always reads well.
Color moodColorFromRgba(Uint8List rgba) {
  var r = 0.0, g = 0.0, b = 0.0, n = 0.0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final a = rgba[i + 3] / 255;
    if (a < 0.5) continue;
    r += rgba[i];
    g += rgba[i + 1];
    b += rgba[i + 2];
    n++;
  }
  if (n == 0) return const Color(0xFF7C8CFF);
  final hsv = HSVColor.fromColor(Color.fromARGB(255, (r / n).round(), (g / n).round(), (b / n).round()));
  return hsv.withSaturation((hsv.saturation * 1.15 + 0.1).clamp(0.35, 0.95)).withValue(hsv.value.clamp(0.45, 0.85)).toColor();
}
