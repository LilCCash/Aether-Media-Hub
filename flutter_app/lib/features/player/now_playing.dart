import 'dart:io';

import 'package:flutter/services.dart';

/// The lock screen and Control Center on iPhone: the title, the position and the play / pause / skip buttons (the same as the
/// iOS app's «Now Playing» and remote commands). Other platforms: nothing happens.
class NowPlaying {
  NowPlaying._();
  static const _channel = MethodChannel('aether/nowplaying');
  static void Function(String name, Map<String, Object?> args)? _onCommand;
  static bool _wired = false;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'command') {
        final m = Map<String, Object?>.from(call.arguments as Map);
        _onCommand?.call(m['name']! as String, m);
      }
    });
  }

  static void listen(void Function(String name, Map<String, Object?> args)? h) {
    if (!Platform.isIOS) return;
    _wire();
    _onCommand = h;
  }

  static Future<void> update({
    required String title,
    String? subtitle,
    String? artwork,
    required double durationSec,
    required double positionSec,
    required double rate,
    required bool playing,
    bool hasPrevious = false,
    bool hasNext = false,
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('update', {
        'title': title,
        'subtitle': subtitle,
        'artwork': artwork,
        'duration': durationSec,
        'position': positionSec,
        'rate': rate,
        'playing': playing,
        'hasPrevious': hasPrevious,
        'hasNext': hasNext,
      });
    } on Object {
      // no lock-screen controls on this device
    }
  }

  static Future<void> clear() async {
    if (!Platform.isIOS) return;
    // The handler stays: the next episode's screen has already replaced it (a closed screen ignores the calls).
    try {
      await _channel.invokeMethod<void>('clear');
    } on Object {
      // nothing to clear
    }
  }
}
