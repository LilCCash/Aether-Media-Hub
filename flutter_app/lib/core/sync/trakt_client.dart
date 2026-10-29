import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/stores.dart';
import 'sync_app.dart';
import '../metadata/service_http.dart';
import '../util/lenient.dart';

/// What the viewer must do to link Trakt: open [verificationUrl] and type [userCode].
class DeviceCode {
  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.interval,
    required this.expiresIn,
  });
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int interval;
  final int expiresIn;
}

enum DevicePoll { pending, linked, expired, denied, slowDown, failed }

/// A title the viewer has watched or wants to watch, as another service names it.
class SyncTitle {
  const SyncTitle(this.imdb, this.type, this.name, {this.year});
  final String imdb;
  final String type; // movie | series
  final String name;
  final int? year;
}

class TraktPull {
  const TraktPull({
    this.watchedMovies = const [],
    this.watchedEpisodes = const {},
    this.watchlist = const [],
  });
  final List<SyncTitle> watchedMovies;

  /// IMDb code of the show → `season:episode` pairs watched.
  final Map<String, Set<String>> watchedEpisodes;
  final List<SyncTitle> watchlist;
}

/// Trakt (https://trakt.docs.apiary.io): linking with the device-code flow (the viewer's own application keys), scrobbling while
/// watching, and a pull of the watched list and the watchlist. Tokens live in the secret store, never in the settings.
class TraktClient {
  TraktClient({required this.secrets, Dio? dio})
    : _http = ServiceHttp(dio: dio, timeout: const Duration(seconds: 12));

  final SecretStore secrets;
  final ServiceHttp _http;
  static final base = Uri.parse('https://api.trakt.tv');

  Future<String?> _client() async => SyncApp.hasTrakt
      ? SyncApp.traktClientId
      : await secrets.serviceKey(ServiceKey.traktClient);
  Future<String?> _secret() async => SyncApp.hasTrakt
      ? SyncApp.traktClientSecret
      : await secrets.serviceKey(ServiceKey.traktSecret);

