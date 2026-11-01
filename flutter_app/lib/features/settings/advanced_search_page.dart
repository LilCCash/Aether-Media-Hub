import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/search/advanced_search_engine.dart';
import '../../core/search/ai_search_client.dart';
import '../../core/search/natural_query_parser.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';
import '../../data/stores.dart';
import '../../design/tokens.dart';
import 'settings_extra.dart';
import 'settings_widgets.dart';

/// Impostazioni ▸ Ricerca avanzata: parole chiave, frasi in italiano e modelli di intelligenza artificiale (con la chiave dell'utente).
class AdvancedSearchSettingsPage extends ConsumerStatefulWidget {
  const AdvancedSearchSettingsPage({super.key});

  @override
  ConsumerState<AdvancedSearchSettingsPage> createState() =>
      _AdvancedSearchSettingsPageState();
}

class _AdvancedSearchSettingsPageState
    extends ConsumerState<AdvancedSearchSettingsPage> {
  final _sample = TextEditingController(
    text: 'film divertenti degli ultimi anni',
  );
  final _keyField = TextEditingController();
  final _baseField = TextEditingController();
  List<AiModelInfo> _models = const [];
  String? _modelsStatus;
  bool _modelsOk = false;
  bool _busy = false;
  String? _testStatus;
  bool _testOk = false;
  bool _keySaved = false;
  bool _tmdbKey = false;
  AiProvider? _loadedFor;

  @override
  void initState() {
    super.initState();
    _baseField.text = ref.read(settingsProvider).advCustomBase;
    unawaited(_refreshKeyState());
  }

  @override
  void dispose() {
    _sample.dispose();
    _keyField.dispose();
    _baseField.dispose();
    super.dispose();
  }

  AiProvider get _provider => ref.read(settingsProvider).advProvider;

  Future<void> _refreshKeyState() async {
    final secrets = ref.read(servicesProvider).secrets;
    final p = _provider;
    final saved =
        ((await secrets.serviceKey(aiServiceKey(p))) ?? '').isNotEmpty;
    final tmdb = ((await secrets.serviceKey(ServiceKey.tmdb)) ?? '').isNotEmpty;
    if (!mounted) return;
    setState(() {
      _keySaved = saved;
      _tmdbKey = tmdb;
    });
    if (_loadedFor != p &&
        (saved || p.keyOptional || p == AiProvider.openrouter)) {
      _loadedFor = p;
      unawaited(_loadModels(auto: true));
    }
  }

  Future<void> _loadModels({required bool auto}) async {
    final p = _provider;
    if (!_keySaved && !p.keyOptional && p != AiProvider.openrouter) {
      if (!auto) setState(() => _modelsStatus = 'Prima salva la chiave.');
      return;
    }
    setState(() => _busy = true);
    try {
      final list = await ref
          .read(advancedEngineProvider)
          .ai
          .listModels(p, ref.read(settingsProvider).advCustomBase);
      if (!mounted || p != _provider) return;
      final cfg = ref.read(settingsProvider);
      setState(() {
        _models = list;
        _modelsOk = true;
        _modelsStatus = _keySaved
            ? 'Chiave valida: ${list.length} modelli disponibili con il tuo piano.'
            : '${list.length} modelli disponibili.';
      });
      // Se il modello scelto non è più disponibile con questo piano, si propone il primo consigliato.
      if (!list.any((m) => m.id == cfg.advModel(p))) {
        final preferred =
            list.where((m) => m.id == p.defaultModel).firstOrNull ?? list.first;
        ref
            .read(settingsProvider.notifier)
            .update((x) => x.withAdvModel(p, preferred.id));
      }
    } on AiSearchError catch (e) {
      if (!mounted) return;
      setState(() {
        _models = const [];
        _modelsOk = false;
        _modelsStatus = auto ? null : e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveKey() async {
    final p = _provider;
    await ref
        .read(servicesProvider)
        .secrets
        .setServiceKey(aiServiceKey(p), _keyField.text);
    _keyField.clear();
    _loadedFor = null;
    await _refreshKeyState();
  }

  Future<void> _removeKey() async {
    await ref
        .read(servicesProvider)
        .secrets
        .setServiceKey(aiServiceKey(_provider), null);
    setState(() {
      _models = const [];
      _modelsStatus = null;
      _modelsOk = false;
    });
    _loadedFor = null;
    await _refreshKeyState();
  }

  Future<void> _runTest() async {
    setState(() {
      _busy = true;
      _testStatus = null;
    });
    final cfg = ref.read(settingsProvider).advancedConfig;
    final error = await ref
        .read(advancedEngineProvider)
        .ai
        .test(cfg.ai, DateTime.now().year);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _testOk = error == null;
      _testStatus = error == null ? 'Il modello risponde.' : error.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final p = s.advProvider;
    final n = ref.read(settingsProvider.notifier);
    final model = s.advModel(p);
    return SettingsPageFrame(
      title: 'Ricerca avanzata',
      children: [
        SettingsGroup(
          footer: 'Scrivi cosa ti va di vedere («commedie demenziali famose», «horror italiani anni 80», «film simili a Toy Story») e Aether lo trasforma in filtri e titoli. I risultati compaiono in cima alla scheda Cerca. Serve la chiave TMDB (Impostazioni ▸ Servizi); il resto dipende dai livelli scelti qui sotto.',
          children: [
            const PrefSwitch(
              'advSearch',
              'Attiva la ricerca avanzata',
              _enabled,
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: const Text('Chiave TMDB'),
              trailing: Text(
                _tmdbKey ? 'Presente' : 'Mancante',
                style: TextStyle(
                  color: _tmdbKey ? AetherTokens.success : AetherTokens.warning,
                ),
              ),
            ),
          ],
        ),
        if (s.advSearch) ...[
          const SettingsGroup(
            title: 'Livelli di ricerca',
            footer: 'Si possono accendere insieme: il parser lavora per primo; l\'AI interviene secondo la regola scelta più sotto; le parole chiave completano ciò che resta.',
            children: [
              PrefSwitch(
                'advKeyword',
                '1 · Parole chiave',
                _keyword,
                subtitle: 'Cerca anche per tema («slasher», «heist», «viaggi nel tempo») con le parole chiave di TMDB. Gratis.',
              ),
              PrefSwitch(
                'advParser',
                '2 · Frasi in italiano (parser)',
                _parser,
                subtitle: 'Capisce in locale generi, anni, decenni, paesi e ordinamento («ultimi anni», «anni 80», «italiani», «migliori»). Gratis, senza AI.',
              ),
              PrefSwitch(
                'advAi',
                '3 · Intelligenza artificiale',
                _ai,
                subtitle: 'Capisce frasi libere e propone i titoli. Usa un modello in rete con la tua chiave.',
              ),
            ],
          ),
          if (s.advParser) _parserTry(),
          if (s.advAi) ...[
            _providerGroup(s, p, n),
            _keyGroup(p),
            _modelGroup(p, model, n),
            SettingsGroup(
              title: 'Quando usare l\'AI',
              footer: '«Premendo Cerca» fa una sola richiesta per ricerca (meno consumo di chiave). «Solo se il parser non capisce» risparmia richieste. Con «L\'AI propone i titoli» sceglie lei i titoli (poi ritrovati su TMDB); senza, traduce solo la frase in filtri.',
              children: const [
                PrefSwitch('advSuggest', 'L\'AI propone i titoli', _suggest),
                PrefChoice<String>('advTrigger', 'Interroga l\'AI', _trigger, {
                  'submit': 'Premendo Cerca',
                  'typing': 'Mentre scrivo',
                }),
                PrefChoice<String>('advMode', 'Intervento dell\'AI', _mode, {
                  'always': 'Sempre',
                  'fallback': 'Solo se il parser non capisce',
                }),
                PrefSlider(
                  'advTimeout',
                  'Attesa massima',
                  _timeout,
                  min: 5,
                  max: 60,
                  divisions: 11,
                  integer: true,
                  format: _secFmt,
                ),
              ],
            ),
          ],
          SettingsGroup(
            title: 'Risultati',
            footer: 'Per sapere quali titoli sono «migliori» Aether ignora quelli con pochissimi voti: alza il numero per essere più selettivo. Ricordare le frasi evita di richiamare l\'AI per la stessa ricerca.',
            children: [
              const PrefChoice<String>('advKinds', 'Cerca tra', _kinds, {
                'both': 'Film e serie',
                'movie': 'Solo film',
                'series': 'Solo serie',
              }),
              const PrefSlider(
                'advMax',
                'Risultati',
                _max,
                min: 5,
                max: 40,
                divisions: 7,
                integer: true,
                format: _intFmt,
              ),
              const PrefSlider(
                'advMinVotes',
                'Voti minimi per «migliori»',
                _votes,
                min: 0,
                max: 5000,
                divisions: 50,
                integer: true,
                format: _intFmt,
              ),
              const PrefSwitch(
                'advShowInterpretation',
                'Mostra come ho letto la frase',
                _showInterp,
              ),
              const PrefSwitch(
                'advShowSource',
                'Mostra chi l\'ha interpretata',
                _showSource,
              ),
              const PrefSwitch(
                'advAdult',
                'Includi contenuti per adulti',
                _adult,
              ),
              const PrefSwitch(
                'advRemember',
                'Ricorda le frasi già interpretate',
                _remember,
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('Svuota le frasi ricordate'),
                textColor: AetherTokens.warning,
                onTap: () => ref.read(advancedEngineProvider).clearCache(),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Velocità',
            footer: 'Per ogni ricerca segna quanto ci hanno messo l\'AI e TMDB, fase per fase: così si vede chi è lento. Il registro resta sul telefono (ultime 40 ricerche) e si può copiare. Aether ricorda anche i titoli già ritrovati, quindi le ricerche ripetute sono più veloci.',
            children: [
              const PrefSwitch('advLog', 'Registra i tempi', _log),
              NavRow(
                icon: Icons.speed_rounded,
                title: 'Registro dei tempi',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SearchTimingLogPage(),
                  ),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Esempi',
            children: [
              for (final e in const [
                'film divertenti degli ultimi anni',
                'commedie demenziali famose',
                'horror italiani anni 80',
                'migliori serie thriller',
                'film simili a Toy Story',
              ])
                ListTile(
                  dense: true,
                  title: Text(
                    '«$e»',
                    style: const TextStyle(
                      color: AetherTokens.textTertiary,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _parserTry() {
    final out = NaturalQueryParser().parse(_sample.text);
    final intent = out.intent;
    return SettingsGroup(
      title: 'Prova il parser',
      footer: 'Mostra come Aether legge la frase, senza fare ricerche.',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _sample,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Scrivi una frase'),
          ),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: Icon(
            intent.hasFilters
                ? Icons.check_circle_rounded
                : Icons.help_outline_rounded,
            color: intent.hasFilters
                ? AetherTokens.success
                : AetherTokens.textTertiary,
          ),
          title: Text(
            intent.hasFilters
                ? intent.summary
                : 'Il parser non riconosce filtri in questa frase.',
          ),
          subtitle:
              out.leftovers.isNotEmpty && ref.read(settingsProvider).advKeyword
              ? Text('Come parole chiave: ${out.leftovers.take(3).join(', ')}')
              : null,
        ),
      ],
    );
  }

  Widget _providerGroup(AppSettings s, AiProvider p, SettingsNotifier n) =>
      SettingsGroup(
        title: 'Modello in rete',
        footer: _providerHint(p),
        children: [
          ChoiceRow<String>(
            title: 'Servizio',
            value: p.name,
            options: {for (final v in AiProvider.values) v.name: v.title},
            onChanged: (v) {
              n.update((x) => x.withExt('advProvider', v));
              setState(() {
                _models = const [];
                _modelsStatus = null;
                _modelsOk = false;
                _testStatus = null;
                _loadedFor = null;
              });
              unawaited(_refreshKeyState());
            },
          ),
          if (p == AiProvider.custom)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _baseField,
                keyboardType: TextInputType.url,
                autocorrect: false,
                onChanged: (v) =>
                    n.update((x) => x.withExt('advCustomBase', v.trim())),
                decoration: const InputDecoration(
                  hintText: 'Indirizzo (https://…/v1)',
                ),
              ),
            ),
          _KeyGuide(provider: p),
        ],
      );

  Widget _keyGroup(AiProvider p) => SettingsGroup(
    title: 'Chiave di ${p.title}',
    footer:
        'La chiave resta nel Portachiavi di questo telefono (mai nei log). La frase che scrivi viene inviata a ${p.title} solo quando l\'AI interviene.',
    children: [
      if (_keySaved) ...[
        const ListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: 16),
          leading: Icon(Icons.key_rounded),
          title: Text('Chiave salvata nel Portachiavi'),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('Rimuovi la chiave'),
          textColor: AetherTokens.warning,
          onTap: _removeKey,
        ),
      ] else
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keyField,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: p.keyOptional
                        ? 'Chiave (facoltativa)'
                        : 'Chiave API',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _keyField.text.trim().isEmpty ? null : _saveKey,
                child: const Text('Salva'),
              ),
            ],
          ),
        ),
    ],
  );

  Widget _modelGroup(AiProvider p, String model, SettingsNotifier n) {
    final name =
        _models.where((m) => m.id == model).firstOrNull?.name ??
        (model.isEmpty ? 'Nessuno' : model);
    return SettingsGroup(
      title: 'Chiave e modello',
      footer: '«Verifica la chiave» chiede al servizio l\'elenco dei modelli: è gratuito, non consuma credito. L\'elenco dipende dal piano dell\'account collegato alla chiave. «Prova il modello» invia una vera richiesta («film simili a Toy Story»): costa una frazione di centesimo.',
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('Verifica la chiave'),
          trailing: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: _busy ? null : () => _loadModels(auto: false),
        ),
        if (_modelsStatus != null)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: Icon(
              _modelsOk
                  ? Icons.check_circle_rounded
                  : Icons.warning_amber_rounded,
              color: _modelsOk ? AetherTokens.success : AetherTokens.warning,
            ),
            title: Text(_modelsStatus!),
          ),
        if (_models.isNotEmpty)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text('Modello'),
            subtitle: Text(name),
            trailing: const Icon(Icons.arrow_drop_down_rounded),
            onTap: () => _pickModel(p, model, n),
          )
        else if (p == AiProvider.custom)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextFormField(
              key: ValueKey('advmodel-${p.name}'),
              initialValue: model,
              autocorrect: false,
              onChanged: (v) => n.update((x) => x.withAdvModel(p, v.trim())),
              decoration: const InputDecoration(hintText: 'Nome del modello'),
            ),
          )
        else ...[
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text('Modello'),
            subtitle: Text(name),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Salva e verifica la chiave per scegliere tra i modelli disponibili.',
              style: TextStyle(fontSize: 12, color: AetherTokens.textTertiary),
            ),
          ),
        ],
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('Prova il modello'),
          onTap: _busy ? null : _runTest,
        ),
        if (_testStatus != null)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: Icon(
              _testOk
                  ? Icons.check_circle_rounded
                  : Icons.warning_amber_rounded,
              color: _testOk ? AetherTokens.success : AetherTokens.warning,
            ),
            title: Text(_testStatus!),
          ),
      ],
    );
  }

  Future<void> _pickModel(
    AiProvider p,
    String current,
    SettingsNotifier n,
  ) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AetherTokens.inkRaised,
      builder: (_) => _ModelPicker(models: _models, selected: current),
    );
    if (chosen != null) n.update((x) => x.withAdvModel(p, chosen));
  }

  static String _providerHint(AiProvider p) => switch (p) {
    AiProvider.anthropic => 'Consigliato un modello piccolo e veloce come Claude Haiku: basta e costa poco.',
    AiProvider.openai => 'Un modello «mini» basta.',
    AiProvider.google => 'Un modello «flash» basta. C\'è un livello gratuito con limiti di richieste.',
    AiProvider.openrouter => 'Una sola chiave dà accesso a molti modelli. Il nome ha la forma «fornitore/modello».',
    AiProvider.custom => 'Qualsiasi server con API compatibile OpenAI raggiungibile via https (la chiave è facoltativa).',
  };
}

