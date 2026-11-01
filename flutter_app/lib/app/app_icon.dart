import 'dart:io';

import 'package:flutter/services.dart';

/// Gli stili dell'icona dell'app (solo Android): ognuno è un alias dell'attività principale nel manifest.
class AppIconStyle {
  const AppIconStyle(this.id, this.label, this.asset);
  final String id;
  final String label;
  final String asset;
}

const kAppIconStyles = [
  AppIconStyle('Default', 'Predefinita', 'assets/app_icons/default.png'),
  AppIconStyle('Light', 'Chiara', 'assets/app_icons/light.png'),
  AppIconStyle('Dark', 'Scura', 'assets/app_icons/dark.png'),
  AppIconStyle('Cinema', 'Cinema', 'assets/app_icons/cinema.png'),
  AppIconStyle('Halloween', 'Halloween', 'assets/app_icons/halloween.png'),
  AppIconStyle('Natale', 'Natalizio', 'assets/app_icons/natale.png'),
  AppIconStyle('Western', 'Western', 'assets/app_icons/western.png'),
  AppIconStyle('SciFi', 'Fantascienza', 'assets/app_icons/scifi.png'),
  AppIconStyle('Giallo', 'Giallo poliziesco', 'assets/app_icons/giallo.png'),
];

class AppIconService {
  static const _channel = MethodChannel('app.aether/icon');

  static bool get supported => Platform.isAndroid;

  static Future<String> current() async {
    if (!supported) return 'Default';
    try {
      return await _channel.invokeMethod<String>('get') ?? 'Default';
    } on PlatformException {
      return 'Default';
    }
  }

  static Future<bool> set(String id) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('set', {'style': id}) ?? false;
    } on PlatformException {
      return false;
    }
  }
}
