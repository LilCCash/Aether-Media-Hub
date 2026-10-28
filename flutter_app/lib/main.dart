import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'app/services.dart';
import 'features/player/media_kit_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKitEngine.ensureInitialised();
  // The app lives in portrait; only the player and Theater Mode turn the screen sideways (and give it back when they close).
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  final services = await AppServices.create();
  runApp(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: const AetherApp(),
    ),
  );
}
