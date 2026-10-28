import 'package:flutter/widgets.dart';

enum TrackKind { audio, subtitle }

/// An audio or subtitle track the engine found in the media (or loaded from outside).
class TrackInfo {
  const TrackInfo({
    required this.id,
    required this.kind,
    this.title,
    this.language,
    this.isDefault = false,
    this.isForced = false,
    this.codec,
  });
  final String id;
  final TrackKind kind;
  final String? title;
  final String? language;
  final bool isDefault;
  final bool isForced;
  final String? codec;

  String get label {
    final parts = <String>[
      if (language != null && language!.isNotEmpty) languageName(language!),
      if (title != null &&
          title!.isNotEmpty &&
          title!.toLowerCase() != (language ?? '').toLowerCase())
        title!,
      if (codec != null && codec!.isNotEmpty) codec!.toUpperCase(),
      if (isForced) 'forzati',
    ];
    return parts.isEmpty ? 'Traccia $id' : parts.join(' · ');
  }

  static const _names = {
    'ita': 'Italiano',
    'it': 'Italiano',
    'eng': 'Inglese',
    'en': 'Inglese',
    'fra': 'Francese',
    'fre': 'Francese',
    'fr': 'Francese',
    'spa': 'Spagnolo',
    'es': 'Spagnolo',
    'deu': 'Tedesco',
    'ger': 'Tedesco',
    'de': 'Tedesco',
    'por': 'Portoghese',
    'pt': 'Portoghese',
    'jpn': 'Giapponese',
    'ja': 'Giapponese',
    'rus': 'Russo',
    'ru': 'Russo',
    'zho': 'Cinese',
    'chi': 'Cinese',
    'zh': 'Cinese',
    'kor': 'Coreano',
    'ko': 'Coreano',
  };

  static String languageName(String code) => _names[code.toLowerCase()] ?? code;

  /// ISO 639 variants of the same language ("it" / "ita").
  static bool sameLanguage(String? a, String? b) {
    if (a == null || b == null) return false;
    String norm(String x) {
      final l = x.toLowerCase();
      return _names[l] ?? l;
    }

    return norm(a) == norm(b);
  }
}

class EngineTracks {
  const EngineTracks({this.audio = const [], this.subtitles = const []});
  final List<TrackInfo> audio;
  final List<TrackInfo> subtitles;
}

class PlaybackSource {
  const PlaybackSource({
    required this.uri,
    this.headers = const {},
    this.title = '',
    this.start = Duration.zero,
    this.isLocalFile = false,
  });
  final String uri;
  final Map<String, String> headers;
  final String title;
  final Duration start;
  final bool isLocalFile;
}

/// The part of a player the rest of Aether depends on. One implementation wraps the real engine (media_kit / libmpv); tests use
/// a fake. Nothing above this interface knows which engine is running, so a native adapter can be added per platform.
abstract class PlaybackEngine {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;
  Stream<bool> get completedStream;
  Stream<String> get errorStream;
  Stream<EngineTracks> get tracksStream;
  Stream<List<String>> get embeddedSubtitleTextStream;

  Duration get position;
  Duration get duration;
  bool get playing;
  EngineTracks get tracks;

  Future<void> open(PlaybackSource source);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume01);

  /// A raw option of the engine (libmpv property name and value); engines without it ignore the call.
  Future<void> setOption(String name, String value);

  /// What the engine reports about the file that is playing (container, video format, decoder…), for the information panel.
  Future<Map<String, String>> probe();
  Future<void> selectAudio(TrackInfo? track);

  /// Selects an embedded subtitle track, or switches the embedded subtitles off (null).
  Future<void> selectSubtitle(TrackInfo? track);

  Widget buildVideo(BuildContext context, {required BoxFit fit});
  Future<void> dispose();
}
