import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/util/app_log.dart';
import 'playback_engine.dart';
import 'remux_bridge.dart';

/// [PlaybackEngine] on the system player (AVPlayer on iPhone): the one that can show Picture in Picture, because it draws
/// through a real `AVPlayerLayer`. It opens MP4, MOV and HLS; anything else (MKV, AVI…) stays on libmpv, exactly as in the
/// iOS app. It has no list of embedded tracks: the file plays with its default audio, and subtitles come from the addons.
class AvPlayerEngine implements PlaybackEngine {
  VideoPlayerController? _c;
  Timer? _tick;
  Duration _lastPos = Duration.zero;
  Duration _lastDur = Duration.zero;
  bool _lastPlaying = false;
  bool _lastBuffering = true;
  bool _completed = false;
  String? _lastError;
  double _volume = 1;
  double _rate = 1;

  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _done = StreamController<bool>.broadcast();
  final _err = StreamController<String>.broadcast();
  final _tracks = StreamController<EngineTracks>.broadcast();
  final _subs = StreamController<List<String>>.broadcast();

  /// Whether this engine can take [source]: an http(s) link to a file AVPlayer opens.
  /// The file this engine opened through the converter (an MKV), if any.
  RemuxLease? lease;
  bool _lan = false;
  StreamSubscription<bool>? _route;
  PlaybackSource? _source;
  List<String> languages = const [];
  EngineTracks _trackList = const EngineTracks();

  /// Files the system player reads as they are.
  static bool isNative(PlaybackSource source) {
    final u = Uri.tryParse(source.uri);
    final path = (u?.path ?? source.uri).toLowerCase();
    return path.endsWith('.mp4') ||
        path.endsWith('.m4v') ||
        path.endsWith('.mov') ||
        path.endsWith('.m3u8');
  }

  /// [always]: the viewer chose the system player, so everything that comes from the network is converted to HLS first.
  static bool canOpen(PlaybackSource source, {bool always = false}) {
    if (!Platform.isIOS) return false;
    final isWeb =
        (Uri.tryParse(source.uri)?.scheme.startsWith('http')) ?? false;
    if (isNative(source)) return isWeb || source.isLocalFile;
    return always && isWeb && !source.isLocalFile;
  }

  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<Duration> get durationStream => _dur.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get bufferingStream => _buffering.stream;
  @override
  Stream<bool> get completedStream => _done.stream;
  @override
  Stream<String> get errorStream => _err.stream;
  @override
  Stream<EngineTracks> get tracksStream => _tracks.stream;
  @override
  Stream<List<String>> get embeddedSubtitleTextStream => _subs.stream;

  @override
  Duration get position => _lastPos;
  @override
  Duration get duration => _lastDur;
  @override
  bool get playing => _lastPlaying;
  @override
  EngineTracks get tracks => _trackList;

  /// The size of the picture, once known (for the Picture in Picture window).
  Size get videoSize => _c?.value.size ?? Size.zero;

