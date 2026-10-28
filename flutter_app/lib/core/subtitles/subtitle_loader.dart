import 'dart:convert';

import 'package:dio/dio.dart';

import '../addons/network_policy.dart';
import 'subtitle_parser.dart';

/// Downloads an external subtitle file (from an addon) and reads it. Limited in size, validated, with Latin-1 as a fallback
/// for old files that are not UTF-8.
class SubtitleLoader {
  SubtitleLoader({Dio? dio, NetworkPolicy policy = const NetworkPolicy()})
      : _dio = dio ?? Dio(),
        _policy = policy;

  final Dio _dio;
  final NetworkPolicy _policy;
  static const int maxBytes = 3 * 1024 * 1024;

  Future<List<SubtitleCue>> load(String url, {CancelToken? cancel}) async {
    final uri = Uri.tryParse(url);
    if (uri == null) throw const FormatException('Indirizzo del sottotitolo non valido.');
    final problem = _policy.reject(uri);
    if (problem != null) throw FormatException(problem);
    final response = await _dio.getUri<List<int>>(
      uri,
      cancelToken: cancel,
      options: Options(responseType: ResponseType.bytes, receiveTimeout: const Duration(seconds: 15), sendTimeout: const Duration(seconds: 10), validateStatus: (_) => true),
    );
    if ((response.statusCode ?? 0) ~/ 100 != 2) throw FormatException('Il server dei sottotitoli ha risposto ${response.statusCode}.');
    final bytes = response.data ?? const <int>[];
    if (bytes.length > maxBytes) throw const FormatException('Il file dei sottotitoli è troppo grande.');
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = latin1.decode(bytes);
    }
    final cues = SubtitleParser.parse(text);
    if (cues.isEmpty) throw const FormatException('Nel file non ho trovato sottotitoli leggibili (formato non supportato?).');
    return cues;
  }
}
