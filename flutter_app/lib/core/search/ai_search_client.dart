import 'dart:convert';

import 'package:dio/dio.dart';

import '../metadata/service_http.dart';
import '../util/lenient.dart';
import 'search_intent.dart';

/// Chi interpreta le frasi della ricerca avanzata (sempre un modello in rete con la chiave dell'utente).
enum AiProvider {
  anthropic('Claude (Anthropic)', 'claude-haiku-5-5'),
  openai('OpenAI', 'gpt-4o-mini'),
  google('Gemini (Google)', 'gemini-3.5-flash'),
  openrouter('OpenRouter', 'openai/gpt-4o-mini'),
  custom('Server compatibile OpenAI', '');

  const AiProvider(this.title, this.defaultModel);
  final String title;
  final String defaultModel;

  /// Il server accetta richieste senza chiave (solo quello personalizzato).
  bool get keyOptional => this == custom;

  static AiProvider fromName(String? n) =>
      values.firstWhere((p) => p.name == n, orElse: () => anthropic);
}

class AiSearchError implements Exception {
  const AiSearchError(this.message);
  final String message;

  static const notConfigured = AiSearchError(
    'Manca la chiave del modello scelto.',
  );
  static const invalidCredentials = AiSearchError(
    'Il servizio ha rifiutato la chiave: controllala.',
  );
  static const rateLimited = AiSearchError(
    'Troppe richieste o credito esaurito: riprova più tardi.',
  );
  static const badEndpoint = AiSearchError(
    'Indirizzo del server non valido (serve https).',
  );
  static const unavailable = AiSearchError(
    'Impossibile raggiungere il servizio: controlla la connessione.',
  );
  static const unreadable = AiSearchError(
    'Il modello ha risposto in modo non comprensibile.',
  );

  factory AiSearchError.server(int status, String? detail) {
    final d = detail == null ? '' : ': $detail';
    return switch (status) {
      404 => AiSearchError(
        'Modello non trovato per questa chiave (errore 404)$d. Scegline un altro dall\'elenco.',
      ),
      400 => AiSearchError(
        'Richiesta rifiutata (errore 400)$d. Prova un altro modello.',
      ),
      _ => AiSearchError('Il servizio ha risposto con un errore $status$d.'),
    };
  }

  @override
  String toString() => message;
}

/// Un modello che la chiave può usare.
class AiModelInfo {
  const AiModelInfo(this.id, this.name, {this.note});
  final String id;
  final String name;
  final String? note;
}

class AiConfig {
  const AiConfig({
    required this.provider,
    required this.model,
    this.customBase = '',
    this.timeoutSeconds = 15,
    this.count = 20,
    this.suggestTitles = true,
  });
  final AiProvider provider;
  final String model;
  final String customBase;
  final int timeoutSeconds;
  final int count;
  final bool suggestTitles;
}

/// Istruzioni e lettura della risposta, uguali per ogni modello.
class AiIntentCodec {
  static String systemPrompt(
    int year, {
    int count = 15,
    bool suggestTitles = true,
  }) {
    final genres = IntentGenre.values.map((g) => g.name).join(', ');
    var text =
        'You are an expert on films and TV series helping a user find something to watch. The user writes in Italian. '
        'Reply with ONE JSON object and nothing else, with these optional keys: '
        '"kind" ("movie" or "series", omit for both); '
        '"genres" (array, only from: $genres); '
        '"keywords" (array of 0-3 short English TMDB keywords such as "heist", "slasher", "parody"); '
        '"year_from" and "year_to" (integers); '
        '"sort" ("popularity", "rating", "newest" or "oldest"); '
        '"min_rating" (0-10); '
        '"countries" (array of ISO 3166-1 codes); '
        '"max_runtime" (minutes); '
        '"title" (only if the user names one specific title and wants that title itself); '
        '"similar_to" (the reference title when the user asks for titles similar to a specific film or series).';
    if (suggestTitles) {
      text +=
          ' Add "titles": an array of up to $count real titles that best answer the request, most relevant first, '
          'each as {"t": ORIGINAL title, "y": release year, "k": "m" for movie or "s" for series} (short keys, no extra fields). '
          'Use your knowledge: Italian release titles often differ from the original ones '
          '(e.g. "Ghost Movie" is the Italian title of "A Haunted House" (2013)), so identify the real title first and '
          'then recommend titles with the same genre, tone and style, not just titles that share a word. '
          'Never invent titles; leave "titles" out if you are not sure.';
    }
    text +=
        ' The current year is $year: "recent years" means the last 5 years. Never explain, never add text outside the JSON.';
    return text;
  }

