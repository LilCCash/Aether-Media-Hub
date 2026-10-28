import 'package:dio/dio.dart';

import '../addons/network_policy.dart';
import 'badge_pack.dart';

/// Downloads a badge pack from a link. https only, no credentials in the address, no local addresses, at most 1.5 MB, short
/// timeouts. The text is only parsed as data (JSON); nothing in it is ever executed.
class BadgePackLoader {
  BadgePackLoader({Dio? dio, this.policy = const NetworkPolicy()})
    : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 15);
    _dio.options.validateStatus = (_) => true;
  }

  final Dio _dio;
  final NetworkPolicy policy;

  /// Throws [FormatException] with a reason in Italian.
  Future<List<CustomBadgeRule>> load(String address) async {
    final uri = Uri.tryParse(address.trim());
    if (uri == null || uri.scheme != 'https') {
      throw const FormatException('Serve un indirizzo che inizi con https://.');
    }
    final why = policy.reject(uri);
    if (why != null) throw FormatException(why);
    final Response<String> response;
    try {
      response = await _dio.getUri<String>(
        uri,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Accept': 'application/json'},
          maxRedirects: 3,
        ),
      );
    } on DioException {
      throw const FormatException('Impossibile scaricare il file dei badge.');
    }
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw FormatException('Il server ha risposto con errore $status.');
    }
    final text = response.data ?? '';
    if (text.length > CustomBadgePack.maxBytes) {
      throw const FormatException('Il file è troppo grande (massimo 1,5 MB).');
    }
    final rules = CustomBadgePack.parse(text);
    if (rules.isEmpty) {
      throw const FormatException(
        'Nel file non c’è nessun badge che riconosco (formato «filters» o elenco con label/match).',
      );
    }
    return rules;
  }
}
