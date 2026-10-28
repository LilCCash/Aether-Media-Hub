import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/subtitles/subtitle_loader.dart';
import '../../core/subtitles/subtitle_parser.dart';
import '../../core/util/app_log.dart';
import '../../data/library_repository.dart';
import '../../data/settings.dart';
import 'playback_engine.dart';

/// A subtitle that does not live inside the video file: from an addon (a link), or bundled (text).
class ExternalSubtitle {
  const ExternalSubtitle({required this.id, required this.label, this.language, this.url, this.text});
  final String id;
  final String label;
  final String? language;
  final String? url;
  final String? text;
}

class PlayerAlternative {
  const PlayerAlternative({required this.label, required this.open});
  final String label;

  /// Prepares the other source (it can take time: a debrid link) and returns it.
  final Future<PlaybackSource> Function() open;
}

/// What the player is asked to play, and who it belongs to.
class PlayerArgs {
  const PlayerArgs({
    required this.title,
    required this.source,
    this.metaId = '',
    this.videoId = '',
    this.type = 'movie',
    this.poster,
    this.season,
    this.episode,
    this.episodeTitle,
    this.externalSubtitles = const [],
    this.alternatives = const [],
    this.onNext,
    this.saveProgress = true,
  });

  final String title;
  final PlaybackSource source;
  final String metaId;
  final String videoId;
  final String type;
  final String? poster;
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final List<ExternalSubtitle> externalSubtitles;
  final List<PlayerAlternative> alternatives;

  /// Prepares the next episode (null when there is none).
  final Future<PlayerArgs?> Function()? onNext;
  final bool saveProgress;

  bool get isEpisode => season != null && episode != null;
}

enum AspectMode { fit, fill, stretch }

extension AspectFit on AspectMode {
  BoxFit get boxFit => switch (this) { AspectMode.fit => BoxFit.contain, AspectMode.fill => BoxFit.cover, AspectMode.stretch => BoxFit.fill };
  String get label => switch (this) { AspectMode.fit => 'Adatta', AspectMode.fill => 'Riempi', AspectMode.stretch => 'Allunga' };
}

/// The state and the rules of one playback: resume, progress saving, preferred audio / subtitle tracks, external subtitles with a
/// time offset, speed, aspect, errors and "next episode". The widgets only draw it.
class PlayerSession extends ChangeNotifier {
  PlayerSession({required this.engine, required this.args, required this.library, required this.settings, required this.subtitleLoader, Duration progressInterval = const Duration(seconds: 5)}) : _progressInterval = progressInterval;

  final PlaybackEngine engine;
  PlayerArgs args;
  final LibraryRepository library;
  final AppSettings settings;
  final SubtitleLoader subtitleLoader;
  final Duration _progressInterval;

  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _progressTimer;
  bool _disposed = false;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool buffering = true;
  String? error;
  EngineTracks tracks = const EngineTracks();
  TrackInfo? audio;
  TrackInfo? embeddedSubtitle;
  ExternalSubtitle? externalSubtitle;
  List<SubtitleCue> _cues = const [];
  String? subtitleProblem;
  bool loadingSubtitle = false;
  int subtitleOffsetMs = 0;
  double speed = 1.0;
  AspectMode aspect = AspectMode.fit;
  bool locked = false;
  bool completedReached = false;
  bool nextRequested = false;
  bool _autoTracksApplied = false;
  bool _opened = false;

  /// The line of an external subtitle at the current position (offset applied), or null.
  String? get externalLine {
    if (externalSubtitle == null || _cues.isEmpty) return null;
    return SubtitleParser.cueAt(_cues, position, offset: Duration(milliseconds: subtitleOffsetMs))?.text;
  }

  bool get subtitlesOn => embeddedSubtitle != null || externalSubtitle != null;