  Future<Map<String, Object?>?> _tokens() async {
    final raw = await secrets.serviceKey(ServiceKey.traktToken);
    if (raw == null) return null;
    try {
      return asMap(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<bool> get linked async => (await _tokens()) != null;

  Future<void> disconnect() =>
      secrets.setServiceKey(ServiceKey.traktToken, null);

  Future<void> _store(Map<String, Object?> body) async {
    final created =
        asInt(body['created_at']) ??
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expires = created + (asInt(body['expires_in']) ?? 7776000);
    await secrets.setServiceKey(
      ServiceKey.traktToken,
      jsonEncode({
        'access': asString(body['access_token']),
        'refresh': asString(body['refresh_token']),
        'expires': expires,
      }),
    );
  }

  Future<DeviceCode?> startDevice() async {
    final id = await _client();
    if (id == null || id.isEmpty) return null;
    final r = await _http.send(
      'trakt',
      base.replace(path: '/oauth/device/code'),
      method: 'POST',
      data: {'client_id': id},
      contentType: Headers.jsonContentType,
    );
    final m = asMap(r?.body);
    if (r == null || !r.ok || m == null) return null;
    final dc = asString(m['device_code']);
    final uc = asString(m['user_code']);
    if (dc == null || uc == null) return null;
    return DeviceCode(
      deviceCode: dc,
      userCode: uc,
      verificationUrl:
          asString(m['verification_url']) ?? 'https://trakt.tv/activate',
      interval: asInt(m['interval']) ?? 5,
      expiresIn: asInt(m['expires_in']) ?? 600,
    );
  }

  Future<DevicePoll> pollDevice(String deviceCode) async {
    final id = await _client();
    final secret = await _secret();
    if (id == null || secret == null) return DevicePoll.failed;
    final r = await _http.send(
      'trakt',
      base.replace(path: '/oauth/device/token'),
      method: 'POST',
      data: {'code': deviceCode, 'client_id': id, 'client_secret': secret},
      contentType: Headers.jsonContentType,
    );
    if (r == null) return DevicePoll.failed;
    switch (r.status) {
      case 200:
        final m = asMap(r.body);
        if (m == null) return DevicePoll.failed;
        await _store(m);
        return DevicePoll.linked;
      case 400:
        return DevicePoll.pending;
      case 429:
        return DevicePoll.slowDown;
      case 404:
      case 410:
        return DevicePoll.expired;
      case 418:
        return DevicePoll.denied;
      default:
        return DevicePoll.failed;
    }
  }

  /// The headers of an authorised call, refreshing the token when it is about to expire; null when not linked.
  Future<Map<String, String>?> _auth() async {
    final id = await _client();
    var t = await _tokens();
    if (id == null || t == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if ((asInt(t['expires']) ?? 0) - now < 86400) {
      final secret = await _secret();
      final refresh = asString(t['refresh']);
      if (secret != null && refresh != null) {
        final r = await _http.send(
          'trakt',
          base.replace(path: '/oauth/token'),
          method: 'POST',
          data: {
            'refresh_token': refresh,
            'client_id': id,
            'client_secret': secret,
            'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob',
            'grant_type': 'refresh_token',
          },
          contentType: Headers.jsonContentType,
        );
        final m = asMap(r?.body);
        if (r != null && r.ok && m != null) {
          await _store(m);
          t = await _tokens();
        }
      }
    }
    final access = asString(t?['access']);
    if (access == null) return null;
    return {
      'Authorization': 'Bearer $access',
      'trakt-api-version': '2',
      'trakt-api-key': id,
    };
  }

  Map<String, Object?> _target(
    String type,
    String imdb,
    int? season,
    int? episode,
  ) {
    if (type == 'movie') {
      return {
        'movie': {
          'ids': {'imdb': imdb},
        },
      };
    }
    return {
      'show': {
        'ids': {'imdb': imdb},
      },
      'episode': {'season': season, 'number': episode},
    };
  }

  /// `start`, `pause` or `stop` with the progress in percent. Stopping past 80 % makes Trakt count it as watched.
  Future<bool> scrobble(
    String action, {
    required String type,
    required String imdb,
    int? season,
    int? episode,
    required double progress,
  }) async {
    final h = await _auth();
    if (h == null) return false;
    final r = await _http.send(
      'trakt',
      base.replace(path: '/scrobble/$action'),
      method: 'POST',
      headers: h,
      data: {
        ..._target(type, imdb, season, episode),
        'progress': progress.clamp(0, 100),
      },
      contentType: Headers.jsonContentType,
    );
    return r != null && (r.ok || r.status == 409);
  }

  Future<TraktPull?> pull({bool history = true, bool watchlist = true}) async {
    final h = await _auth();
    if (h == null) return null;
    Future<List<Object?>> list(String path) async {
      final r = await _http.send('trakt', base.replace(path: path), headers: h);
      return r != null && r.ok ? asList(r.body) : const [];
    }

    final movies = <SyncTitle>[];
    final episodes = <String, Set<String>>{};
    final wl = <SyncTitle>[];
    if (history) {
      for (final e in await list('/sync/watched/movies')) {
        final m = asMap(asMap(e)?['movie']);
        final imdb = asString(asMap(m?['ids'])?['imdb']);
        if (m != null && imdb != null) {
          movies.add(
            SyncTitle(
              imdb,
              'movie',
              asString(m['title']) ?? imdb,
              year: asInt(m['year']),
            ),
          );
        }
      }
      for (final e in await list('/sync/watched/shows')) {
        final show = asMap(asMap(e)?['show']);
        final imdb = asString(asMap(show?['ids'])?['imdb']);
        if (imdb == null) continue;
        final set = episodes.putIfAbsent(imdb, () => {});
        for (final s in asList(asMap(e)?['seasons'])) {
          final sn = asInt(asMap(s)?['number']);
          for (final ep in asList(asMap(s)?['episodes'])) {
            final en = asInt(asMap(ep)?['number']);
            if (sn != null && en != null) set.add('$sn:$en');
          }
        }
      }
    }
    if (watchlist) {
      for (final e in await list('/sync/watchlist')) {
        final m = asMap(e);
        final isMovie = asString(m?['type']) == 'movie';
        final item = asMap(m?[isMovie ? 'movie' : 'show']);
        final imdb = asString(asMap(item?['ids'])?['imdb']);
        if (item != null && imdb != null) {
          wl.add(
            SyncTitle(
              imdb,
              isMovie ? 'movie' : 'series',
              asString(item['title']) ?? imdb,
              year: asInt(item['year']),
            ),
          );
        }
      }
    }
    return TraktPull(
      watchedMovies: movies,
      watchedEpisodes: episodes,
      watchlist: wl,
    );
  }

  Future<bool> addToWatchlist(String type, String imdb) async {
    final h = await _auth();
    if (h == null) return false;
    final key = type == 'movie' ? 'movies' : 'shows';
    final r = await _http.send(
      'trakt',
      base.replace(path: '/sync/watchlist'),
      method: 'POST',
      headers: h,
      data: {
        key: [
          {
            'ids': {'imdb': imdb},
          },
        ],
      },
      contentType: Headers.jsonContentType,
    );
    return r != null && r.ok;
  }
}