  static String userPrompt(String query) => 'Richiesta: ${query.trim()}';

  /// Estrae l'intento dal testo del modello (accetta anche JSON dentro blocchi di codice o con testo attorno).
  static SearchIntent? parse(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      return null;
    }
    final o = asMap(decoded);
    if (o == null) return null;
    final intent = SearchIntent(source: IntentSource.ai);
    final kind = asString(o['kind'])?.toLowerCase();
    if (kind == 'movie' || kind == 'film') intent.kind = IntentKind.movie;
    if (kind == 'series' || kind == 'tv' || kind == 'show') {
      intent.kind = IntentKind.series;
    }
    for (final g in asList(o['genres'])) {
      final genre = IntentGenre.parse(asString(g) ?? '');
      if (genre != null && !intent.genres.contains(genre))
        intent.genres.add(genre);
    }
    for (final k in asList(o['keywords'])) {
      final w = asString(k)?.trim().toLowerCase();
      if (w != null && w.isNotEmpty && intent.keywords.length < 3) {
        intent.keywords.add(w);
      }
    }
    int? year(Object? v) {
      final n = asInt(v);
      return n != null && n >= 1900 && n <= 2100 ? n : null;
    }

    intent.yearFrom = year(o['year_from']);
    intent.yearTo = year(o['year_to']);
    final sort = asString(o['sort'])?.toLowerCase();
    for (final s in IntentSort.values) {
      if (s.name == sort) intent.sort = s;
    }
    final rating = asDouble(o['min_rating']);
    if (rating != null && rating > 0 && rating <= 10) intent.minRating = rating;
    for (final c in asList(o['countries'])) {
      final code = asString(c)?.toUpperCase();
      if (code != null && code.length == 2) intent.countries.add(code);
    }
    final runtime = asInt(o['max_runtime']);
    if (runtime != null && runtime > 20 && runtime < 400) {
      intent.maxRuntime = runtime;
    }
    for (final entry in asList(o['titles'])) {
      final d = asMap(entry);
      if (d == null) continue;
      final name = (asString(d['t']) ?? asString(d['title']))?.trim();
      if (name == null || name.isEmpty) continue;
      final y = asInt(d['y'] ?? d['year']);
      final type = (asString(d['k']) ?? asString(d['type']))?.toLowerCase();
      IntentKind? k;
      if (type == 'm' || type == 'movie' || type == 'film')
        k = IntentKind.movie;
      if (type == 's' || type == 'series' || type == 'tv' || type == 'show') {
        k = IntentKind.series;
      }
      final s = SuggestedTitle(
        name,
        year: y != null && y >= 1880 && y <= 2100 ? y : null,
        kind: k,
      );
      if (!intent.suggestions.contains(s)) intent.suggestions.add(s);
      if (intent.suggestions.length >= 40) break;
    }
    final similar = asString(o['similar_to'])?.trim();
    if (similar != null && similar.isNotEmpty) intent.similarTo = similar;
    final title = asString(o['title'])?.trim();
    if (title != null && title.isNotEmpty) intent.title = title;
    return intent.hasFilters || intent.title != null ? intent : null;
  }
}