  Future<void> start({bool resume = true}) async {
    subtitleOffsetMs = settings.subtitleOffsetMs;
    speed = settings.playbackSpeed;
    var startAt = args.source.start;
    if (resume && settings.resumePlayback && args.saveProgress && startAt == Duration.zero && args.videoId.isNotEmpty) {
      final p = library.progressOf(args.videoId);
      if (p != null && p.resumable) startAt = Duration(milliseconds: p.positionMs);
    }
    _subs
      ..add(engine.positionStream.listen((d) {
        position = d;
        notifyListeners();
      }))
      ..add(engine.durationStream.listen((d) {
        duration = d;
        notifyListeners();
      }))
      ..add(engine.playingStream.listen((v) {
        final wasPlaying = playing;
        playing = v;
        if (wasPlaying && !v) unawaited(saveProgressNow());
        notifyListeners();
      }))
      ..add(engine.bufferingStream.listen((v) {
        buffering = v;
        notifyListeners();
      }))
      ..add(engine.errorStream.listen(_onError))
      ..add(engine.tracksStream.listen(_onTracks))
      ..add(engine.completedStream.listen((done) {
        if (done) unawaited(_onCompleted());
      }));
    _progressTimer = Timer.periodic(_progressInterval, (_) {
      if (playing) unawaited(saveProgressNow());
    });
    try {
      await engine.open(PlaybackSource(uri: args.source.uri, headers: args.source.headers, title: args.title, start: startAt, isLocalFile: args.source.isLocalFile));
      _opened = true;
      if (speed != 1.0) await engine.setRate(speed);
    } on Object catch (e) {
      AppLog.instance.add('player', 'Apertura non riuscita: ${e.runtimeType}');
      error = 'Non riesco ad aprire questo video.';
      notifyListeners();
    }
  }

  void _onError(String message) {
    if (message.trim().isEmpty) return;
    AppLog.instance.add('player', 'Errore del motore: $message');
    error = _friendly(message);
    notifyListeners();
  }

