import 'search_intent.dart';

/// Livello 2 della ricerca avanzata: capisce in locale frasi italiane come «commedie demenziali degli ultimi anni».
/// Niente rete, niente AI: un dizionario di parole. Quel che non riconosce resta tra le «parole rimaste».
class ParsedQuery {
  const ParsedQuery(this.intent, this.leftovers);
  final SearchIntent intent;
  final List<String> leftovers;
}

class NaturalQueryParser {
  NaturalQueryParser({int? currentYear})
    : currentYear = currentYear ?? DateTime.now().year;

  final int currentYear;

  static const _genreStems = <IntentGenre, List<String>>{
    IntentGenre.comedy: [
      'commedi',
      'divert',
      'comic',
      'ridere',
      'ridicol',
      'spassos',
      'demenzial',
      'esilarant',
      'umoristic',
      'satir',
    ],
    IntentGenre.horror: [
      'horror',
      'paura',
      'spavent',
      'terrore',
      'splatter',
      'slasher',
      'inquiet',
    ],
    IntentGenre.thriller: ['thriller', 'suspense', 'tension', 'adrenalin'],
    IntentGenre.action: ['azione', 'action', 'esplosiv', 'combattiment'],
    IntentGenre.adventure: ['avventur'],
    IntentGenre.animation: [
      'animazion',
      'animat',
      'cartoni',
      'cartone',
      'pixar',
      'disney',
    ],
    IntentGenre.scifi: [
      'fantascien',
      'scifi',
      'sci-fi',
      'spaziali',
      'spazio',
      'alieni',
      'distopic',
      'cyberpunk',
    ],
    IntentGenre.fantasy: ['fantasy', 'magic', 'fantastic', 'incantat'],
    IntentGenre.drama: ['dramma', 'drammatic', 'commovent', 'strappalacrime'],
    IntentGenre.romance: ['romanti', 'amore', "d'amore", 'sentimental'],
    IntentGenre.documentary: ['documentar'],
    IntentGenre.war: ['guerra', 'bellic'],
    IntentGenre.western: ['western', 'spaghetti'],
    IntentGenre.mystery: [
      'giall',
      'mister',
      'investigativ',
      'detective',
      'whodunit',
    ],
    IntentGenre.crime: [
      'crimin',
      'gangster',
      'mafia',
      'polizies',
      'rapin',
      'heist',
      'criminal',
    ],
    IntentGenre.family: ['famigli', 'bambini', 'ragazzi'],
    IntentGenre.music: ['music', 'concert'],
    IntentGenre.history: [
      'storic',
      'period',
      'epoca',
      "d'epoca",
      'antica',
      'medieval',
    ],
  };

  static const _countryStems = <String, List<String>>{
    'IT': ['italian'],
    'US': ['american', 'hollywood'],
    'FR': ['francese', 'francesi'],
    'ES': ['spagnol'],
    'DE': ['tedesch'],
    'GB': ['british', 'inglesi', 'inglese', 'britannic'],
    'KR': ['corean'],
    'JP': ['giappones'],
    'IN': ['indian', 'bollywood'],
    'CN': ['cines'],
    'SE': ['svedes'],
    'DK': ['danes'],
    'MX': ['messican'],
    'BR': ['brasilian'],
    'TR': ['turch'],
  };

  static const _keywordHints = <(String, String)>[
    ('demenzial', 'slapstick'),
    ('slasher', 'slasher'),
    ('heist', 'heist'),
    ('rapin', 'heist'),
    ('spaghetti', 'spaghetti western'),
    ('zombie', 'zombie'),
    ('vampir', 'vampire'),
    ('supereroi', 'superhero'),
    ('cyberpunk', 'cyberpunk'),
    ('distopic', 'dystopia'),
    ('parodi', 'parody'),
    ('natal', 'christmas'),
    ('viaggi nel tempo', 'time travel'),
    ('alieni', 'alien'),
    ('robot', 'robot'),
    ('serial killer', 'serial killer'),
    ('mafia', 'mafia'),
    ('storia vera', 'based on true story'),
  ];