/// Legge e ordina l'elenco dei modelli di ogni servizio: tiene solo quelli che sanno chattare e mette per primi i piccoli e veloci.
class AiModelCatalog {
  static const _cheap = [
    'haiku',
    'mini',
    'nano',
    'flash',
    'lite',
    'small',
    'instant',
  ];
  static const _excludedOpenAi = [
    'embedding',
    'whisper',
    'tts',
    'dall-e',
    'image',
    'audio',
    'realtime',
    'transcribe',
    'moderation',
    'davinci',
    'babbage',
    'search',
    'computer-use',
    'codex',
    'sora',
    'omni-moderation',
  ];
  static const _notText = [
    'image',
    'tts',
    'audio',
    'live',
    'embedding',
    'imagen',
    'veo',
    'robotics',
    'computer-use',
    'aqa',
    'learnlm',
    'vision',
  ];

  static String? note(String id) {
    final l = id.toLowerCase();
    return _cheap.any(l.contains) ? 'veloce ed economico' : null;
  }

  static List<AiModelInfo> parse(AiProvider provider, Object? body) {
    final o = asMap(body);
    if (o == null) return const [];
    final models = <AiModelInfo>[];
    switch (provider) {
      case AiProvider.anthropic:
        for (final e in asList(o['data'])) {
          final m = asMap(e);
          final id = asString(m?['id']);
          if (id == null) continue;
          models.add(
            AiModelInfo(id, asString(m?['display_name']) ?? id, note: note(id)),
          );
        }
      case AiProvider.openai:
        for (final e in asList(o['data'])) {
          final id = asString(asMap(e)?['id']);
          if (id == null) continue;
          final l = id.toLowerCase();
          final chat =
              l.startsWith('gpt-') ||
              l.startsWith('chatgpt') ||
              RegExp(r'^o[1-5]').hasMatch(l);
          if (!chat || _excludedOpenAi.any(l.contains)) continue;
          models.add(AiModelInfo(id, id, note: note(id)));
        }
      case AiProvider.google:
        for (final e in asList(o['models'])) {
          final m = asMap(e);
          final full = asString(m?['name']);
          if (full == null) continue;
          final id = full.startsWith('models/') ? full.substring(7) : full;
          final methods = asStringList(m?['supportedGenerationMethods']);
          final l = id.toLowerCase();
          if (!methods.contains('generateContent') ||
              !l.startsWith('gemini') ||
              _notText.any(l.contains)) {
            continue;
          }
          models.add(
            AiModelInfo(id, asString(m?['displayName']) ?? id, note: note(id)),
          );
        }
      case AiProvider.openrouter:
        for (final e in asList(o['data'])) {
          final m = asMap(e);
          final id = asString(m?['id']);
          if (id == null) continue;
          final out = asStringList(
            asMap(m?['architecture'])?['output_modalities'],
          );
          if (out.isNotEmpty && !out.contains('text')) continue;
          final pricing = asMap(m?['pricing']);
          final free =
              id.endsWith(':free') ||
              (asString(pricing?['prompt']) == '0' &&
                  asString(pricing?['completion']) == '0');
          models.add(
            AiModelInfo(
              id,
              asString(m?['name']) ?? id,
              note: free ? 'gratuito' : note(id),
            ),
          );
        }
      case AiProvider.custom:
        for (final e in asList(o['data'])) {
          final id = asString(asMap(e)?['id']);
          if (id != null) models.add(AiModelInfo(id, id));
        }
    }
    final seen = <String>{};
    final unique = [
      for (final m in models)
        if (seen.add(m.id)) m,
    ];
    return [
      ...unique.where((m) => m.note != null),
      ...unique.where((m) => m.note == null),
    ];
  }
}

/// Chiama il modello in rete scelto dall'utente con la sua chiave (letta dal Portachiavi a ogni richiesta).
class AiSearchClient {
  AiSearchClient({required this.keyFor, ServiceHttp? http})
    : _http = http ?? ServiceHttp(timeout: const Duration(seconds: 20));

