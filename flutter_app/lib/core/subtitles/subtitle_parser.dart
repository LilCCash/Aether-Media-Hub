/// One timed line of text.
class SubtitleCue {
  const SubtitleCue(this.start, this.end, this.text);
  final Duration start;
  final Duration end;
  final String text;
}

/// SubRip (.srt) and WebVTT (.vtt) parsing, plus a text-only reading of ASS/SSA. Formats that are pictures (PGS, VobSub) are
/// not parsed here: the player engine renders those when they are embedded in the file.
class SubtitleParser {
  const SubtitleParser._();

  static List<SubtitleCue> parse(String content) {
    final text = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceFirst('﻿', '');
    if (RegExp(
      r'^\[Script Info\]',
      multiLine: true,
      caseSensitive: false,
    ).hasMatch(text))
      return _ass(text);
    return _timed(text);
  }

  static final RegExp _time = RegExp(
    r'(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})\s*-->\s*(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})',
  );

  static Duration _dur(String? h, String m, String s, String ms) => Duration(
    hours: int.tryParse(h ?? '0') ?? 0,
    minutes: int.parse(m),
    seconds: int.parse(s),
    milliseconds: int.parse(ms.padRight(3, '0').substring(0, 3)),
  );

  static List<SubtitleCue> _timed(String text) {
    final cues = <SubtitleCue>[];
    for (final block in text.split(RegExp(r'\n{2,}'))) {
      final lines = block.split('\n');
      final index = lines.indexWhere((l) => _time.hasMatch(l));
      if (index < 0) continue;
      final m = _time.firstMatch(lines[index])!;
      final body = lines.sublist(index + 1).join('\n');
      final clean = clean_(body);
      if (clean.isEmpty) continue;
      cues.add(
        SubtitleCue(
          _dur(m[1], m[2]!, m[3]!, m[4]!),
          _dur(m[5], m[6]!, m[7]!, m[8]!),
          clean,
        ),
      );
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static List<SubtitleCue> _ass(String text) {
    final cues = <SubtitleCue>[];
    var textIndex = 9;
    var startIndex = 1;
    var endIndex = 2;
    for (final line in text.split('\n')) {
      if (line.startsWith('Format:') && line.contains('Text')) {
        final fields = line
            .substring(7)
            .split(',')
            .map((f) => f.trim().toLowerCase())
            .toList();
        textIndex = fields.indexOf('text');
        startIndex = fields.indexOf('start');
        endIndex = fields.indexOf('end');
      } else if (line.startsWith('Dialogue:')) {
        final parts = line.substring(9).trim().split(',');
        if (parts.length <= textIndex) continue;
        final start = _assTime(parts[startIndex]);
        final end = _assTime(parts[endIndex]);
        if (start == null || end == null) continue;
        final body = parts
            .sublist(textIndex)
            .join(',')
            .replaceAll(RegExp(r'\{[^}]*\}'), '')
            .replaceAll(r'\N', '\n')
            .replaceAll(r'\n', '\n');
        final clean = clean_(body);
        if (clean.isNotEmpty) cues.add(SubtitleCue(start, end, clean));
      }
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static Duration? _assTime(String s) {
    final m = RegExp(r'(\d+):(\d{2}):(\d{2})[.](\d{1,2})').firstMatch(s.trim());
    if (m == null) return null;
    return Duration(
      hours: int.parse(m[1]!),
      minutes: int.parse(m[2]!),
      seconds: int.parse(m[3]!),
      milliseconds: int.parse(m[4]!.padRight(2, '0')) * 10,
    );
  }

  /// Removes markup and, optionally, the sound descriptions written for deaf viewers: "[door slams]", "♪ ... ♪", "JOHN:".
  static String clean_(String raw, {bool removeHearingImpaired = false}) {
    var s = raw
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\{\\[^}]*\}'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"');
    if (removeHearingImpaired) {
      s = s
          .replaceAll(RegExp(r'[\[\(][^\]\)]*[\]\)]'), '')
          .replaceAll(RegExp(r'^[♪♫].*$', multiLine: true), '');
      s = s.replaceAll(
        RegExp(r'^[A-ZÀ-Ý][A-ZÀ-Ý .\-]{1,24}:\s*', multiLine: true),
        '',
      );
    }
    return s
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join('\n');
  }

  /// The cue shown at [position] once the viewer's [offset] (positive = later) is applied; null when none.
  static SubtitleCue? cueAt(
    List<SubtitleCue> cues,
    Duration position, {
    Duration offset = Duration.zero,
  }) {
    final t = position - offset;
    var lo = 0;
    var hi = cues.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final cue = cues[mid];
      if (t < cue.start) {
        hi = mid - 1;
      } else if (t >= cue.end) {
        lo = mid + 1;
      } else {
        return cue;
      }
    }
    return null;
  }
}