  static const _stopwords = <String>{
    'il',
    'lo',
    'la',
    'i',
    'gli',
    'le',
    'un',
    'uno',
    'una',
    'di',
    'del',
    'dello',
    'della',
    'dei',
    'degli',
    'delle',
    'da',
    'dal',
    'dallo',
    'dalla',
    'dai',
    'dagli',
    'dalle',
    'in',
    'nel',
    'nello',
    'nella',
    'nei',
    'negli',
    'nelle',
    'con',
    'su',
    'sul',
    'per',
    'tra',
    'fra',
    'e',
    'ed',
    'o',
    'che',
    'ci',
    'sono',
    'ho',
    'voglio',
    'vorrei',
    'cerco',
    'cercare',
    'trova',
    'trovami',
    'mostrami',
    'dammi',
    'qualche',
    'alcuni',
    'alcune',
    'molto',
    'piu',
    'film',
    'films',
    'serie',
    'serial',
    'tv',
    'telefilm',
    'movie',
    'movies',
    'titoli',
    'roba',
    'cose',
    'bei',
    'bel',
    'belli',
    'bello',
    'bella',
    'belle',
    'buoni',
    'buon',
    'buona',
    'tipo',
    'stile',
    'genere',
    'ultimi',
    'ultime',
    'ultimo',
    'ultima',
    'anni',
    'anno',
    'recenti',
    'recente',
    'famosi',
    'famose',
    'famoso',
    'famosa',
    'visti',
    'dell',
    'all',
    'alla',
    'alle',
    'agli',
    'ai',
    'al',
    'quelli',
    'quelle',
    'quello',
    'quella',
    'molti',
    'tanti',
    'tante',
    'mi',
    'ti',
    'si',
    'ne',
    'non',
    'ma',
    'se',
    'come',
    'dove',
    'quando',
    'anche',
    'solo',
  };

  static const _decades = <String, int>{
    'sessanta': 1960,
    'settanta': 1970,
    'ottanta': 1980,
    'novanta': 1990,
    'duemila': 2000,
  };

  /// «film simili a Toy Story», «film tipo Scary Movie», «serie come Lost».
  static ({String title, IntentKind? kind})? similarRequest(String raw) {
    const prefix = r'^\s*(film|serie tv|serie|telefilm|titoli)?\s*';
    final patterns = <(String, bool)>[
      (
        '$prefix(?:simil[ei]\\s+(?:alle|alla|allo|all\'|agli|ai|al|ad|a)\\s*|tipo\\s+|(?:sullo\\s+)?stile\\s+di\\s+|che\\s+ricordano\\s+|che\\s+assomigliano\\s+a\\s+)(.+?)\\s*\$',
        false,
      ),
      ('${prefix}come\\s+(.+?)\\s*\$', true),
    ];
    for (final (pattern, needsPrefix) in patterns) {
      final m = RegExp(pattern, caseSensitive: false).firstMatch(raw);
      if (m == null) continue;
      final kindWord = m.group(1)?.toLowerCase();
      if (needsPrefix && kindWord == null) continue;
      final title = (m.group(2) ?? '').trim().replaceAll(
        RegExp('^[ .,;:!?"“”«»]+|[ .,;:!?"“”«»]+\$'),
        '',
      );
      if (title.length < 2 || title.split(' ').length > 8) continue;
      IntentKind? kind;
      if (kindWord == 'film') kind = IntentKind.movie;
      if (kindWord != null &&
          (kindWord.startsWith('serie') || kindWord == 'telefilm')) {
        kind = IntentKind.series;
      }
      return (title: title, kind: kind);
    }
    return null;
  }

  static String _fold(String s) {
    const from = 'àáâäèéêëìíîïòóôöùúûüÀÁÂÄÈÉÊËÌÍÎÏÒÓÔÖÙÚÛÜ';
    const to = 'aaaaeeeeiiiioooouuuuaaaaeeeeiiiioooouuuu';
    final b = StringBuffer();
    for (final r in s.toLowerCase().runes) {
      final c = String.fromCharCode(r);
      final i = from.indexOf(c);
      b.write(i >= 0 ? to[i] : c);
    }
    return b.toString().replaceAll('’', "'");
  }

