import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'media_kit_engine.dart';

/// The light riser of the start screen: air (noise whose brightness opens up) and a thin rising tone that swell together and let
/// go in a soft tail, about 1.7 seconds. Made here, sample by sample: nothing is taken from a film or a song.
class IntroSound {
  IntroSound._();
  static final IntroSound instance = IntroSound._();

  Player? _player;
  static File? _file;

  /// 16-bit mono WAV at 22.05 kHz.
  static Uint8List wav() {
    const rate = 22050;
    const seconds = 1.7;
    const rise = 1.35;
    final count = (rate * seconds).round();
    final data = Int16List(count);
    var seed = 0x2F6E2B1;
    var low = 0.0;
    var phase = 0.0;
    for (var i = 0; i < count; i++) {
      final t = i / rate;
      seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
      final noise = ((seed & 0xFFFF) / 32768.0) - 1.0;
      final progress = math.min(1.0, t / rise);
      final cutoff = 400 + 6600 * progress * progress;
      final k = 1 - math.exp(-2 * math.pi * cutoff / rate);
      low += k * (noise - low);
      final freq = 380 + 900 * progress * progress;
      phase += 2 * math.pi * freq / rate;
      final swell = progress * progress;
      final tail = t <= rise
          ? 1.0
          : math.max(0.0, 1 - (t - rise) / (seconds - rise));
      final fadeIn = math.min(1.0, t / 0.05);
      final v = (low * 0.55 + math.sin(phase) * 0.22) * swell * tail * fadeIn;
      data[i] = (v.clamp(-1.0, 1.0) * 32000).round();
    }
    final bytes = BytesBuilder();
    void u32(int v) =>
        bytes.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
    void u16(int v) => bytes.add([v & 255, (v >> 8) & 255]);
    final size = count * 2;
    bytes.add('RIFF'.codeUnits);
    u32(36 + size);
    bytes.add('WAVEfmt '.codeUnits);
    u32(16);
    u16(1);
    u16(1);
    u32(rate);
    u32(rate * 2);
    u16(2);
    u16(16);
    bytes.add('data'.codeUnits);
    u32(size);
    bytes.add(data.buffer.asUint8List());
    return bytes.toBytes();
  }

  Future<void> play() async {
    try {
      await stop();
      MediaKitEngine.ensureInitialised();
      var file = _file;
      if (file == null || !file.existsSync()) {
        final dir = await getTemporaryDirectory();
        file = File('${dir.path}/aether_riser.wav');
        await file.writeAsBytes(wav(), flush: true);
        _file = file;
      }
      final player = Player();
      _player = player;
      await player.setVolume(70);
      await player.open(Media(file.path));
    } on Object {
      // no sound where the player cannot start: the screen works the same
    }
  }

  Future<void> stop() async {
    final p = _player;
    _player = null;
    if (p != null) {
      try {
        await p.dispose();
      } on Object {
        // already gone
      }
    }
  }
}
