import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'playback_engine.dart';

/// [PlaybackEngine] on media_kit (libmpv). Chosen because it plays the containers and codecs the addons really serve (MKV, AVI,
/// HEVC, multiple audio and subtitle tracks, ASS) on both iOS and Android with one code path. See docs/research/decisions/ADR-002.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine() {
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'Aether',
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _video = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
  }

  late final Player _player;
  late final VideoController _video;

  static bool _initialised = false;
  static void ensureInitialised() {
    if (_initialised) return;
    MediaKit.ensureInitialized();
    _initialised = true;
  }

  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<bool> get playingStream => _player.stream.playing;
  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;
  @override
  Stream<bool> get completedStream => _player.stream.completed;
  @override
  Stream<String> get errorStream => _player.stream.error;
  @override
  Stream<List<String>> get embeddedSubtitleTextStream =>
      _player.stream.subtitle;

  EngineTracks _map(Tracks t) => EngineTracks(
    audio: [
      for (final a in t.audio)
        if (a.id != 'auto' && a.id != 'no')
          TrackInfo(
            id: a.id,
            kind: TrackKind.audio,
            title: a.title,
            language: a.language,
            isDefault: a.isDefault ?? false,
            codec: a.codec,
          ),
    ],
    subtitles: [
      for (final s in t.subtitle)
        if (s.id != 'auto' && s.id != 'no')
          TrackInfo(
            id: s.id,
            kind: TrackKind.subtitle,
            title: s.title,
            language: s.language,
            isDefault: s.isDefault ?? false,
            codec: s.codec,
          ),
    ],
  );

  @override
  Stream<EngineTracks> get tracksStream => _player.stream.tracks.map(_map);

  @override
  Duration get position => _player.state.position;
  @override
  Duration get duration => _player.state.duration;
  @override
  bool get playing => _player.state.playing;
  @override
  EngineTracks get tracks => _map(_player.state.tracks);

  @override
  Future<void> open(PlaybackSource source) => _player.open(
    Media(
      source.uri,
      httpHeaders: source.headers.isEmpty ? null : source.headers,
      start: source.start == Duration.zero ? null : source.start,
    ),
    play: true,
  );

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration to) => _player.seek(to);
  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setOption(String name, String value) async {
    final p = _player.platform;
    if (p is NativePlayer) await p.setProperty(name, value);
  }

  @override
  Future<Map<String, String>> probe() async {
    final p = _player.platform;
    final out = <String, String>{};
    if (p is! NativePlayer) return out;
    for (final k in const [
      'file-format',
      'video-format',
      'video-codec',
      'hwdec-current',
      'video-params/w',
      'video-params/h',
      'video-params/pixelformat',
      'video-params/primaries',
      'video-params/gamma',
      'video-params/colormatrix',
      'container-fps',
      'video-bitrate',
      'audio-codec-name',
      'audio-params/channel-count',
      'audio-params/samplerate',
      'audio-bitrate',
    ]) {
      try {
        final v = await p.getProperty(k);
        if (v.isNotEmpty) out[k] = v;
      } on Object {
        // not available for this file
      }
    }
    return out;
  }

  @override
  Future<void> setVolume(double volume01) =>
      _player.setVolume((volume01.clamp(0.0, 1.0)) * 100);

  @override
  Future<void> selectAudio(TrackInfo? track) async {
    if (track == null) return _player.setAudioTrack(AudioTrack.auto());
    final match = _player.state.tracks.audio.where((a) => a.id == track.id);
    if (match.isNotEmpty) await _player.setAudioTrack(match.first);
  }

  @override
  Future<void> selectSubtitle(TrackInfo? track) async {
    if (track == null) return _player.setSubtitleTrack(SubtitleTrack.no());
    final match = _player.state.tracks.subtitle.where((s) => s.id == track.id);
    if (match.isNotEmpty) await _player.setSubtitleTrack(match.first);
  }

  @override
  Widget buildVideo(BuildContext context, {required BoxFit fit}) => Video(
    controller: _video,
    fit: fit,
    controls: NoVideoControls,
    fill: Colors.black,
    // Embedded subtitles are drawn by the engine's own view; the one external-file overlay is Aether's.
    subtitleViewConfiguration: const SubtitleViewConfiguration(
      style: TextStyle(
        fontSize: 34,
        color: Colors.white,
        fontWeight: FontWeight.w600,
        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
      ),
    ),
  );

  @override
  Future<void> dispose() => _player.dispose();
}
