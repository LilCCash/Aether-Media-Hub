import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/stores.dart';
import '../metadata/tmdb_client.dart';
import '../model/meta.dart';
import '../util/lenient.dart';
import 'advanced_search_service.dart';
import 'ai_search_client.dart';
import 'natural_query_parser.dart';
import 'search_intent.dart';

/// Tutte le scelte della scheda «Ricerca avanzata», lette dalle impostazioni.
class AdvancedConfig {
  const AdvancedConfig({
    this.enabled = false,
    this.keywordSearch = true,
    this.naturalParser = true,
    this.aiEnabled = false,
    this.aiSuggestsTitles = true,
    this.provider = AiProvider.anthropic,
    this.model = '',
    this.customBase = '',
    this.aiOnSubmit = true,
    this.aiAlways = true,
    this.aiTimeout = 15,
    this.kinds = 'both',
    this.maxResults = 20,
    this.minVotes = 300,
    this.showInterpretation = true,
    this.showSource = true,
    this.includeAdult = false,
    this.rememberInterpretations = true,
    this.logTimings = true,
    this.language = 'it-IT',
  });

  final bool enabled;
  final bool keywordSearch;
  final bool naturalParser;
  final bool aiEnabled;
  final bool aiSuggestsTitles;
  final AiProvider provider;
  final String model;
  final String customBase;
  final bool aiOnSubmit;
  final bool aiAlways;
  final int aiTimeout;
  final String kinds;
  final int maxResults;
  final int minVotes;
  final bool showInterpretation;
  final bool showSource;
  final bool includeAdult;
  final bool rememberInterpretations;
  final bool logTimings;
  final String language;

  bool get hasAnyLevel =>
      enabled && (keywordSearch || naturalParser || aiEnabled);

  AiConfig get ai => AiConfig(
    provider: provider,
    model: model,
    customBase: customBase,
    timeoutSeconds: aiTimeout,
    count: maxResults,
    suggestTitles: aiSuggestsTitles,
  );

  AdvancedOptions get options => AdvancedOptions(
    kinds: kinds,
    maxResults: maxResults,
    minVotes: minVotes,
    includeAdult: includeAdult,
    keywordSearch: keywordSearch,
    language: language,
  );

  @override
  bool operator ==(Object other) =>
      other is AdvancedConfig &&
      other.enabled == enabled &&
      other.keywordSearch == keywordSearch &&
      other.naturalParser == naturalParser &&
      other.aiEnabled == aiEnabled &&
      other.aiSuggestsTitles == aiSuggestsTitles &&
      other.provider == provider &&
      other.model == model &&
      other.customBase == customBase &&
      other.aiOnSubmit == aiOnSubmit &&
      other.aiAlways == aiAlways &&
      other.kinds == kinds &&
      other.maxResults == maxResults &&
      other.minVotes == minVotes &&
      other.includeAdult == includeAdult &&
      other.language == language;

  @override
  int get hashCode => Object.hash(
    enabled,
    keywordSearch,
    naturalParser,
    aiEnabled,
    aiSuggestsTitles,
    provider,
    model,
    customBase,
    aiOnSubmit,
    aiAlways,
    kinds,
    Object.hash(maxResults, minVotes, includeAdult, language),
  );
}

class AdvancedResult {
  const AdvancedResult(this.intent, this.items, this.notes);
  final SearchIntent? intent;
  final List<MetaItem> items;
  final List<String> notes;
}

/// Una ricerca avanzata e il tempo di ogni sua fase.
class TimingEntry {
  TimingEntry({
    required this.query,
    required this.interpreter,
    required this.total,
    required this.phases,
    required this.results,
    required this.notes,
    DateTime? date,
  }) : date = date ?? DateTime.now();

  final DateTime date;
  final String query;
  final String interpreter;
  final double total;
  final List<PhaseTiming> phases;
  final int results;
  final List<String> notes;

  Map<String, Object?> toJson() => {
    'date': date.millisecondsSinceEpoch,
    'query': query,
    'interpreter': interpreter,
    'total': total,
    'phases': [for (final p in phases) p.toJson()],
    'results': results,
    'notes': notes,
  };

