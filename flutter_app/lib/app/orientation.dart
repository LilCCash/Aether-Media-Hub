import 'package:flutter/services.dart';

/// The orientation and system-bar mode the current screen wants, so a screen opened on top (the player) can give them back
/// exactly when it closes: the Theater Mode stays landscape and immersive after the player, the rest stays portrait.
class AppOrientation {
  AppOrientation._();

  static const portrait = [DeviceOrientation.portraitUp];
  static const landscape = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  static List<DeviceOrientation> _base = portrait;
  static SystemUiMode _ui = SystemUiMode.edgeToEdge;

  static Future<void> setBase(
    List<DeviceOrientation> orientations, {
    SystemUiMode ui = SystemUiMode.edgeToEdge,
  }) {
    _base = orientations;
    _ui = ui;
    return restore();
  }

  /// A screen on top (the player) turns sideways WITHOUT changing what the screen underneath wants.
  static Future<void> enterLandscape() async {
    await SystemChrome.setPreferredOrientations(landscape);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// Back to what the screen underneath wants. iOS only rotates back when asked again after the first change has settled.
  static Future<void> restore() async {
    await SystemChrome.setPreferredOrientations(_base);
    await SystemChrome.setEnabledSystemUIMode(_ui);
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      SystemChrome.setPreferredOrientations(_base);
    });
  }
}