  ParsedQuery parse(String raw) {
    final similar = similarRequest(raw);
    if (similar != null) {
      return ParsedQuery(
        SearchIntent(
          kind: similar.kind,
          similarTo: similar.title,
          source: IntentSource.parser,
        ),
        const [],
      );
    }
    final intent = SearchIntent(source: IntentSource.parser);
    var text = ' ${_fold(raw)} ';
    final used = <String>{};

    void remove(String pattern) {
      text = text.replaceAll(RegExp(pattern), ' ');
    }

    int? firstInt(String pattern) {
      final m = RegExp(pattern).firstMatch(text);
      return m == null ? null : int.tryParse(m.group(1) ?? '');
    }

    // Anni espliciti e decenni.
    final to = firstInt(
      r'(?:prima del|entro il|fino al|fino a)\s+((?:19|20)\d{2})',
    );
    if (to != null) {
      intent.yearTo = to;
      remove(r'(?:prima del|entro il|fino al|fino a)\s+(?:19|20)\d{2}');
    }
    final from = firstInt(
      r'(?:dopo il|dal|a partire dal|da)\s+((?:19|20)\d{2})',
    );
    if (from != null) {
      intent.yearFrom = from;
      remove(r'(?:dopo il|dal|a partire dal|da)\s+(?:19|20)\d{2}');
    }
    final decade = firstInt(r"(?:anni|anni')\s*'?((?:19|20)?\d0)\b");
    if (decade != null) {
      final year = decade < 100
          ? (decade >= 30 ? 1900 + decade : 2000 + decade)
          : decade;
      intent.yearFrom = year;
      intent.yearTo = year + 9;
      remove(r"(?:anni|anni')\s*'?(?:19|20)?\d0\b");
    } else {
      for (final e in _decades.entries) {
        if (text.contains('anni ${e.key}') || text.contains("anni '${e.key}")) {
          intent.yearFrom = e.value;
          intent.yearTo = e.value + 9;
          remove("anni '?${e.key}");
          break;
        }
      }
    }
    if (intent.yearFrom == null && intent.yearTo == null) {
      final single = firstInt(r'\b((?:19|20)\d{2})\b');
      if (single != null) {
        intent.yearFrom = single;
        intent.yearTo = single;
        remove(r'\b(?:19|20)\d{2}\b');
      }
    }

    // Periodi relativi.
    if (intent.yearFrom == null) {
      if (text.contains('ultimi anni') ||
          text.contains('ultimi tempi') ||
          text.contains('negli ultimi')) {
        intent.yearFrom = currentYear - 5;
      } else if (text.contains('ultimo anno') ||
          text.contains("quest'anno") ||
          text.contains('questanno')) {
        intent.yearFrom = currentYear - 1;
      } else if (text.contains('recent') ||
          text.contains(' nuov') ||
          text.contains('ultime uscite') ||
          text.contains('appena usciti')) {
        intent.yearFrom = currentYear - 2;
      } else if (text.contains('classic') ||
          text.contains('vecchi') ||
          text.contains("d'altri tempi") ||
          text.contains('di una volta')) {
        intent.yearTo = 1995;
      } else if (text.contains('moderni') || text.contains('contemporane')) {
        intent.yearFrom = 2010;
      }
    }

    // Ordinamento.
    if (text.contains('famos') ||
        text.contains('popolar') ||
        text.contains('piu visti') ||
        text.contains('di successo') ||
        text.contains('noti')) {
      intent.sort = IntentSort.popularity;
    }
    if (text.contains('migliori') ||
        text.contains('capolavor') ||
        text.contains('top ') ||
        text.contains('meglio') ||
        text.contains('ben votat') ||
        text.contains('acclamat') ||
        text.contains('premiati')) {
      intent.sort = IntentSort.rating;
      intent.minRating = 7.0;
    }
    if (text.contains('cult')) {
      intent.sort = IntentSort.rating;
      intent.minRating = 6.5;
      intent.yearTo ??= currentYear - 12;
    }
    if (intent.sort == IntentSort.popularity &&
        (text.contains('ultime uscite') ||
            text.contains('novita') ||
            text.contains('appena usciti'))) {
      intent.sort = IntentSort.newest;
    }

    // Tipo.
    final wantsSeries =
        text.contains(' serie') ||
        text.contains(' telefilm') ||
        text.contains(' tv ') ||
        text.contains('stagion');
    final wantsMovie =
        text.contains(' film') ||
        text.contains(' movie') ||
        text.contains('lungometragg');
    if (wantsSeries && !wantsMovie) intent.kind = IntentKind.series;
    if (wantsMovie && !wantsSeries) intent.kind = IntentKind.movie;

    // Durata.
    if (text.contains('brevi') ||
        text.contains(' corti') ||
        text.contains('breve ') ||
        text.contains('veloci')) {
      intent.maxRuntime = 95;
    }

    // Generi e paesi.
    final words = text
        .split(RegExp(r"[^a-z0-9'\-]+"))
        .where((w) => w.isNotEmpty)
        .map((w) {
          if (w.startsWith("l'") ||
              w.startsWith("un'") ||
              w.startsWith("dell'")) {
            return w.substring(w.indexOf("'") + 1);
          }
          return w;
        })
        .toList();
    for (final entry in _genreStems.entries) {
      var matched = false;
      for (final word in words) {
        if (entry.value.any(word.startsWith)) {
          used.add(word);
          matched = true;
        }
      }
      if (matched && !intent.genres.contains(entry.key)) {
        intent.genres.add(entry.key);
      }
    }
    for (final (stem, keyword) in _keywordHints) {
      if (text.contains(stem) && !intent.keywords.contains(keyword)) {
        intent.keywords.add(keyword);
      }
    }
    for (final entry in _countryStems.entries) {
      for (final word in words) {
        if (entry.value.any(word.startsWith)) {
          used.add(word);
          if (!intent.countries.contains(entry.key)) {
            intent.countries.add(entry.key);
          }
        }
      }
    }

    final leftovers = [
      for (final w in words)
        if (w.length > 2 &&
            !used.contains(w) &&
            !_stopwords.contains(w) &&
            !RegExp(r'^\d+$').hasMatch(w))
          w,
    ];
    return ParsedQuery(intent, leftovers);
  }
}
