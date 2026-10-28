import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/debrid/torbox_client.dart';
import '../../core/streams/release_language.dart';
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
///
/// With [language], [season] and [episode] (a season download) the name of the file the link really leads to is also read: a
/// name that states another language, or another episode, makes the source unsuitable.
Future<String?> checkSource(
  PlaybackSource s, {
  Dio? dio,
  String? language,
  int? season,
  int? episode,
}) async {
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
    if (code < 400 && (language != null || season != null)) {
      final disposition = r.headers.value('content-disposition') ?? '';
      final named = RegExp(r'filename\*?=(?:UTF-8\x27\x27)?"?([^";]+)')
          .firstMatch(disposition)
          ?.group(1);
      final last = r.realUri.pathSegments.isEmpty
          ? ''
          : r.realUri.pathSegments.last;
      final name = Uri.decodeComponent(named ?? last);
      final why = wrongFile(
        name,
        language: language,
        season: season,
        episode: episode,
      );
      if (why != null) return why;
    }
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

/// Why a file called [name] is not the one wanted: it states another episode, or another language than the one asked for.
String? wrongFile(String name, {String? language, int? season, int? episode}) {
  final tag = TorBoxClient.parseEpisode(name);
  if (season != null && episode != null && tag != null) {
    if (tag.$1 != season || tag.$2 != episode) {
      return 'Il file è un altro episodio (S${tag.$1}E${tag.$2}).';
    }
  }
  if (language != null) {
    final found = ReleaseLanguage.languages(name);
    if (found.isNotEmpty &&
        !found.contains(language) &&
        !found.contains('Multi')) {
      return 'Il file è in un’altra lingua (${found.join(', ')}).';
    }
  }
  return null;
}
