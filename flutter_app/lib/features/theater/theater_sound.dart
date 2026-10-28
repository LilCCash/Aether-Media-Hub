import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

import '../../core/util/app_log.dart';

typedef WavPlayer = Future<void> Function(Uint8List wav);

/// The opening sound of Theater Mode, made from maths so no audio file is needed: a riser that climbs for about three and a
/// half seconds, then a low gong with a shimmer. It is a sound effect, never music from anyone else.
class TheaterSound {
  TheaterSound._();

  /// Tests replace the player; the default plays the WAV through libmpv.
  static WavPlayer? override;

  static Future<void> playIntro() async {
    try {
      final wav = await Isolate.run(() => wave());
      final play = override;
      if (play != null) {
        await play(wav);
        return;
      }
      final file = File(
        '${Directory.systemTemp.path}/aether_theater_intro.wav',
      );
      await file.writeAsBytes(wav, flush: true);
      final player = Player();
      await player.setVolume(80);
      await player.open(Media(file.path));
      Future<void>.delayed(const Duration(seconds: 9), player.dispose);
    } on Object catch (e) {
      AppLog.instance.add('theater', 'Suono d’ingresso non disponibile: $e');
    }
  }

  /// 16-bit mono PCM WAV, 44.1 kHz.
  static Uint8List wave({double seconds = 8, double hit = 3.4}) {
    const rate = 44100.0;
    final count = (rate * seconds).round();
    final pcm = Int16List(count);
    var phase = 0.0;
    var seed = 12345;
    double noise() {
      seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
      return (seed >> 8) / (1 << 24) * 2 - 1;
    }

    const partials = [
      (1.0, 1.0, 0.42),
      (1.51, 0.7, 0.55),
      (2.0, 0.5, 0.8),
      (2.74, 0.36, 1.1),
      (3.7, 0.24, 1.6),
      (5.2, 0.12, 2.4),
    ];
    for (var i = 0; i < count; i++) {
      final t = i / rate;
      var v = 0.0;
      if (t < hit) {
        final p = t / hit;
        final frequency = 70 * math.pow(14, p);
        phase += 2 * math.pi * frequency / rate;
        final envelope = p * p;
        v += (math.sin(phase) * 0.5 + math.sin(phase * 1.5) * 0.2) * envelope;
        v += noise() * 0.18 * envelope * envelope;
      } else {
        final tau = t - hit;
        final bloom = 1 - math.exp(-tau * 7);
        const base = 56.0;
        for (final (ratio, level, decay) in partials) {
          final shape = ratio < 1.2 ? 1.0 : bloom;
          v +=
              math.sin(2 * math.pi * base * ratio * tau) *
              math.exp(-tau * decay) *
              level *
              shape *
              0.55;
        }
        v +=
            math.sin(2 * math.pi * (base + 1.7) * tau) *
            math.exp(-tau * 0.5) *
            0.35;
        v +=
            math.sin(2 * math.pi * (70 - 22 * math.min(1, tau / 0.4)) * tau) *
            math.exp(-tau * 6) *
            0.8;
        v += noise() * math.exp(-tau * 16) * 0.22;
      }
      final fade = t > seconds - 1.0 ? math.max(0, seconds - t) : 1.0;
      final soft = _tanh(v * 0.45) * 0.9 * fade;
      pcm[i] = (soft * 32767).round().clamp(-32768, 32767);
    }
    final bytes = pcm.length * 2;
    final out = ByteData(44 + bytes);
    void tag(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        out.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    out.setUint32(4, 36 + bytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little);
    out.setUint16(22, 1, Endian.little);
    out.setUint32(24, rate.round(), Endian.little);
    out.setUint32(28, rate.round() * 2, Endian.little);
    out.setUint16(32, 2, Endian.little);
    out.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    out.setUint32(40, bytes, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      out.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  static double _tanh(double x) {
    if (x > 20) return 1;
    if (x < -20) return -1;
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }
}
