import 'dart:convert';

import '../model/stream.dart';
import '../util/lenient.dart';

/// One imported badge: shown on every source whose text matches one of the entries.
class CustomBadgeRule {
  const CustomBadgeRule({
    required this.uid,
    required this.label,
    required this.match,
    this.colorHex,
    this.borderHex,
    this.fillHex,
    this.fillAlpha = 0.18,
    this.imageUrl,
  });

  final String uid;
  final String label;

  /// Words (case-insensitive); an entry starting with "re:" is a regular expression.
  final List<String> match;
  final String? colorHex;
  final String? borderHex;
  final String? fillHex;
  final double fillAlpha;

  /// A ready-made picture of the badge (https), drawn instead of the text when present.
  final String? imageUrl;

  static final Map<String, RegExp?> _regexCache = {};

  static RegExp? _regex(String pattern) => _regexCache.putIfAbsent(pattern, () {
    try {
      // Dart has no inline flags: the common «(?i)» (case-insensitive) is already what is asked for below.
      return RegExp(
        pattern.replaceAll('(?i)', '').replaceAll('(?-i)', ''),
        caseSensitive: false,
      );
    } on FormatException {
      return null;
    }
  });

  bool matches(String text) {
    final lower = text.toLowerCase();
    for (final e in match) {
      if (e.startsWith('re:')) {
        if (_regex(e.substring(3))?.hasMatch(text) ?? false) return true;
      } else if (e.isNotEmpty && lower.contains(e.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  Map<String, Object?> toJson() => {
    'uid': uid,
    'label': label,
    'match': match,
    'colorHex': colorHex,
    'borderHex': borderHex,
    'fillHex': fillHex,
    'fillAlpha': fillAlpha,
    'imageUrl': imageUrl,
  };

  static CustomBadgeRule? fromJson(Object? raw) {
    final m = asMap(raw);
    final label = asNonEmptyString(m?['label']);
    final match = asStringList(m?['match']);
    if (m == null || label == null || match.isEmpty) return null;
    return CustomBadgeRule(
      uid: asNonEmptyString(m['uid']) ?? label,
      label: label,
      match: match,
      colorHex: asNonEmptyString(m['colorHex']),
      borderHex: asNonEmptyString(m['borderHex']),
      fillHex: asNonEmptyString(m['fillHex']),
      fillAlpha: (asDouble(m['fillAlpha']) ?? 0.18).clamp(0.0, 1.0),
      imageUrl: CustomBadgePack.https(m['imageUrl']),
    );
  }
}

/// A badge pack as published at a link. Two shapes are understood (same as the iOS app):
/// - the Nuvio/Fusion style `{"filters":[{"name","pattern","imageURL","tagColor","borderColor","textColor","isEnabled"}]}`;
/// - the simple list `[{"label":"Remux","match":["remux"],"color":"#FF9500"}]` (or inside `{"badges":[…]}`).
/// Patterns are regular expressions: they only ever run on the text of a source, never anything else.
class CustomBadgePack {
  static const maxRules = 300;
  static const maxBytes = 1500000;

  /// "#RRGGBB" or "#AARRGGBB" (also without "#") → colour and alpha.
  static ({String hex, double alpha})? color(Object? value) {
    final raw = asNonEmptyString(value)?.toUpperCase();
    if (raw == null) return null;
    final digits = raw.startsWith('#') ? raw.substring(1) : raw;
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(digits)) return null;
    if (digits.length == 6) return (hex: '#$digits', alpha: 1.0);
    if (digits.length == 8) {
      return (
        hex: '#${digits.substring(2)}',
        alpha: int.parse(digits.substring(0, 2), radix: 16) / 255,
      );
    }
    return null;
  }

  static String? https(Object? value) {
    final text = asNonEmptyString(value);
    final uri = text == null ? null : Uri.tryParse(text);
    return (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty)
        ? text
        : null;
  }

  static List<CustomBadgeRule> parse(String text) {
    if (text.length > maxBytes) return const [];
    final Object? object;
    try {
      object = jsonDecode(text);
    } on FormatException {
      return const [];
    }
    final List<Object?> list;
    if (object is List) {
      list = object;
    } else {
      final m = asMap(object);
      list = asList(m?['filters']).isNotEmpty
          ? asList(m?['filters'])
          : (asList(m?['badges']).isNotEmpty
                ? asList(m?['badges'])
                : (asList(m?['rules']).isNotEmpty
                      ? asList(m?['rules'])
                      : asList(m?['items'])));
    }
    final rules = <CustomBadgeRule>[];
    for (final entry in list) {
      final item = asMap(entry);
      if (item == null) continue;
      if (item['isEnabled'] == false) continue;
      final label =
          (asNonEmptyString(item['label']) ??
                  asNonEmptyString(item['name']) ??
                  asNonEmptyString(item['text']) ??
                  '')
              .trim();
      final words = <String>[];
      for (final key in const [
        'match',
        'keywords',
        'pattern',
        'regex',
        'contains',
      ]) {
        final v = item[key];
        final asRegex = key == 'regex' || key == 'pattern';
        if (v is String) words.add(asRegex ? 're:$v' : v);
        if (v is List) words.addAll(asStringList(v));
      }
      final clean = words
          .map((w) => w.trim())
          .where((w) => w.isNotEmpty)
          .take(12)
          .toList();
      if (label.isEmpty || clean.isEmpty) continue;
      final text =
          color(item['textColor']) ??
          color(item['color']) ??
          color(item['colour']) ??
          color(item['hex']);
      final fill = color(item['tagColor']);
      final border = color(item['borderColor']);
      rules.add(
        CustomBadgeRule(
          uid: '${rules.length}',
          label: label.length > 24 ? label.substring(0, 24) : label,
          match: clean,
          colorHex: text?.hex,
          borderHex: border?.hex,
          fillHex: (fill ?? text)?.hex,
          fillAlpha: fill?.alpha ?? 0.18,
          imageUrl: https(item['imageURL']),
        ),
      );
      if (rules.length >= maxRules) break;
    }
    return rules;
  }

  /// The imported badges that apply to a source.
  static List<CustomBadgeRule> badgesFor(
    AddonStream stream,
    List<CustomBadgeRule> rules,
  ) {
    if (rules.isEmpty) return const [];
    // The same text the analyzer reads: name, description, file name and the last part of the link.
    final text = stream.searchText;
    return rules.where((r) => r.matches(text)).toList();
  }
}
