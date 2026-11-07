import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'app/services.dart';
import 'core/util/device_profile.dart';
import 'data/prefs_ext.dart';
import 'design/liquid.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The app lives in portrait; only the player and Theater Mode turn the screen sideways (and give it back when they close).
  // What the phone can do is read in parallel with the settings, so the first frame already knows the right level of effects.
  final profile = DeviceProfile.load();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  final services = await AppServices.create();
  final device = await profile;
  // Decoded pictures live in RAM: a weak phone keeps fewer of them (the disk cache is unchanged).
  final cache = PaintingBinding.instance.imageCache;
  if (device.veryWeak) {
    cache.maximumSize = 120;
    cache.maximumSizeBytes = 48 << 20;
  } else if (device.weak) {
    cache.maximumSize = 200;
    cache.maximumSizeBytes = 80 << 20;
  }
  runApp(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: const AetherApp(),
    ),
  );
  // The glass shaders are only needed by the first screen that uses them: loaded after the first frame, and not at all where
  // the efficient mode will not draw them.
  final s = services.initialSettings;
  final efficient =
      s.performanceMode == 'saver' ||
      (s.performanceMode == 'auto' && device.weak);
  if (s.liquidGlass && !efficient) {
    WidgetsBinding.instance.addPostFrameCallback((_) => precacheLiquid());
  }
}