  static String _friendly(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('403') || m.contains('401') || m.contains('forbidden')) return 'Il server ha rifiutato l’accesso al video (il link potrebbe essere scaduto).';
    if (m.contains('404') || m.contains('not found')) return 'Il video non è più disponibile su questo link.';
    if (m.contains('timed out') || m.contains('timeout') || m.contains('connect')) return 'Connessione al server non riuscita o troppo lenta.';
    if (m.contains('unsupported') || m.contains('codec') || m.contains('demuxer') || m.contains('format')) return 'Questo formato o codec non è supportato da questo dispositivo.';
    return 'Non riesco a riprodurre questo video.';
  }

  void _onTracks(EngineTracks t) {
    tracks = t;
    if (!_autoTracksApplied && (t.audio.isNotEmpty || t.subtitles.isNotEmpty)) {
      _autoTracksApplied = true;
      unawaited(_applyPreferredTracks());
    }
    notifyListeners();
  }

  Future<void> _applyPreferredTracks() async {
    TrackInfo? preferredAudio;
    for (final a in tracks.audio) {
      if (TrackInfo.sameLanguage(a.language, settings.audioLanguage)) {
        preferredAudio = a;
        break;
      }
    }
    final defaultAudio = tracks.audio.where((a) => a.isDefault).firstOrNull;
    if (preferredAudio != null && preferredAudio != defaultAudio) {
      await selectAudio(preferredAudio);
    } else {
      audio = preferredAudio ?? defaultAudio ?? tracks.audio.firstOrNull;
    }
    if (!settings.subtitlesEnabledByDefault) {
      await engine.selectSubtitle(null);
      return;
    }
    final audioLang = audio?.language;
    final wanted = tracks.subtitles.where((s) => TrackInfo.sameLanguage(s.language, settings.subtitleLanguage)).toList();
    // When the film is already in the viewer's language only the forced subtitles (foreign dialogue) are wanted.
    final sameAsAudio = TrackInfo.sameLanguage(audioLang, settings.subtitleLanguage);
    if (wanted.isNotEmpty) {
      final pick = sameAsAudio ? wanted.where((s) => s.isForced).firstOrNull : (wanted.where((s) => !s.isForced).firstOrNull ?? wanted.first);
      if (pick != null) {
        await selectEmbeddedSubtitle(pick);
        return;
      }
    }
    if (!sameAsAudio) {
      final ext = args.externalSubtitles.where((s) => TrackInfo.sameLanguage(s.language, settings.subtitleLanguage)).firstOrNull;
      if (ext != null) {
        await selectExternalSubtitle(ext);
        return;
      }
    }
    await engine.selectSubtitle(null);
  }

  // Controls -----------------------------------------------------------------------------------------------------------

  Future<void> togglePlay() => playing ? engine.pause() : engine.play();

  Future<void> seekTo(Duration to) async {
    final max = duration > Duration.zero ? duration : to;
    await engine.seek(Duration(milliseconds: to.inMilliseconds.clamp(0, max.inMilliseconds)));
  }

  Future<void> seekBy(Duration delta) => seekTo(position + delta);

  Future<void> setSpeed(double value) async {
    speed = value;
    await engine.setRate(value);
    notifyListeners();
  }

  void setAspect(AspectMode mode) {
    aspect = mode;
    notifyListeners();
  }

  void cycleAspect() => setAspect(AspectMode.values[(aspect.index + 1) % AspectMode.values.length]);

  void setLocked(bool value) {
    locked = value;
    notifyListeners();
  }

  Future<void> selectAudio(TrackInfo? track) async {
    audio = track;
    await engine.selectAudio(track);
    notifyListeners();
  }

  Future<void> selectEmbeddedSubtitle(TrackInfo? track) async {
    externalSubtitle = null;
    _cues = const [];
    subtitleProblem = null;
    embeddedSubtitle = track;
    await engine.selectSubtitle(track);
    notifyListeners();
  }

  Future<void> disableSubtitles() async {
    externalSubtitle = null;
    _cues = const [];
    subtitleProblem = null;
    embeddedSubtitle = null;
    await engine.selectSubtitle(null);
    notifyListeners();
  }

  Future<void> selectExternalSubtitle(ExternalSubtitle sub) async {
    loadingSubtitle = true;
    subtitleProblem = null;
    notifyListeners();
    try {
      List<SubtitleCue> cues;
      if (sub.text != null) {
        cues = SubtitleParser.parse(sub.text!);
        if (cues.isEmpty) throw const FormatException('Nel file non ho trovato sottotitoli leggibili.');
      } else {
        cues = await subtitleLoader.load(sub.url!);
      }
      if (settings.removeHearingImpaired) {
        cues = [for (final c in cues) if (SubtitleParser.clean_(c.text, removeHearingImpaired: true).isNotEmpty) SubtitleCue(c.start, c.end, SubtitleParser.clean_(c.text, removeHearingImpaired: true))];
      }
      await engine.selectSubtitle(null); // only one subtitle at a time
      embeddedSubtitle = null;
      externalSubtitle = sub;
      _cues = cues;
    } on FormatException catch (e) {
      subtitleProblem = e.message;
      AppLog.instance.add('subtitles', 'Sottotitolo non caricato');
    } on Object catch (_) {
      subtitleProblem = 'Non riesco a scaricare questo sottotitolo.';
    } finally {
      loadingSubtitle = false;
      notifyListeners();
    }
  }

  /// Positive = the subtitles appear later.
  void setSubtitleOffset(int ms) {
    subtitleOffsetMs = ms.clamp(-30000, 30000);
    notifyListeners();
  }

  /// Opens another source of the same title at the same point.
  Future<void> switchSource(PlayerAlternative alternative) async {
    final at = position;
    error = null;
    buffering = true;
    notifyListeners();
    try {
      final next = await alternative.open();
      await engine.open(PlaybackSource(uri: next.uri, headers: next.headers, title: args.title, start: at, isLocalFile: next.isLocalFile));
      _autoTracksApplied = false;
    } on Object catch (e) {
      error = e is Exception ? e.toString() : 'Non riesco ad aprire questa sorgente.';
      notifyListeners();
    }
  }

  Future<void> retry() async {
    final at = position;
    error = null;
    buffering = true;
    notifyListeners();
    try {
      await engine.open(PlaybackSource(uri: args.source.uri, headers: args.source.headers, title: args.title, start: at, isLocalFile: args.source.isLocalFile));
    } on Object {
      error = 'Non riesco ad aprire questo video.';
      notifyListeners();
    }
  }

  // Progress -----------------------------------------------------------------------------------------------------------

  Future<void> saveProgressNow() async {
    if (!args.saveProgress || args.metaId.isEmpty || args.videoId.isEmpty || duration <= Duration.zero || !_opened) return;
    await library.saveProgress(WatchProgress(
      metaId: args.metaId, videoId: args.videoId, type: args.type, name: args.title, poster: args.poster, season: args.season, episode: args.episode,
      episodeTitle: args.episodeTitle, positionMs: position.inMilliseconds, durationMs: duration.inMilliseconds, updatedAt: DateTime.now(),
    ));
  }

  Future<void> _onCompleted() async {
    if (completedReached) return;
    completedReached = true;
    if (args.saveProgress && args.metaId.isNotEmpty) {
      await library.markWatched(args.metaId, args.videoId, type: args.type, name: args.title, poster: args.poster, season: args.season, episode: args.episode);
    }
    if (settings.autoplayNext && args.onNext != null) nextRequested = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _progressTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(saveProgressNow());
    super.dispose();
  }

  bool get disposed => _disposed;
}
