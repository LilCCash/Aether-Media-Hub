import 'package:dio/dio.dart';

import '../metadata/service_http.dart';
import '../util/lenient.dart';

enum SkipKind { intro, recap, credits }

/// A stretch of an episode the viewer can jump over.
class SkipSegment {
  const SkipSegment(this.kind, this.start, this.end);
  final SkipKind kind;
  final double start;
  final double end;
}

class EpisodeSkipSegments {
  const EpisodeSkipSegments({this.intro, this.recap, this.credits});
  final SkipSegment? intro;
  final SkipSegment? recap;

  /// Where the end credits start, when the service knows (it is also what the «next episode» card waits for).
  final SkipSegment? credits;
  static const none = EpisodeSkipSegments();
  bool get isEmpty => intro == null && recap == null && credits == null;

  static const lead = 1.0;
  static const tail = 1.0;

  /// The segment the playhead is in. [duration] rejects data that cannot belong to this file (a segment ending well after
  /// the end is the timing of another cut).
  SkipSegment? active(double position, {double? duration}) {
    if (!position.isFinite || position < 0) return null;
    for (final s in [recap, intro].whereType<SkipSegment>()) {
      if (duration != null && duration > 0 && s.end > duration + 5) continue;
      if (position >= s.start - lead && position < s.end - tail) return s;
    }
    return null;
  }
}

/// Public IntroDB read API (https://api.introdb.app, no key): `GET /segments?imdb_id=tt…&season=N&episode=M`.
/// The data is contributed by volunteers for one cut of an episode: it can be a few seconds off for another.
class IntroDbClient {
  IntroDbClient({Dio? dio, Uri? baseUrl})
    : _http = ServiceHttp(dio: dio, timeout: const Duration(seconds: 6)),
      base = baseUrl ?? Uri.parse('https://api.introdb.app');

  final ServiceHttp _http;
  final Uri base;
  static const longest = 600.0;
  static const shortest = 3.0;

  static bool isValidImdb(String id) => RegExp(r'^tt[0-9]{6,10}$').hasMatch(id);

  /// Null when nothing could be found out (offline, rate limited); [EpisodeSkipSegments.none] when the service knows nothing.
  Future<EpisodeSkipSegments?> segments(
    String imdb,
    int season,
    int episode, {
    CancelToken? cancel,
  }) async {
    if (!isValidImdb(imdb) || season < 0 || season > 500 || episode < 0) {
      return null;
    }
    final reply = await _http.send(
      'introdb',
      base.replace(
        path: '/segments',
        queryParameters: {
          'imdb_id': imdb,
          'season': '$season',
          'episode': '$episode',
        },
      ),
      cancel: cancel,
    );
    if (reply == null) return null;
    if (reply.status == 404) return EpisodeSkipSegments.none;
    if (!reply.ok) return null;
    return parse(reply.body);
  }

  static EpisodeSkipSegments parse(Object? body) {
    final m = asMap(body);
    SkipSegment? make(SkipKind kind, Object? raw) {
      final p = asMap(raw);
      if (p == null) return null;
      final start =
          asDouble(p['start_sec']) ??
          asDouble(p['start_ms'])?.let((v) => v / 1000);
      final end =
          asDouble(p['end_sec']) ?? asDouble(p['end_ms'])?.let((v) => v / 1000);
      if (start == null || end == null || !start.isFinite || !end.isFinite) {
        return null;
      }
      final length = end - start;
      if (start < 0 || length < shortest || length > longest) return null;
      return SkipSegment(kind, start, end);
    }

    return EpisodeSkipSegments(
      intro: make(SkipKind.intro, m?['intro']),
      recap: make(SkipKind.recap, m?['recap']),
      credits: make(
        SkipKind.credits,
        m?['outro'] ?? m?['credits'] ?? m?['end_credits'],
      ),
    );
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// Remembers answers (also "nothing known") so a failing service is not asked on every episode.
class SkipSegmentsService {
  SkipSegmentsService(this.client);
  final IntroDbClient client;
  final Map<String, (EpisodeSkipSegments, DateTime)> _known = {};
  DateTime? _pausedUntil;

  Future<EpisodeSkipSegments?> segments(
    String imdb,
    int season,
    int episode,
  ) async {
    final key = '$imdb:$season:$episode';
    final now = DateTime.now();
    final hit = _known[key];
    if (hit != null && hit.$2.isAfter(now)) return hit.$1;
    if (_pausedUntil?.isAfter(now) ?? false) return null;
    final found = await client.segments(imdb, season, episode);
    if (found == null) {
      _pausedUntil = now.add(const Duration(seconds: 30));
      return null;
    }
    _known[key] = (
      found,
      now.add(
        found.isEmpty ? const Duration(hours: 6) : const Duration(hours: 24),
      ),
    );
    return found;
  }
}
