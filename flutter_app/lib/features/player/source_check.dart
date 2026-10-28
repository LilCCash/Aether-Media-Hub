import 'dart:convert';

import 'package:dio/dio.dart';

import 'playback_engine.dart';

final _dio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 12),
    sendTimeout: const Duration(seconds: 12),
  ),
);

/// A readable line from the first bytes of an answer, or null when it is not text.
String? textSnippet(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final text = utf8.decode(bytes, allowMalformed: true);
  final printable = text.runes
      .where((r) => r == 10 || r == 13 || r == 9 || (r >= 32 && r != 0xFFFD))
      .length;
  if (printable < text.runes.length * 0.9) return null;
  final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty) return null;
  return clean.length > 160 ? '${clean.substring(0, 160)}…' : clean;
}

/// Why a source that answers with an error, a text or a tiny «video» cannot be played, in words for the viewer.
String explainBadAnswer(int status, String? detail, {String? kind}) {
  final d = detail ?? '';
  final lower = d.toLowerCase();
  final b = StringBuffer();
  if (kind == 'tiny') {
    b.write(
      'L’addon ha restituito un breve video di errore al posto del film.',
    );
  } else if (status >= 400) {
    b.write('La fonte non è disponibile (HTTP $status).');
  } else {
    b.write('La fonte ha risposto con un messaggio invece del video.');
  }
  if (lower.contains('401') ||
      lower.contains('unauthorized') ||
      lower.contains('invalid') && lower.contains('key')) {
    b.write(
      ' Il servizio debrid usato dall’addon rifiuta la sua chiave (non autorizzato): controlla la configurazione dell’addon o scegli un’altra fonte.',
    );
  } else if (lower.contains('unavailable') || lower.contains('not cached')) {
    b.write(' Il contenuto non è pronto sul servizio debrid dell’addon.');
  }
  if (d.isNotEmpty) b.write(' «$d»');
  return b.toString();
}

/// Looks at the first bytes of a source before the player opens it. Returns why it cannot be played (an HTTP error, a text
/// answer such as «Debrid playback unavailable: … HTTP 401», a few-hundred-KB error clip), or null when it looks like a real
/// video or when the check itself could not be made (then the player just tries).
Future<String?> checkSource(PlaybackSource s, {Dio? dio}) async {
  final u = Uri.tryParse(s.uri);
  if (u == null || !u.scheme.startsWith('http') || s.isLocalFile) return null;
  try {
    final r = await (dio ?? _dio).getUri<ResponseBody>(
      u,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'User-Agent': 'Aether/1.0',
          ...s.headers,
          'Range': 'bytes=0-2047',
        },
        validateStatus: (_) => true,
      ),
    );
    final code = r.statusCode ?? 0;
    final bytes = <int>[];
    await for (final chunk in r.data!.stream) {
      bytes.addAll(chunk);
      if (bytes.length >= 2048) break;
    }
    final type = (r.headers.value('content-type') ?? '').toLowerCase();
    final isText =
        type.contains('text/') ||
        type.contains('json') ||
        type.contains('html') ||
        type.contains('xml');
    if (code >= 400) {
      return explainBadAnswer(code, textSnippet(bytes));
    }
    // A video starts with binary data: a start that reads as plain text is a message, whatever its content type says.
    final snippet = textSnippet(bytes);
    if (isText || snippet != null) {
      return explainBadAnswer(code, snippet);
    }
    // A real episode or film is many megabytes; an error clip is not.
    final range = r.headers.value('content-range');
    final total = range == null
        ? int.tryParse(r.headers.value('content-length') ?? '')
        : int.tryParse(range.split('/').last);
    if (total != null && total > 0 && total < 1200000) {
      return explainBadAnswer(code, null, kind: 'tiny');
    }
  } on Object {
    return null;
  }
  return null;
}
