import 'dart:io';

import 'package:flutter/services.dart';

/// Opens the system AirPlay list. It is a normal Flutter button that asks the native side to press the system picker (kept out of
/// sight): a second native view in the controls broke the drawing of everything painted after it, over the video.
class AirPlayPicker {
  static const _ch = MethodChannel('aether/airplaypicker');

  static Future<void> show() async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod<void>('show');
    } on Object {
      // no picker on this device
    }
  }
}
