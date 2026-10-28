import 'dart:async';

import 'package:aether_flutter/core/subtitles/subtitle_loader.dart';
import 'package:aether_flutter/data/library_repository.dart';
import 'package:aether_flutter/data/settings.dart';
import 'package:aether_flutter/data/stores.dart';
import 'package:aether_flutter/features/player/playback_engine.dart';
import 'package:aether_flutter/features/player/player_session.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

class FakeEngine implements PlaybackEngine {
  @override
  Future<Map<String, String>> probe() async => {};

  final Map<String, String> options = {};
  @override
  Future<void> setOption(String name, String value) async =>
      options[name] = value;

  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _tracks = StreamController<EngineTracks>.broadcast();
  final _sub = StreamController<List<String>>.broadcast();
  final calls = <String>[];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  PlaybackSource? opened;

  void emitPosition(Duration d) {
    _position = d;
    _pos.add(d);
  }

  void emitDuration(Duration d) {
    _duration = d;
    _dur.add(d);
  }

  void emitPlaying(bool v) {
    _isPlaying = v;
    _playing.add(v);
  }

  void emitTracks(EngineTracks t) => _tracks.add(t);
  void emitError(String m) => _errors.add(m);
  void emitCompleted() => _completed.add(true);

  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<Duration> get durationStream => _dur.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<bool> get bufferingStream => _buffering.stream;
  @override
  Stream<bool> get completedStream => _completed.stream;
  @override
  Stream<String> get errorStream => _errors.stream;
  @override
  Stream<EngineTracks> get tracksStream => _tracks.stream;
  @override
  Stream<List<String>> get embeddedSubtitleTextStream => _sub.stream;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  bool get playing => _isPlaying;
  @override
  EngineTracks get tracks => const EngineTracks();
  @override
  Future<void> open(PlaybackSource source) async {
    opened = source;
    calls.add('open@${source.start.inSeconds}');
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration to) async => calls.add('seek:${to.inSeconds}');
  @override
  Future<void> setRate(double rate) async => calls.add('rate:$rate');
  @override
  Future<void> setVolume(double v) async => calls.add('volume:$v');
  @override
  Future<void> selectAudio(TrackInfo? t) async => calls.add('audio:${t?.id}');
  @override
  Future<void> selectSubtitle(TrackInfo? t) async => calls.add('sub:${t?.id}');
  @override
  Widget buildVideo(BuildContext context, {required BoxFit fit}) =>
      const SizedBox();
  @override
  Future<void> dispose() async {}
}

const _srt = '1\n00:00:01,000 --> 00:00:03,000\nCiao\n';