  static TimingEntry? fromJson(Object? v) {
    final m = asMap(v);
    final query = asString(m?['query']);
    final total = asDouble(m?['total']);
    if (m == null || query == null || total == null) return null;
    return TimingEntry(
      date: DateTime.fromMillisecondsSinceEpoch(asInt(m['date']) ?? 0),
      query: query,
      interpreter: asString(m['interpreter']) ?? '',
      total: total,
      phases: [for (final p in asList(m['phases'])) ?PhaseTiming.fromJson(p)],
      results: asInt(m['results']) ?? 0,
      notes: asStringList(m['notes']),
    );
  }
}

/// Registro dei tempi della ricerca avanzata (Impostazioni ▸ Ricerca avanzata ▸ Registro dei tempi). Resta sul telefono.
class SearchTimingLog extends ChangeNotifier {
  static const _key = 'search.timings.v1';
  static const limit = 40;
  List<TimingEntry> entries = [];
  KeyValueStore? _store;

  Future<void> attach(KeyValueStore store) async {
    _store = store;
    try {
      final raw = await store.read(_key);
      if (raw != null) {
        entries = [
          for (final e in asList(jsonDecode(raw))) ?TimingEntry.fromJson(e),
        ];
        notifyListeners();
      }
    } on Object {
      entries = [];
    }
  }

  void add(TimingEntry e) {
    entries = [e, ...entries].take(limit).toList();
    notifyListeners();
    _persist();
  }

  void clear() {
    entries = [];
    notifyListeners();
    _persist();
  }

  void _persist() {
    final s = _store;
    if (s != null) {
      unawaited(
        s.write(_key, jsonEncode([for (final e in entries) e.toJson()])),
      );
    }
  }

  /// Il registro come testo, da copiare e mandare.
  String text() => entries
      .map((e) {
        final d = e.date;
        String two(int n) => n.toString().padLeft(2, '0');
        final lines = <String>[
          '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)} · «${e.query}» · ${e.total.toStringAsFixed(2)} s · ${e.results} risultati · ${e.interpreter}',
          for (final p in e.phases)
            '  - ${p.name}: ${p.seconds.toStringAsFixed(2)} s${p.detail == null ? '' : ' (${p.detail})'}',
          for (final n in e.notes) '  ! $n',
        ];
        return lines.join('\n');
      })
      .join('\n\n');
}

ServiceKey aiServiceKey(AiProvider p) => switch (p) {
  AiProvider.anthropic => ServiceKey.aiAnthropic,
  AiProvider.openai => ServiceKey.aiOpenai,
  AiProvider.google => ServiceKey.aiGoogle,
  AiProvider.openrouter => ServiceKey.aiOpenrouter,
  AiProvider.custom => ServiceKey.aiCustom,
};

/// Mette insieme i livelli della ricerca avanzata: parole chiave TMDB, parser locale e modelli AI in rete.
class AdvancedSearchEngine {
  AdvancedSearchEngine({
    required TmdbClient tmdb,
    required SecretStore secrets,
    required KeyValueStore store,
  }) : service = AdvancedSearchService(tmdb),
       ai = AiSearchClient(keyFor: (p) => secrets.serviceKey(aiServiceKey(p))) {
    unawaited(log.attach(store));
  }

  final AdvancedSearchService service;
  final AiSearchClient ai;
  final SearchTimingLog log = SearchTimingLog();
  final Map<String, SearchIntent> _cache = {};

  void clearCache() {
    _cache.clear();
    service.clearCache();
  }

