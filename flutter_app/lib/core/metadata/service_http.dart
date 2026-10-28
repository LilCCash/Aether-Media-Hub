import 'package:dio/dio.dart';

import '../util/app_log.dart';
import '../util/lenient.dart';

/// Answer of a service call: the status and the decoded JSON (or null when the body is not JSON).
class ServiceReply {
  const ServiceReply(this.status, this.body);
  final int status;
  final Object? body;
  bool get ok => status >= 200 && status < 300;
}

/// The small HTTP wrapper the optional metadata services share: fixed timeouts, no exceptions for HTTP statuses, network
/// failures reported as a null reply and logged without the address (which may carry a key).
class ServiceHttp {
  ServiceHttp({Dio? dio, Duration timeout = const Duration(seconds: 10)})
    : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = timeout;
    _dio.options.receiveTimeout = timeout;
    _dio.options.validateStatus = (_) => true;
  }

  final Dio _dio;

  Future<ServiceReply?> send(
    String area,
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? data,
    String? contentType,
    CancelToken? cancel,
  }) async {
    try {
      final response = await _dio.requestUri<Object?>(
        uri,
        data: data,
        cancelToken: cancel,
        options: Options(
          method: method,
          headers: {'Accept': 'application/json', ...headers},
          contentType: contentType,
          responseType: ResponseType.json,
        ),
      );
      Object? body = response.data;
      if (body is String) {
        body = body.isEmpty ? null : _tryJson(body);
      }
      return ServiceReply(response.statusCode ?? 0, body);
    } on DioException catch (e) {
      if (!CancelToken.isCancel(e)) {
        AppLog.instance.add(area, 'Errore di rete (${e.type.name})');
      }
      return null;
    }
  }

  static Object? _tryJson(String s) {
    try {
      return asMapOrList(s);
    } on FormatException {
      return null;
    }
  }
}