  final Future<String?> Function(AiProvider) keyFor;
  final ServiceHttp _http;

  Future<List<AiModelInfo>> listModels(
    AiProvider provider,
    String customBase,
  ) async {
    final key = await keyFor(provider);
    if ((key == null || key.isEmpty) &&
        !provider.keyOptional &&
        provider != AiProvider.openrouter) {
      throw AiSearchError.notConfigured;
    }
    final uri = _listUri(provider, customBase);
    final r = await _http.send('ai', uri, headers: _headers(provider, key));
    if (r == null) throw AiSearchError.unavailable;
    if (!r.ok) throw _error(r.status, r.body);
    final models = AiModelCatalog.parse(provider, r.body);
    if (models.isEmpty) throw AiSearchError.unreadable;
    return models;
  }

  Future<SearchIntent> interpret(
    String query,
    AiConfig config,
    int year,
  ) async {
    final provider = config.provider;
    final key = await keyFor(provider);
    if ((key == null || key.isEmpty) && !provider.keyOptional) {
      throw AiSearchError.notConfigured;
    }
    if (config.model.isEmpty) throw AiSearchError.notConfigured;
    final system = AiIntentCodec.systemPrompt(
      year,
      count: config.count,
      suggestTitles: config.suggestTitles,
    );
    final user = AiIntentCodec.userPrompt(query);
    var r = await _post(config, key, system, user, thinkingOff: true);
    if (provider == AiProvider.google &&
        r != null &&
        r.status == 400 &&
        '${r.body}'.toLowerCase().contains('thinking')) {
      r = await _post(config, key, system, user, thinkingOff: false);
    }
    if (r == null) throw AiSearchError.unavailable;
    if (!r.ok) throw _error(r.status, r.body);
    final text = _answerText(provider, r.body);
    final intent = text == null ? null : AiIntentCodec.parse(text);
    if (intent == null) throw AiSearchError.unreadable;
    return intent;
  }

  /// Prova il modello con una frase breve; null se tutto va bene.
  Future<AiSearchError?> test(AiConfig config, int year) async {
    try {
      await interpret('film simili a Toy Story', config, year);
      return null;
    } on AiSearchError catch (e) {
      return e;
    }
  }

