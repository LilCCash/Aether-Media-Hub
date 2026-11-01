import 'package:flutter_test/flutter_test.dart';
import 'package:aether_flutter/core/search/advanced_search_engine.dart';
import 'package:aether_flutter/core/search/ai_search_client.dart';
import 'package:aether_flutter/core/search/natural_query_parser.dart';
import 'package:aether_flutter/core/search/search_intent.dart';

void main() {
  final parser = NaturalQueryParser(currentYear: 2026);

  test('funny recent movies', () {
    final out = parser.parse('film divertenti degli ultimi anni');
    expect(out.intent.kind, IntentKind.movie);
    expect(out.intent.genres, [IntentGenre.comedy]);
    expect(out.intent.yearFrom, 2021);
  });

  test('silly famous comedies', () {
    final out = parser.parse('commedie demenziali famose');
    expect(out.intent.genres, [IntentGenre.comedy]);
    expect(out.intent.keywords, contains('slapstick'));
    expect(out.intent.sort, IntentSort.popularity);
  });

  test('decade and country', () {
    final out = parser.parse('horror italiani anni 80');
    expect(out.intent.genres, [IntentGenre.horror]);
    expect(out.intent.countries, ['IT']);
    expect(out.intent.yearFrom, 1980);
    expect(out.intent.yearTo, 1989);
  });

  test('best series sets a rating', () {
    final out = parser.parse('migliori serie thriller');
    expect(out.intent.kind, IntentKind.series);
    expect(out.intent.sort, IntentSort.rating);
    expect(out.intent.minRating, isNotNull);
  });

  test('a plain title has no filters', () {
    final out = parser.parse('Inception');
    expect(out.intent.hasFilters, isFalse);
    expect(out.leftovers, ['inception']);
  });

  test('similar to', () {
    final a = parser.parse('film simili a Toy Story');
    expect(a.intent.similarTo, 'Toy Story');
    expect(a.intent.kind, IntentKind.movie);
    expect(
      parser.parse('film tipo Scary Movie').intent.similarTo,
      'Scary Movie',
    );
    final c = parser.parse('serie come Lost');
    expect(c.intent.similarTo, 'Lost');
    expect(c.intent.kind, IntentKind.series);
    expect(parser.parse('come eravamo').intent.similarTo, isNull);
  });

  test('AI answer: filters and suggested titles', () {
    final intent = AiIntentCodec.parse(
      '```json\n{"kind":"movie","genres":["comedy","Horror"],"keywords":["Parody"],"year_from":2018,"sort":"rating","countries":["it"],'
      '"similar_to":"A Haunted House","titles":[{"t":"Scary Movie","y":2000,"k":"m"},{"title":"Lost","year":2004,"type":"series"},{"t":""}]}\n```',
    );
    expect(intent, isNotNull);
    expect(intent!.kind, IntentKind.movie);
    expect(intent.genres, [IntentGenre.comedy, IntentGenre.horror]);
    expect(intent.keywords, ['parody']);
    expect(intent.yearFrom, 2018);
    expect(intent.sort, IntentSort.rating);
    expect(intent.countries, ['IT']);
    expect(intent.similarTo, 'A Haunted House');
    expect(intent.suggestions, [
      const SuggestedTitle('Scary Movie', year: 2000, kind: IntentKind.movie),
      const SuggestedTitle('Lost', year: 2004, kind: IntentKind.series),
    ]);
    expect(AiIntentCodec.parse('non lo so'), isNull);
  });

  test('prompt carries the count and can leave titles out', () {
    expect(AiIntentCodec.systemPrompt(2026, count: 12), contains('up to 12'));
    expect(
      AiIntentCodec.systemPrompt(2026, suggestTitles: false),
      isNot(contains('"titles"')),
    );
  });

  test('model lists are filtered and the cheap ones come first', () {
    final anthropic = AiModelCatalog.parse(AiProvider.anthropic, {
      'data': [
        {'id': 'claude-sonnet-5-5', 'display_name': 'Claude Sonnet 5.5'},
        {'id': 'claude-haiku-5-5', 'display_name': 'Claude Haiku 5.5'},
      ],
    });
    expect(anthropic.map((m) => m.id), [
      'claude-haiku-5-5',
      'claude-sonnet-5-5',
    ]);
    expect(anthropic.first.note, 'veloce ed economico');
    final openai = AiModelCatalog.parse(AiProvider.openai, {
      'data': [
        {'id': 'text-embedding-3-small'},
        {'id': 'gpt-4o'},
        {'id': 'gpt-4o-mini'},
        {'id': 'whisper-1'},
      ],
    });
    expect(openai.map((m) => m.id), ['gpt-4o-mini', 'gpt-4o']);
    final google = AiModelCatalog.parse(AiProvider.google, {
      'models': [
        {
          'name': 'models/gemini-3.5-flash',
          'supportedGenerationMethods': ['generateContent'],
        },
        {
          'name': 'models/gemini-2.5-flash-image',
          'supportedGenerationMethods': ['generateContent'],
        },
        {
          'name': 'models/embedding-001',
          'supportedGenerationMethods': ['embedContent'],
        },
      ],
    });
    expect(google.map((m) => m.id), ['gemini-3.5-flash']);
    final router = AiModelCatalog.parse(AiProvider.openrouter, {
      'data': [
        {'id': 'a/b:free', 'name': 'B'},
        {
          'id': 'c/d',
          'name': 'D',
          'architecture': {
            'output_modalities': ['image'],
          },
        },
      ],
    });
    expect(router.map((m) => m.id), ['a/b:free']);
    expect(router.first.note, 'gratuito');
  });

  test('Gemini thinking is turned down per generation', () {
    expect(
      AiSearchClient.googleGenerationConfig(
        'gemini-2.5-flash',
      )['thinkingConfig'],
      isNotNull,
    );
    expect(
      AiSearchClient.googleGenerationConfig(
        'gemini-3.1-flash-lite',
      )['thinkingConfig'],
      {'thinkingLevel': 'minimal'},
    );
    expect(
      AiSearchClient.googleGenerationConfig('gemini-3-pro')['thinkingConfig'],
      isNull,
    );
    expect(
      AiSearchClient.googleGenerationConfig(
        'gemini-3.1-flash-lite',
        thinking: false,
      )['thinkingConfig'],
      isNull,
    );
  });

  test('timing log round trip', () {
    final log = SearchTimingLog();
    log.add(
      TimingEntry(
        query: 'q',
        interpreter: 'parser locale',
        total: 1.5,
        phases: const [],
        results: 3,
        notes: const ['n'],
      ),
    );
    expect(log.entries.length, 1);
    final restored = TimingEntry.fromJson(log.entries.first.toJson());
    expect(restored?.query, 'q');
    expect(restored?.results, 3);
    expect(log.text(), contains('«q»'));
    log.clear();
    expect(log.entries, isEmpty);
  });
}
