import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/util/mood_color.dart';
import 'providers.dart';

/// The colour of a title's artwork (null when there is no picture, no network or the picture cannot be read).
final moodColorProvider = FutureProvider.autoDispose.family<Color?, String?>((
  ref,
  url,
) async {
  if (url == null || url.isEmpty) return null;
  if (!ref.watch(settingsProvider.select((s) => s.cinematic))) return null;
  try {
    final response = await Dio().get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
      ),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      return null;
    }
    final codec = await ui.instantiateImageCodec(
      Uint8List.fromList(bytes),
      targetWidth: 12,
      targetHeight: 12,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    frame.image.dispose();
    return data == null ? null : moodColorFromRgba(data.buffer.asUint8List());
  } on Object {
    return null;
  }
});
