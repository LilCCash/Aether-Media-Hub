import 'dart:io';

import 'package:flutter/services.dart';

/// What the phone can do, read once at start-up. «Weak» devices (little RAM, few cores, old Android) get the efficient mode
/// when «Prestazioni» is on Automatico: same screens and features, with the costly effects (backdrop blur, glass refraction
/// shaders, big soft shadows) swapped for flat surfaces and smaller caches.
class DeviceProfile {
  const DeviceProfile({
    this.lowRam = false,
    this.memoryClass = 256,
    this.totalMb = 4096,
    this.cores = 8,
    this.sdk = 34,
  });

  final bool lowRam;
  final int memoryClass;
  final int totalMb;
  final int cores;
  final int sdk;

  static const _channel = MethodChannel('app.aether/device');
  static DeviceProfile _current = const DeviceProfile();
  static DeviceProfile get current => _current;

  /// Test hook.
  static void override(DeviceProfile p) => _current = p;

  /// True for a phone that should run in the efficient mode by itself.
  bool get weak =>
      lowRam || totalMb < 4000 || cores <= 4 || sdk < 28 || memoryClass < 192;

  /// Very weak: even the efficient mode trims more (smaller picture cache, smaller playback buffer).
  bool get veryWeak => lowRam || totalMb < 2600 || sdk < 26;

  static Future<DeviceProfile> load() async {
    if (!Platform.isAndroid) return _current;
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('info');
      if (m != null) {
        int i(String k, int d) => (m[k] is num) ? (m[k]! as num).toInt() : d;
        _current = DeviceProfile(
          lowRam: m['lowRam'] == true,
          memoryClass: i('memoryClass', 256),
          totalMb: i('totalMb', 4096),
          cores: i('cores', 8),
          sdk: i('sdk', 34),
        );
      }
    } on Object {
      // keep the optimistic default
    }
    return _current;
  }
}