bool _enabled(AppSettings s) => s.advSearch;
bool _keyword(AppSettings s) => s.advKeyword;
bool _parser(AppSettings s) => s.advParser;
bool _ai(AppSettings s) => s.advAi;
bool _suggest(AppSettings s) => s.advSuggest;
String _trigger(AppSettings s) => s.advTrigger;
String _mode(AppSettings s) => s.advMode;
double _timeout(AppSettings s) => s.advTimeout.toDouble();
String _kinds(AppSettings s) => s.advKinds;
double _max(AppSettings s) => s.advMax.toDouble();
double _votes(AppSettings s) => s.advMinVotes.toDouble();
bool _showInterp(AppSettings s) => s.advShowInterpretation;
bool _showSource(AppSettings s) => s.advShowSource;
bool _adult(AppSettings s) => s.advAdult;
bool _remember(AppSettings s) => s.advRemember;
bool _log(AppSettings s) => s.advLog;
String _secFmt(double v) => '${v.round()} s';
String _intFmt(double v) => '${v.round()}';

/// Come ottenere la chiave del servizio scelto, passo per passo.
class _KeyGuide extends StatelessWidget {
  const _KeyGuide({required this.provider});
  final AiProvider provider;

  ({String url, List<String> steps, String cost})
  get _guide => switch (provider) {
    AiProvider.anthropic => (
      url: 'https://console.anthropic.com/settings/keys',
      steps: [
        'Crea un account sulla console Anthropic (è diversa dall\'app Claude).',
        'Apri Settings ▸ API keys ▸ Create Key e dai un nome alla chiave.',
        'Copia la chiave (inizia con «sk-ant-»): viene mostrata una volta sola.',
        'In Billing aggiungi del credito: l\'API è a consumo.',
      ],
      cost: 'L\'abbonamento Claude Pro/Max non include l\'API. Qui una ricerca costa frazioni di centesimo con un modello Haiku.',
    ),
    AiProvider.openai => (
      url: 'https://platform.openai.com/api-keys',
      steps: [
        'Accedi a platform.openai.com (è separato da ChatGPT).',
        'Apri API keys ▸ Create new secret key.',
        'Copia la chiave (inizia con «sk-»): viene mostrata una volta sola.',
        'In Billing aggiungi credito prepagato, altrimenti le richieste vengono rifiutate.',
      ],
      cost: 'ChatGPT Plus non include l\'API. Un modello «mini» costa pochissimo per richieste così corte.',
    ),
    AiProvider.google => (
      url: 'https://aistudio.google.com/apikey',
      steps: [
        'Accedi a Google AI Studio con il tuo account Google.',
        'Apri «Get API key» ▸ Create API key.',
        'Copia la chiave e incollala qui sotto.',
      ],
      cost: 'C\'è un livello gratuito con limiti di richieste al giorno (variano nel tempo): per le ricerche di Aether basta di solito.',
    ),
    AiProvider.openrouter => (
      url: 'https://openrouter.ai/keys',
      steps: [
        'Crea un account su openrouter.ai.',
        'Apri Keys ▸ Create Key.',
        'Copia la chiave (inizia con «sk-or-»).',
        'Aggiungi credito da Credits, oppure scegli un modello gratuito (nome che finisce con «:free»).',
      ],
      cost: 'Una sola chiave dà accesso a molti modelli di fornitori diversi. L\'elenco dei modelli si vede anche senza chiave.',
    ),
    AiProvider.custom => (
      url: '',
      steps: [
        'Inserisci l\'indirizzo base del server compatibile OpenAI, ad esempio https://tuo-server/v1.',
        'Se il server richiede una chiave, incollala qui sotto; altrimenti lasciala vuota.',
      ],
      cost: 'Il server deve essere raggiungibile via https da Internet.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final g = _guide;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        title: const Text('Come ottenere la chiave'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < g.steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${i + 1}. ${g.steps[i]}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          if (g.url.isNotEmpty)
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(g.url),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text(Uri.parse(g.url).host),
            ),
          Text(
            g.cost,
            style: const TextStyle(
              fontSize: 12,
              color: AetherTokens.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Elenco dei modelli disponibili con il piano della chiave, con ricerca.
class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.selected});
  final List<AiModelInfo> models;
  final String selected;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = q.isEmpty
        ? widget.models
        : [
            for (final m in widget.models)
              if (m.id.toLowerCase().contains(q) ||
                  m.name.toLowerCase().contains(q))
                m,
          ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  autofocus: false,
                  onChanged: (v) => setState(() => _q = v),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Cerca un modello',
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final m in list)
                      ListTile(
                        title: Text(m.name),
                        subtitle: Text(
                          [
                            if (m.name != m.id) m.id,
                            if (m.note != null) m.note!,
                          ].join(' · '),
                        ),
                        trailing: m.id == widget.selected
                            ? const Icon(Icons.check_rounded)
                            : null,
                        onTap: () => Navigator.of(context).pop(m.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Registro dei tempi della ricerca avanzata.
class SearchTimingLogPage extends ConsumerWidget {
  const SearchTimingLogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(advancedEngineProvider).log;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Registro dei tempi'),
          actions: [
            TextButton(
              onPressed: log.entries.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: log.text()));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copiato')),
                        );
                      }
                    },
              child: const Text('Copia'),
            ),
            TextButton(
              onPressed: log.entries.isEmpty ? null : log.clear,
              child: const Text('Svuota'),
            ),
          ],
        ),
        body: log.entries.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nessuna ricerca registrata. Fai una ricerca avanzata (con «Registra i tempi» acceso) e torna qui.',
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final e in log.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '«${e.query}» · ${e.total.toStringAsFixed(1)} s · ${e.results} risultati',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${e.date.toLocal().toString().substring(0, 19)} · ${e.interpreter}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AetherTokens.textTertiary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (final p in e.phases)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      p.detail == null
                                          ? p.name
                                          : '${p.name}\n${p.detail}',
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  Text(
                                    '${p.seconds.toStringAsFixed(2)} s',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          for (final note in e.notes)
                            Text(
                              note,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AetherTokens.warning,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
