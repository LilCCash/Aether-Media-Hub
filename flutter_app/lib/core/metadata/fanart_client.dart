import 'package:dio/dio.dart';

import '../util/lenient.dart';
import 'service_http.dart';

enum FanartKind { movie, tv }

/// fanart.tv (API v3) with the user's own key: only the transparent logo of a film or a series, shown by the player while a
/// source is prepared. Every failure simply means "no logo".
class FanartClient {
  FanartClient({required this.keyProvider, Dio? dio, Uri? baseUrl})
    : _http = ServiceHttp(dio: dio, timeout: const Duration(seconds: 8)),
      base = baseUrl ?? Uri.parse('https://webservice.fanart.tv/v3');

  final Future<String?> Function() keyProvider;
  final ServiceHttp _http;
  final Uri base;

  /// Films by TMDB or IMDb id, series by TheTVDB id.
  Future<String?> logoUrl(
    FanartKind kind,
    String id,
    String language, {
    CancelToken? cancel,
  }) async {
    final key = (await keyProvider())?.trim() ?? '';
    if (key.isEmpty || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(id)) return null;
    final reply = await _http.send(
      'fanart',
      base.replace(
        path: '${base.path}/${kind == FanartKind.movie ? 'movies' : 'tv'}/$id',
        queryParameters: {'api_key': key},
      ),
      cancel: cancel,
    );
    final body = asMap(reply?.body);
    if (reply == null || !reply.ok || body == null) return null;
    final logos = <Map<String, Object?>>[
      for (final k in const [
        'hdmovielogo',
        'hdtvlogo',
        'movielogo',
        'clearlogo',
      ])
        ...asList(body[k]).map(asMap).whereType<Map<String, Object?>>(),
    ];
    return bestLogo(logos, language);
  }

  /// The viewer's language first, then English, then the most liked; only https images served by fanart.tv.
  static String? bestLogo(List<Map<String, Object?>> logos, String language) {
    final wanted = (language.length >= 2 ? language.substring(0, 2) : language)
        .toLowerCase();
    int tier(Map<String, Object?> l) {
      final lang = (asString(l['lang']) ?? '').toLowerCase();
      return lang == wanted ? 0 : (lang == 'en' ? 1 : 2);
    }

    final ordered = [...logos]
      ..sort((a, b) {
        final t = tier(a).compareTo(tier(b));
        if (t != 0) return t;
        return (asInt(b['likes']) ?? 0).compareTo(asInt(a['likes']) ?? 0);
      });
    for (final l in ordered) {
      final uri = Uri.tryParse(asString(l['url']) ?? '');
      final host = uri?.host.toLowerCase() ?? '';
      if (uri != null &&
          uri.scheme == 'https' &&
          (host == 'fanart.tv' || host.endsWith('.fanart.tv'))) {
        return uri.toString();
      }
    }
    return null;
  }
}
