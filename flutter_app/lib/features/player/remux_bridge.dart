import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/util/app_log.dart';
import 'playback_engine.dart';

/// One subtitle line read from the file: the track it belongs to, when it shows and what it says.
class RemuxCueItem {
  const RemuxCueItem(this.track, this.start, this.end, this.text);
  final String track;
  final Duration start;
  final Duration end;
  final String text;
}

/// What the phone serves for a file: the address a player or a television opens.
class RemuxLease {
  const RemuxLease({
    required this.id,
    required this.url,
    required this.lan,
    this.audio = const [],
    this.subtitles = const [],
  });
  final String id;
  final Uri url;

  /// Served on the Wi-Fi address (a television can fetch it), not only on this phone.
  final bool lan;
  final List<TrackInfo> audio;

  /// The text subtitle tracks inside the file (their lines arrive on [RemuxBridge.cues] as the pieces are made).
  final List<TrackInfo> subtitles;
}

/// iPhone: Matroska → HLS on the phone (FFmpeg, in the native plugin), so the system player (picture in picture, AirPlay) and Google
/// Cast can play MKV files; and a relay for sources that need request headers a television cannot send. One file at a time.
class RemuxBridge {
  static const _ch = MethodChannel('aether/remux');

  static bool get supported => Platform.isIOS;

  static final _airplay = StreamController<bool>.broadcast();
  static final _cueEvents = StreamController<List<RemuxCueItem>>.broadcast();

  /// Subtitle lines read from the file, in batches, as its pieces are made.
  static Stream<List<RemuxCueItem>> get cues {
    _listen();
    return _cueEvents.stream;
  }

  static bool _listening = false;

  static void _listen() {
    if (_listening || !supported) return;
    _listening = true;
    _ch.setMethodCallHandler((call) async {
      final a = call.arguments as Map?;
      if (call.method == 'route') {
        _airplay.add(a?['airplay'] == true);
      } else if (call.method == 'cues') {
        final items = <RemuxCueItem>[];
        for (final r in (a?['items'] as List? ?? const [])) {
          final l = r as List;
          items.add(
            RemuxCueItem(
              '${l[0]}',
              Duration(milliseconds: ((l[1] as num) * 1000).round()),
              Duration(milliseconds: ((l[2] as num) * 1000).round()),
              '${l[3]}',
            ),
          );
        }
        if (items.isNotEmpty) _cueEvents.add(items);
      } else if (call.method == 'log') {
        AppLog.instance.add('remux', '${a?['m']}');
      }
    });
  }

  /// True when the output goes to an AirPlay receiver, false when it comes back to the phone.
  static Stream<bool> get airplay {
    _listen();
    return _airplay.stream;
  }

  static Future<bool> airplayActive() async {
    try {
      return await _ch.invokeMethod<bool>('airplay') ?? false;
    } on Object {
      return false;
    }
  }

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
    final subs = <TrackInfo>[
      for (final a in (m['subtitles'] as List? ?? const []))
        TrackInfo(
          id: '${(a as Map)['index']}',
          kind: TrackKind.subtitle,
          language: (a['language'] as String?)?.isEmpty ?? true
              ? null
              : a['language'] as String,
          title: (a['title'] as String?)?.isEmpty ?? true
              ? null
              : a['title'] as String,
          codec: a['codec'] as String?,
          isDefault: a['isDefault'] == true,
          isForced: a['isForced'] == true,
        ),
    ];
    return RemuxLease(
      id: m['id'] as String,
      url: Uri.parse(m['url'] as String),
      lan: m['lan'] == true,
      audio: tracks,
      subtitles: subs,
    );
  }

  /// Converts [url] (an MKV) into HLS. Throws a [PlatformException] whose message says why, in Italian.
  static Future<RemuxLease> open(
    String url,
    Map<String, String> headers, {
    List<String> languages = const [],
    int? audioIndex,
    bool lan = true,
  }) async {
    _listen();
    return _lease(
      await _ch
          .invokeMethod<Object>('open', {
            'url': url,
            'headers': headers,
            'languages': languages,
            'audioIndex': ?audioIndex,
            'lan': lan,
          })
          .timeout(const Duration(seconds: 300)),
    );
  }

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