  Future<ServiceReply?> _post(
    AiConfig c,
    String? key,
    String system,
    String user, {
    required bool thinkingOff,
  }) {
    final uri = _chatUri(c);
    final Map<String, Object?> body;
    switch (c.provider) {
      case AiProvider.anthropic:
        body = {
          'model': c.model,
          'max_tokens': 2000,
          'system': system,
          'messages': [
            {'role': 'user', 'content': user},
          ],
        };
      case AiProvider.google:
        body = {
          'systemInstruction': {
            'parts': [
              {'text': system},
            ],
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': user},
              ],
            },
          ],
          'generationConfig': googleGenerationConfig(
            c.model,
            thinking: thinkingOff,
          ),
        };
      case AiProvider.openai:
        body = {
          'model': c.model,
          'response_format': {'type': 'json_object'},
          'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': user},
          ],
        };
      case AiProvider.openrouter || AiProvider.custom:
        body = {
          'model': c.model,
          'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': user},
          ],
        };
    }
    return _http.send(
      'ai',
      uri,
      method: 'POST',
      headers: _headers(c.provider, key),
      data: body,
      contentType: Headers.jsonContentType,
    );
  }

  /// Il ragionamento allunga la risposta e per elencare titoli non serve: la serie 2.5 usa un budget di token, la serie 3 un livello.
  /// I modelli Pro non permettono di spegnerlo.
  static Map<String, Object?> googleGenerationConfig(
    String model, {
    bool thinking = true,
  }) {
    final config = <String, Object?>{'responseMimeType': 'application/json'};
    if (!thinking) return config;
    final l = model.toLowerCase();
    if (l.contains('pro')) return config;
    if (l.contains('2.5-flash')) {
      config['thinkingConfig'] = {'thinkingBudget': 0};
    } else if (l.startsWith('gemini-3')) {
      config['thinkingConfig'] = {'thinkingLevel': 'minimal'};
    }
    return config;
  }

  static Map<String, String> _headers(AiProvider p, String? key) {
    final k = key ?? '';
    return switch (p) {
      AiProvider.anthropic => {
        'x-api-key': k,
        'anthropic-version': '2023-06-01',
      },
      AiProvider.google => {'x-goog-api-key': k},
      AiProvider.openrouter ||
      AiProvider.openai ||
      AiProvider.custom => {if (k.isNotEmpty) 'Authorization': 'Bearer $k'},
    };
  }

  static Uri _base(String custom) {
    final t = custom.trim().replaceAll(RegExp(r'/+$'), '');
    final u = Uri.tryParse(t);
    if (u == null || u.scheme.toLowerCase() != 'https' || u.host.isEmpty) {
      throw AiSearchError.badEndpoint;
    }
    return u;
  }

  static Uri _listUri(AiProvider p, String custom) => switch (p) {
    AiProvider.anthropic => Uri.parse(
      'https://api.anthropic.com/v1/models?limit=1000',
    ),
    AiProvider.openai => Uri.parse('https://api.openai.com/v1/models'),
    AiProvider.openrouter => Uri.parse('https://openrouter.ai/api/v1/models'),
    AiProvider.google => Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models?pageSize=200',
    ),
    AiProvider.custom => Uri.parse('${_base(custom)}/models'),
  };

  static Uri _chatUri(AiConfig c) => switch (c.provider) {
    AiProvider.anthropic => Uri.parse('https://api.anthropic.com/v1/messages'),
    AiProvider.openai => Uri.parse(
      'https://api.openai.com/v1/chat/completions',
    ),
    AiProvider.openrouter => Uri.parse(
      'https://openrouter.ai/api/v1/chat/completions',
    ),
    AiProvider.google => Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/${Uri.encodeComponent(c.model)}:generateContent',
    ),
    AiProvider.custom => Uri.parse('${_base(c.customBase)}/chat/completions'),
  };

  static String? _answerText(AiProvider p, Object? body) {
    final o = asMap(body);
    if (o == null) return null;
    switch (p) {
      case AiProvider.anthropic:
        return asList(o['content'])
            .map((b) => asString(asMap(b)?['text']))
            .whereType<String>()
            .join('\n');
      case AiProvider.google:
        final c = asMap(asList(o['candidates']).firstOrNull);
        final parts = asList(asMap(c?['content'])?['parts']);
        return parts
            .map((b) => asString(asMap(b)?['text']))
            .whereType<String>()
            .join('\n');
      case AiProvider.openai || AiProvider.openrouter || AiProvider.custom:
        final c = asMap(asList(o['choices']).firstOrNull);
        return asString(asMap(c?['message'])?['content']);
    }
  }

  /// Traduce una risposta di errore (senza mai riportare la chiave) nel messaggio giusto.
  static AiSearchError _error(int status, Object? body) {
    final e = asMap(asMap(body)?['error']);
    final raw = asString(e?['message']);
    final detail = raw == null
        ? null
        : (raw.replaceAll('\n', ' ').length > 160
              ? raw.replaceAll('\n', ' ').substring(0, 160)
              : raw.replaceAll('\n', ' '));
    final l = (detail ?? '').toLowerCase();
    if (status == 401) return AiSearchError.invalidCredentials;
    if (status == 400 &&
        (l.contains('api key not valid') ||
            l.contains('api_key_invalid') ||
            l.contains('invalid api key'))) {
      return AiSearchError.invalidCredentials;
    }
    if (status == 403 &&
        (l.contains('api key') || l.contains('permission')) &&
        !l.contains('location')) {
      return AiSearchError.invalidCredentials;
    }
    if (status == 402 || status == 429) return AiSearchError.rateLimited;
    return AiSearchError.server(status, detail);
  }
}
