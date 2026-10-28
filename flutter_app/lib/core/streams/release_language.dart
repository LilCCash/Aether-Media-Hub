/// Best-effort parser of the audio languages in a release name, ported from the iOS app (ReleaseLanguageDetector).
/// Scene/P2P names use tags such as ITA, ENG, MULTI or DUAL AUDIO. Subtitle-only tags (SUB ITA, VOSTFR, HARDSUB…) are removed
/// first, so «ENG SUB ITA» counts as English audio, not Italian.
class ReleaseLanguage {
  ReleaseLanguage._();

  static final _subtitlePatterns = [
    RegExp(
      r'(?<![A-Z0-9])(?:SUBS?|SUBTITLE|SUBTITLES|HARDSUB|SOFTSUB|VOSTFR|VOSTEN|VOST|SUBBED)\s*[ ._-]*(?:ITA|IT|ITALIAN|ITALIANO|ENG|EN|ENGLISH|FRA|FRE|FR|FRENCH|FRANCAIS|SPA|ESP|ES|SPANISH|CASTELLANO|DEU|GER|DE|GERMAN|POR|PT|PORTUGUESE)(?![A-Z0-9])',
    ),
    RegExp(
      r'(?<![A-Z0-9])(?:SUBS?|SUBTITLE|SUBTITLES|HARDSUB|SOFTSUB|VOSTFR|VOSTEN|VOST|SUBBED)(?![A-Z0-9])',
    ),
  ];

  static final _markers = <(RegExp, String)>[
    (RegExp(r'(?<![A-Z0-9])(?:ITA|ITALIAN|ITALIANO)(?![A-Z0-9])'), 'it'),
    (RegExp(r'(?<![A-Z0-9])(?:ENG|ENGLISH)(?![A-Z0-9])'), 'en'),
    (RegExp(r'(?<![A-Z0-9])(?:FRA|FRE|FRENCH|FRANCAIS)(?![A-Z0-9])'), 'fr'),
    (RegExp(r'(?<![A-Z0-9])(?:SPA|ESP|SPANISH|CASTELLANO)(?![A-Z0-9])'), 'es'),
    (RegExp(r'(?<![A-Z0-9])(?:DEU|GER|GERMAN|DEUTSCH)(?![A-Z0-9])'), 'de'),
    (RegExp(r'(?<![A-Z0-9])(?:POR|PORTUGUESE|PORTUGUES)(?![A-Z0-9])'), 'pt'),
    (RegExp(r'(?<![A-Z0-9])(?:PT[ .]?BR|BRAZILIAN)(?![A-Z0-9])'), 'pt-BR'),
    (
      RegExp(
        r'(?<![A-Z0-9])(?:MULTI|MULTILANGUAGE|DUAL[ ]?AUDIO|MULTI[ ]?AUDIO|ML)(?![A-Z0-9])',
      ),
      'multi',
    ),
  ];

  // Two-letter tags are ambiguous in titles («The IT Crowd»): only in brackets, or in the tail next to technical markers.
  static const _tail =
      r'(?= (?:\d{3,4}P|WEB|BLURAY|BDRIP|DVDRIP|DLMUX|HDTV|X26[45]|H\.?26[45]|HEVC|AV1)(?: |$))';
  static final _short = <(RegExp, String)>[
    (RegExp(r'(?:\[IT\]|\(IT\))'), 'it'),
    (RegExp(r'(?:\[EN\]|\(EN\))'), 'en'),
    (RegExp(r'(?:\[ES\]|\(ES\))'), 'es'),
    (RegExp(r'(?:\[FR\]|\(FR\))'), 'fr'),
    (RegExp(r'(?:\[DE\]|\(DE\))'), 'de'),
    (RegExp(r'(?:\[PT\]|\(PT\))'), 'pt'),
    (RegExp('(?:^| )IT$_tail'), 'it'),
    (RegExp('(?:^| )EN$_tail'), 'en'),
    (RegExp('(?:^| )ES$_tail'), 'es'),
    (RegExp('(?:^| )FR$_tail'), 'fr'),
    (RegExp('(?:^| )DE$_tail'), 'de'),
    (RegExp('(?:^| )PT$_tail'), 'pt'),
  ];

  /// The language codes of the audio clues, in a fixed order (`it`, `en`, `fr`, `es`, `de`, `pt`, `pt-BR`, `multi`).
  static List<String> codes(String text) {
    var v = text.toUpperCase().replaceAll(RegExp(r'[_.\-]'), ' ');
    for (final p in _subtitlePatterns) {
      v = v.replaceAll(p, ' ');
    }
    final found = <String>[];
    for (final (re, code) in [..._markers, ..._short]) {
      if (re.hasMatch(v) && !found.contains(code)) found.add(code);
    }
    if (found.isEmpty && v.contains('🇮🇹')) found.add('it');
    if (found.isEmpty && (v.contains('🇬🇧') || v.contains('🇺🇸'))) {
      found.add('en');
    }
    return found;
  }

  /// The names the analyzer and the settings use.
  static const names = {
    'it': 'Italiano',
    'en': 'Inglese',
    'fr': 'Francese',
    'es': 'Spagnolo',
    'de': 'Tedesco',
    'pt': 'Portoghese',
    'pt-BR': 'Portoghese',
    'multi': 'Multi',
  };

  static List<String> languages(String text) => [
    for (final c in codes(text))
      if (names[c] != null && !(c == 'pt-BR' && codes(text).contains('pt')))
        names[c]!,
  ];
}