  /// [submitted]: l'utente ha premuto «Cerca» (serve per l'AI quando è impostata su «premendo Cerca»).
  Future<AdvancedResult> search(
    String query,
    AdvancedConfig c, {
    required bool submitted,
  }) async {
    if (!c.hasAnyLevel) return const AdvancedResult(null, [], []);
    if (!await service.isAvailable) {
      return const AdvancedResult(null, [], [
        'La ricerca avanzata usa TMDB: inserisci la chiave in Impostazioni ▸ Servizi.',
      ]);
    }
    final total = Stopwatch()..start();
    final phases = <PhaseTiming>[];
    var interpreter = 'parser locale';
    final notes = <String>[];
    final year = DateTime.now().year;
    final parseSw = Stopwatch()..start();
    final parser = NaturalQueryParser(currentYear: year);
    final parsed = c.naturalParser ? parser.parse(query) : null;
    SearchIntent? intent = (parsed?.intent.hasFilters ?? false)
        ? parsed!.intent
        : null;
    phases.add(
      PhaseTiming('Parser locale', parseSw.elapsedMilliseconds / 1000),
    );

    final aiAllowed = c.aiEnabled && (submitted || !c.aiOnSubmit);
    // «Simili a…»: il parser sa solo cercare il titolo; l'AI sa davvero quali titoli gli somigliano.
    final aiKnowsSimilar = c.aiSuggestsTitles && intent?.similarTo != null;
    final wantsAi =
        aiAllowed && (c.aiAlways || intent == null || aiKnowsSimilar);
    if (wantsAi) {
      final sw = Stopwatch()..start();
      final r = await _askAi(query, c, year);
      phases.add(
        PhaseTiming(
          'Interpretazione AI · ${r.via}',
          sw.elapsedMilliseconds / 1000,
          detail: r.intent == null
              ? 'nessuna risposta'
              : '${r.intent!.suggestions.length} titoli proposti',
        ),
      );
      if (r.intent != null) {
        intent = r.intent;
        interpreter = r.via;
      }
      notes.addAll(r.notes);
    } else if (c.aiEnabled && !aiAllowed && intent == null) {
      notes.add(
        'Premi «Cerca» sulla tastiera per far interpretare la frase dal modello AI.',
      );
    }

    final leftovers = c.keywordSearch
        ? (parsed?.leftovers ?? parser.parse(query).leftovers).take(3).toList()
        : <String>[];
    if (intent == null) {
      if (leftovers.isEmpty) {
        _record(c, query, interpreter, total, phases, 0, notes);
        return AdvancedResult(null, const [], notes);
      }
      intent = SearchIntent(source: IntentSource.keyword)
        ..keywords.addAll(leftovers);
    }
    final extra = intent.source == IntentSource.keyword
        ? <String>[]
        : leftovers;
    final outcome = await service.run(intent, extra, c.options);
    notes.addAll(outcome.notes);
    phases.addAll(outcome.timings);
    _record(c, query, interpreter, total, phases, outcome.items.length, notes);
    return AdvancedResult(intent, outcome.items, notes);
  }

  void _record(
    AdvancedConfig c,
    String query,
    String interpreter,
    Stopwatch total,
    List<PhaseTiming> phases,
    int results,
    List<String> notes,
  ) {
    if (!c.logTimings) return;
    log.add(
      TimingEntry(
        query: query,
        interpreter: interpreter,
        total: total.elapsedMilliseconds / 1000,
        phases: phases,
        results: results,
        notes: [...notes],
      ),
    );
  }

  Future<({SearchIntent? intent, List<String> notes, String via})> _askAi(
    String query,
    AdvancedConfig c,
    int year,
  ) async {
    final key =
        '${query.toLowerCase()}|${c.aiSuggestsTitles}|${c.maxResults}|${c.provider.name}|${c.model}';
    if (c.rememberInterpretations) {
      final hit = _cache[key];
      if (hit != null)
        return (intent: hit, notes: const <String>[], via: 'memoria');
    }
    final notes = <String>[];
    SearchIntent? found;
    var via = 'nessuno';
    try {
      found = await ai.interpret(query, c.ai, year);
      via = '${c.provider.title} (${c.model})';
    } on AiSearchError catch (e) {
      notes.add('${c.provider.title}: ${e.message}');
    }
    if (found != null && c.rememberInterpretations) _cache[key] = found;
    return (intent: found, notes: notes, via: via);
  }
}