  void _poll() {
    final c = _c;
    if (c == null) return;
    final v = c.value;
    if (v.hasError &&
        v.errorDescription != null &&
        v.errorDescription != _lastError) {
      _lastError = v.errorDescription;
      _err.add(v.errorDescription!);
    }
    if (v.position != _lastPos) {
      _lastPos = v.position;
      _pos.add(_lastPos);
    }
    if (v.duration != _lastDur) {
      _lastDur = v.duration;
      _dur.add(_lastDur);
    }
    if (v.isPlaying != _lastPlaying) {
      _lastPlaying = v.isPlaying;
      _playing.add(_lastPlaying);
    }
    if (v.isBuffering != _lastBuffering) {
      _lastBuffering = v.isBuffering;
      _buffering.add(_lastBuffering);
    }
    final done =
        v.isInitialized &&
        v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 300) &&
        !v.isPlaying;
    if (done != _completed) {
      _completed = done;
      _done.add(done);
    }
  }

  @override
  Future<void> open(PlaybackSource source) async {
    // On a reopen (another audio track, a change of route) the last picture stays on screen, paused, until the new one is ready.
    final old = _c;
    if (old != null) unawaited(old.pause());
    _completed = false;
    _lastError = null;
    _source = source;
    var uri = Uri.parse(source.uri);
    var headers = source.headers;
    if (!source.isLocalFile && !isNative(source)) {
      // MKV and the rest: the phone converts it to HLS and AVPlayer plays that (so picture in picture and AirPlay work).
      try {
        AppLog.instance.add('player', 'AVPlayer: converto il file (remux)');
        final l = await RemuxBridge.open(
          source.uri,
          source.headers,
          languages: languages,
          audioIndex: _audioIndex,
          lan: _lan,
        );
        AppLog.instance.add(
          'player',
          'AVPlayer: conversione pronta, apro la lista HLS',
        );
        lease = l;
        uri = l.url;
        headers = const {};
        _trackList = EngineTracks(audio: l.audio);
        // On the phone the file is served on 127.0.0.1 (no network permission needed); when the output moves to an AirPlay
        // receiver it is served again on the Wi-Fi address, from the same place.
        _route ??= RemuxBridge.airplay.listen((on) {
          if (on != _lan && lease != null) {
            _lan = on;
            unawaited(_reopenHere());
          }
        });
        if (!_lan && await RemuxBridge.airplayActive()) {
          _lan = true;
          unawaited(_reopenHere());
        }
      } on TimeoutException {
        throw StateError(
          'La conversione del file non risponde (oltre 5 minuti).',
        );
      } on Object catch (e) {
        throw StateError(RemuxBridge.messageOf(e));
      }
    }
    final c = source.isLocalFile
        ? VideoPlayerController.file(
            File(source.uri),
            viewType: VideoViewType.platformView,
            // Without this the plugin pauses the video when the app goes to the background, which is also when Picture in Picture opens.
            videoPlayerOptions: VideoPlayerOptions(
              allowBackgroundPlayback: true,
            ),
          )
        : VideoPlayerController.networkUrl(
            uri,
            httpHeaders: headers,
            viewType: VideoViewType.platformView,
            // Without this the plugin pauses the video when the app goes to the background, which is also when Picture in Picture opens.
            videoPlayerOptions: VideoPlayerOptions(
              allowBackgroundPlayback: true,
            ),
          );
    try {
      await c.initialize().timeout(const Duration(seconds: 45));
    } on TimeoutException {
      unawaited(c.dispose());
      throw StateError('AVPlayer non carica la lista HLS (oltre 45 s).');
    }
    _tick?.cancel();
    _c = c;
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _poll());
    // The picture is redrawn on the new controller first; the old one goes away once the new view is on screen.
    _swap.value++;
    if (old != null) {
      Timer(const Duration(milliseconds: 600), () => unawaited(old.dispose()));
    }
    AppLog.instance.add('player', 'AVPlayer: pronto');
    await Future.wait([
      c.setVolume(_volume),
      if (_rate != 1.0) c.setPlaybackSpeed(_rate),
    ]);
    if (source.start > Duration.zero) await c.seekTo(source.start);
    await c.play();
    _tracks.add(_trackList);
    _poll();
  }

  @override
  Future<void> play() async => _c?.play();
  @override
  Future<void> pause() async => _c?.pause();
  @override
  Future<void> seek(Duration to) async => _c?.seekTo(to);
  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    await _c?.setPlaybackSpeed(rate);
  }

  @override
  Future<void> setVolume(double volume01) async {
    _volume = volume01.clamp(0.0, 1.0);
    await _c?.setVolume(_volume);
  }

  @override
  Future<void> setOption(String name, String value) async {
    // libmpv options (decoding, picture, subtitle style): AVPlayer has none of them.
  }

  @override
  Future<Map<String, String>> probe() async {
    final v = _c?.value;
    if (v == null || !v.isInitialized) return const {};
    return {
      'file-format': 'AVPlayer (sistema)',
      if (v.size != Size.zero) 'video-params/w': '${v.size.width.round()}',
      if (v.size != Size.zero) 'video-params/h': '${v.size.height.round()}',
      'hwdec-current': 'videotoolbox',
    };
  }

  int? _audioIndex;

  /// Counts the controller swaps, so the picture is built again on the new one.
  final _swap = ValueNotifier<int>(0);

  Future<void> _reopenHere() async {
    final src = _source;
    if (src == null) return;
    await open(
      PlaybackSource(
        uri: src.uri,
        headers: src.headers,
        title: src.title,
        start: _lastPos,
      ),
    );
  }

  /// With a converted file the audio is one track of the HLS: choosing another converts again, from where the viewer is.
  @override
  Future<void> selectAudio(TrackInfo? track) async {
    final src = _source;
    if (track == null || lease == null || src == null) return;
    _audioIndex = int.tryParse(track.id);
    final at = _lastPos;
    await open(
      PlaybackSource(
        uri: src.uri,
        headers: src.headers,
        title: src.title,
        start: at,
      ),
    );
  }

  @override
  Future<void> selectSubtitle(TrackInfo? track) async {}

  @override
  Widget buildVideo(BuildContext context, {required BoxFit fit}) {
    return ValueListenableBuilder<int>(
      valueListenable: _swap,
      builder: (context, _, _) {
        final c = _c;
        if (c == null) return const SizedBox.expand();
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: c,
          builder: (context, v, _) {
            if (!v.isInitialized || v.size == Size.zero) {
              return const SizedBox.expand();
            }
            return ClipRect(
              child: SizedBox.expand(
                child: FittedBox(
                  fit: fit,
                  child: SizedBox(
                    width: v.size.width,
                    height: v.size.height,
                    child: VideoPlayer(c, key: ObjectKey(c)),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Future<void> dispose() async {
    _tick?.cancel();
    await _route?.cancel();
    await _c?.dispose();
    if (lease != null) await RemuxBridge.close();
    for (final s in [
      _pos,
      _dur,
      _playing,
      _buffering,
      _done,
      _err,
      _tracks,
      _subs,
    ]) {
      await s.close();
    }
  }
}
