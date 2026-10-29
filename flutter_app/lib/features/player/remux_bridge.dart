import 'dart:io';

import 'package:flutter/services.dart';

import 'playback_engine.dart';

/// What the phone serves for a file: the address a player or a television opens.
class RemuxLease {
  const RemuxLease({
    required this.id,
    required this.url,
    required this.lan,
    this.audio = const [],
  });
  final String id;
  final Uri url;

  /// Served on the Wi-Fi address (a television can fetch it), not only on this phone.
  final bool lan;
  final List<TrackInfo> audio;
}

/// iPhone: Matroska → HLS on the phone (FFmpeg, in the native plugin), so the system player (picture in picture, AirPlay) and Google
/// Cast can play MKV files; and a relay for sources that need request headers a television cannot send. One file at a time.
class RemuxBridge {
  static const _ch = MethodChannel('aether/remux');

  static bool get supported => Platform.isIOS;

  static bool isMatroska(String uriOrPath) {
    final p = (Uri.tryParse(uriOrPath)?.path ?? uriOrPath).toLowerCase();
    return p.endsWith('.mkv') || p.endsWith('.mka');
  }

  static String extensionOf(String uriOrPath) {
    final p = Uri.tryParse(uriOrPath)?.path ?? uriOrPath;
    final dot = p.lastIndexOf('.');
    return dot < 0 ? 'mp4' : p.substring(dot + 1).toLowerCase();
  }

  static Future<bool> available() async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('available') ?? false;
    } on Object {
      return false;
    }
  }

  static RemuxLease _lease(Object? raw) {
    final m = Map<Object?, Object?>.from(raw as Map);
    final tracks = <TrackInfo>[
      for (final a in (m['audio'] as List? ?? const []))
        TrackInfo(
          id: '${(a as Map)['index']}',
          kind: TrackKind.audio,
          language: (a['language'] as String?)?.isEmpty ?? true
              ? null
              : a['language'] as String,
          title: (a['title'] as String?)?.isEmpty ?? true
              ? null
              : a['title'] as String,
          codec: a['codec'] as String?,
          isDefault: a['isDefault'] == true,
        ),
    ];
    return RemuxLease(
      id: m['id'] as String,
      url: Uri.parse(m['url'] as String),
      lan: m['lan'] == true,
      audio: tracks,
    );
  }

  /// Converts [url] (an MKV) into HLS. Throws a [PlatformException] whose message says why, in Italian.
  static Future<RemuxLease> open(
    String url,
    Map<String, String> headers, {
    List<String> languages = const [],
    int? audioIndex,
    bool lan = true,
  }) async => _lease(
    await _ch.invokeMethod<Object>('open', {
      'url': url,
      'headers': headers,
      'languages': languages,
      'audioIndex': ?audioIndex,
      'lan': lan,
    }),
  );

  /// Forwards the file as it is through the phone (the television gets an address without headers).
  static Future<RemuxLease> forward(
    String url,
    Map<String, String> headers,
  ) async => _lease(
    await _ch.invokeMethod<Object>('forward', {
      'url': url,
      'headers': headers,
      'ext': extensionOf(url),
    }),
  );

  static Future<void> close() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod<void>('close');
    } on Object {
      // nothing was open
    }
  }

  static String messageOf(Object e) => e is PlatformException
      ? (e.message ?? 'Conversione non riuscita.')
      : '$e';
}
