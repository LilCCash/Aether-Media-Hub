import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

typedef FakeHandler = ({int status, String body}) Function(RequestOptions options);

/// A Dio adapter that answers from a function: no network is touched by any test.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final FakeHandler handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final r = handler(options);
    return ResponseBody.fromBytes(utf8.encode(r.body), r.status, headers: {Headers.contentTypeHeader: ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

Dio fakeDio(FakeHandler handler, [List<RequestOptions>? log]) {
  final adapter = FakeAdapter(handler);
  final dio = Dio()..httpClientAdapter = adapter;
  return dio;
}
