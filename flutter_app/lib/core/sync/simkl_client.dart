import 'package:dio/dio.dart';

import '../../data/stores.dart';
import 'sync_app.dart';
import '../metadata/service_http.dart';
import '../util/lenient.dart';
import 'trakt_client.dart' show DeviceCode, DevicePoll;

/// Simkl (https://simkl.docs.apiary.io): linking with a PIN (the viewer's own client id), and the watched list / watchlist sent
/// as titles are finished or saved.
class SimklClient {
  SimklClient({required this.secrets, Dio? dio})
    : _http = ServiceHttp(dio: dio, timeout: const Duration(seconds: 12));

  final SecretStore secrets;
  final ServiceHttp _http;
  static final base = Uri.parse('https://api.simkl.com');

  Future<String?> _client() async => SyncApp.hasSimkl
      ? SyncApp.simklClientId
      : await secrets.serviceKey(ServiceKey.simklClient);
  Future<bool> get linked async =>
      ((await secrets.serviceKey(ServiceKey.simklToken)) ?? '').isNotEmpty;
  Future<void> disconnect() =>
      secrets.setServiceKey(ServiceKey.simklToken, null);

  Future<DeviceCode?> startPin() async {
    final id = await _client();
    if (id == null || id.isEmpty) return null;
    final r = await _http.send(
      'simkl',
      base.replace(path: '/oauth/pin', queryParameters: {'client_id': id}),
    );
    final m = asMap(r?.body);
    final code = asString(m?['user_code']);
    if (r == null || !r.ok || code == null) return null;
    return DeviceCode(
      deviceCode: code,
      userCode: code,
      verificationUrl:
          asString(m?['verification_url']) ?? 'https://simkl.com/pin',
      interval: asInt(m?['interval']) ?? 5,
      expiresIn: asInt(m?['expires_in']) ?? 900,
    );
  }

  Future<DevicePoll> pollPin(String userCode) async {
    final id = await _client();
    if (id == null) return DevicePoll.failed;
    final r = await _http.send(
      'simkl',
      base.replace(
        path: '/oauth/pin/$userCode',
        queryParameters: {'client_id': id},
      ),
    );
    final m = asMap(r?.body);
    if (r == null || !r.ok || m == null) return DevicePoll.failed;
    final token = asString(m['access_token']);
    if (asString(m['result']) == 'OK' && token != null) {
      await secrets.setServiceKey(ServiceKey.simklToken, token);
      return DevicePoll.linked;
    }
    return DevicePoll.pending;
  }

  Future<Map<String, String>?> _auth() async {
    final id = await _client();
    final token = await secrets.serviceKey(ServiceKey.simklToken);
    if (id == null || token == null) return null;
    return {'Authorization': 'Bearer $token', 'simkl-api-key': id};
  }

  /// A film, or an episode of a show, finished.
  Future<bool> markWatched({
    required String type,
    required String imdb,
    int? season,
    int? episode,
  }) async {
    final h = await _auth();
    if (h == null) return false;
    final body = type == 'movie'
        ? {
            'movies': [
              {
                'ids': {'imdb': imdb},
              },
            ],
          }
        : {
            'shows': [
              {
                'ids': {'imdb': imdb},
                'seasons': [
                  {
                    'number': season,
                    'episodes': [
                      {'number': episode},
                    ],
                  },
                ],
              },
            ],
          };
    final r = await _http.send(
      'simkl',
      base.replace(path: '/sync/history'),
      method: 'POST',
      headers: h,
      data: body,
      contentType: Headers.jsonContentType,
    );
    return r != null && r.ok;
  }

  Future<bool> addToWatchlist(String type, String imdb) async {
    final h = await _auth();
    if (h == null) return false;
    final r = await _http.send(
      'simkl',
      base.replace(path: '/sync/add-to-list'),
      method: 'POST',
      headers: h,
      data: {
        type == 'movie' ? 'movies' : 'shows': [
          {
            'to': 'plantowatch',
            'ids': {'imdb': imdb},
          },
        ],
      },
      contentType: Headers.jsonContentType,
    );
    return r != null && r.ok;
  }
}