PlayerArgs _args({
  List<ExternalSubtitle> subs = const [],
  Future<PlayerArgs?> Function()? next,
}) => PlayerArgs(
  title: 'Film',
  metaId: 'tt1',
  videoId: 'tt1',
  poster: 'p',
  externalSubtitles: subs,
  onNext: next,
  source: const PlaybackSource(uri: 'https://cdn/a.mkv'),
);

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late FakeEngine engine;
  late LibraryRepository library;
  late MemoryStore store;

  PlayerSession make({
    AppSettings settings = const AppSettings(),
    PlayerArgs? args,
  }) => PlayerSession(
    engine: engine,
    args: args ?? _args(),
    library: library,
    settings: settings,
    subtitleLoader: SubtitleLoader(
      dio: fakeDio((o) => (status: 200, body: _srt)),
    ),
    progressInterval: const Duration(milliseconds: 30),
  );

  setUp(() async {
    engine = FakeEngine();
    store = MemoryStore();
    library = LibraryRepository(store);
  });

  test(
    'resumes from the saved position, not when finished or under 10 seconds',
    () async {
      await library.saveProgress(
        WatchProgress(
          metaId: 'tt1',
          videoId: 'tt1',
          type: 'movie',
          name: 'Film',
          positionMs: 600000,
          durationMs: 7200000,
          updatedAt: DateTime.now(),
        ),
      );
      final s = make();
      await s.start();
      expect(engine.calls.first, 'open@600');
      s.dispose();
      final s2 = make(settings: const AppSettings(resumePlayback: false));
      await s2.start();
      expect(engine.calls.last, 'open@0');
      s2.dispose();
    },
  );

  test('progress is saved periodically and on pause, and finished titles are marked watched', () async {
    final s = make();
    await s.start();
    engine.emitDuration(const Duration(minutes: 100));
    engine.emitPosition(const Duration(minutes: 20));
    engine.emitPlaying(true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(library.progressOf('tt1')!.positionMs, 20 * 60 * 1000);
    engine.emitPosition(const Duration(minutes: 30));
    engine.emitPlaying(false);
    await _tick();
    expect(library.progressOf('tt1')!.positionMs, 30 * 60 * 1000);
    engine.emitCompleted();
    await _tick();
    expect(library.isWatched('tt1'), isTrue);
    expect(library.continueWatching, isEmpty);
    s.dispose();
  });

  test('the offline test (no meta id) never writes history', () async {
    final s = make(
      args: const PlayerArgs(
        title: 'Prova',
        source: PlaybackSource(uri: '/tmp/a.mp4', isLocalFile: true),
        saveProgress: false,
      ),
    );
    await s.start();
    engine.emitDuration(const Duration(minutes: 1));
    engine.emitPosition(const Duration(seconds: 30));
    await s.saveProgressNow();
    expect(library.history, isEmpty);
    s.dispose();
  });

  test('preferred audio language is selected and the matching subtitle too; forced only when audio already matches', () async {
    final s = make(
      settings: const AppSettings(
        audioLanguage: 'ita',
        subtitleLanguage: 'ita',
      ),
    );
    await s.start();
    engine.emitTracks(
      const EngineTracks(
        audio: [
          TrackInfo(
            id: '1',
            kind: TrackKind.audio,
            language: 'eng',
            isDefault: true,
          ),
          TrackInfo(id: '2', kind: TrackKind.audio, language: 'ita'),
        ],
        subtitles: [
          TrackInfo(id: '1', kind: TrackKind.subtitle, language: 'ita'),
          TrackInfo(
            id: '2',
            kind: TrackKind.subtitle,
            language: 'ita',
            isForced: true,
          ),
        ],
      ),
    );
    await _tick();
    expect(engine.calls, contains('audio:2'));
    expect(
      engine.calls.last,
      'sub:2',
    ); // audio is Italian now: only the forced track
    expect(s.embeddedSubtitle!.id, '2');
    s.dispose();

    engine.calls.clear();
    final s2 = make(
      settings: const AppSettings(
        audioLanguage: 'eng',
        subtitleLanguage: 'ita',
      ),
    );
    await s2.start();
    engine.emitTracks(
      const EngineTracks(
        audio: [
          TrackInfo(
            id: '1',
            kind: TrackKind.audio,
            language: 'eng',
            isDefault: true,
          ),
        ],
        subtitles: [
          TrackInfo(id: '1', kind: TrackKind.subtitle, language: 'ita'),
          TrackInfo(
            id: '2',
            kind: TrackKind.subtitle,
            language: 'ita',
            isForced: true,
          ),
        ],
      ),
    );
    await _tick();
    expect(s2.embeddedSubtitle!.id, '1');
    s2.dispose();
  });

  test('subtitles off by default setting and external fallback', () async {
    final off = make(
      settings: const AppSettings(subtitlesEnabledByDefault: false),
    );
    await off.start();
    engine.emitTracks(
      const EngineTracks(
        subtitles: [
          TrackInfo(id: '1', kind: TrackKind.subtitle, language: 'ita'),
        ],
      ),
    );
    await _tick();
    expect(off.subtitlesOn, isFalse);
    off.dispose();

    final ext = make(
      settings: const AppSettings(
        audioLanguage: 'eng',
        subtitleLanguage: 'ita',
      ),
      args: _args(
        subs: const [
          ExternalSubtitle(
            id: 'x',
            label: 'ITA',
            language: 'ita',
            url: 'https://s.example/a.srt',
          ),
        ],
      ),
    );
    await ext.start();
    engine.emitTracks(
      const EngineTracks(
        audio: [
          TrackInfo(
            id: '1',
            kind: TrackKind.audio,
            language: 'eng',
            isDefault: true,
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(ext.externalSubtitle!.id, 'x');
    engine.emitPosition(const Duration(seconds: 2));
    await _tick();
    expect(ext.externalLine, 'Ciao');
    ext.setSubtitleOffset(2000); // later by 2 s: 2 s is now before the cue
    expect(ext.externalLine, isNull);
    ext.setSubtitleOffset(-500);
    expect(ext.externalLine, 'Ciao');
    ext.dispose();
  });

  test(
    'a bad subtitle reports a problem and keeps playing; bundled text works',
    () async {
      final s = PlayerSession(
        engine: engine,
        args: _args(),
        library: library,
        settings: const AppSettings(),
        subtitleLoader: SubtitleLoader(
          dio: fakeDio((o) => (status: 200, body: '<html>')),
        ),
      );
      await s.start();
      await s.selectExternalSubtitle(
        const ExternalSubtitle(
          id: 'bad',
          label: 'x',
          url: 'https://s.example/a.srt',
        ),
      );
      expect(s.subtitleProblem, isNotNull);
      expect(s.externalSubtitle, isNull);
      await s.selectExternalSubtitle(
        const ExternalSubtitle(id: 'ok', label: 'x', text: _srt),
      );
      expect(s.subtitleProblem, isNull);
      expect(s.externalSubtitle!.id, 'ok');
      s.dispose();
    },
  );

  test('seek is clamped, speed and aspect are applied, errors are friendly and retry reopens at the same point', () async {
    final s = make();
    await s.start();
    engine.emitDuration(const Duration(seconds: 100));
    engine.emitPosition(const Duration(seconds: 95));
    await _tick();
    await s.seekBy(const Duration(seconds: 30));
    expect(engine.calls.last, 'seek:100');
    await s.seekBy(const Duration(seconds: -500));
    expect(engine.calls.last, 'seek:0');
    await s.setSpeed(1.5);
    expect(engine.calls.last, 'rate:1.5');
    s.cycleAspect();
    expect(s.aspect, AspectMode.fill);
    engine.emitError('HTTP error 403 Forbidden');
    await _tick();
    expect(s.error, contains('rifiutato'));
    await s.retry();
    expect(s.error, isNull);
    expect(engine.opened!.start, const Duration(seconds: 95));
    s.dispose();
  });

  test('autoplay next episode is requested only when there is a next one and the setting allows it', () async {
    final withNext = make(args: _args(next: () async => null));
    await withNext.start();
    engine.emitCompleted();
    await _tick();
    expect(withNext.nextRequested, isTrue);
    withNext.dispose();
    final noNext = make(
      settings: const AppSettings(autoplayNext: false),
      args: _args(next: () async => null),
    );
    await noNext.start();
    engine.emitCompleted();
    await _tick();
    expect(noNext.nextRequested, isFalse);
    noNext.dispose();
  });

  test('switching source keeps the position', () async {
    final s = make();
    await s.start();
    engine.emitPosition(const Duration(seconds: 42));
    await _tick();
    await s.switchSource(
      PlayerAlternative(
        label: 'B',
        open: () async => const PlaybackSource(uri: 'https://cdn/b.mp4'),
      ),
    );
    expect(engine.opened!.uri, 'https://cdn/b.mp4');
    expect(engine.opened!.start, const Duration(seconds: 42));
    s.dispose();
  });
}
