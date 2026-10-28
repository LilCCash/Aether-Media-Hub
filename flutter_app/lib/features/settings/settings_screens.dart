import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/version.dart';
import '../../core/debrid/torbox_client.dart';
import '../../core/metadata/fanart_client.dart';
import 'settings_pages2.dart';
import '../../design/palettes.dart';
import '../../core/metadata/tmdb_client.dart';
import '../../core/model/meta.dart';
import '../../core/util/app_log.dart';
import '../../data/backup.dart';
import '../../data/stores.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../home/home_screen.dart';
import 'settings_widgets.dart';

/// "Altro": the doorway to addons, downloads and every setting, grouped by what they are for.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addons = ref.watch(addonsProvider);
    return AetherBackdrop(
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
              child: Text(
                'Altro',
                style: Theme.of(context).textTheme.displaySmall,
              ),
            ),
            SettingsGroup(
              title: 'Contenuti',
              children: [
                NavRow(
                  icon: Icons.theaters_rounded,
                  title: 'Theater Mode',
                  subtitle: 'L’app in orizzontale, in stile cinema',
                  onTap: () => context.push('/theater'),
                ),
                NavRow(
                  icon: Icons.extension_rounded,
                  title: 'Addon',
                  subtitle: addons.isEmpty
                      ? 'Nessuno installato'
                      : '${addons.where((a) => a.enabled).length} attivi su ${addons.length}',
                  onTap: () => context.push('/addons'),
                ),
                NavRow(
                  icon: Icons.download_for_offline_rounded,
                  title: 'Download',
                  subtitle: 'File per guardare senza rete',
                  onTap: () => context.push('/downloads'),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Impostazioni',
              children: [
                NavRow(
                  icon: Icons.play_circle_outline_rounded,
                  title: 'Riproduzione',
                  subtitle: 'Lingue, sottotitoli, velocità, ripresa',
                  onTap: () => context.push('/settings/playback'),
                ),
                NavRow(
                  icon: Icons.palette_outlined,
                  title: 'Aspetto',
                  subtitle: 'Colori, vetro, Cinematic, AMOLED',
                  onTap: () => context.push('/settings/appearance'),
                ),
                NavRow(
                  icon: Icons.view_list_rounded,
                  title: 'Contenuti e cataloghi',
                  subtitle: 'Lingua, nomi e ordine dei cataloghi, rete locale',
                  onTap: () => context.push('/settings/content'),
                ),
                NavRow(
                  icon: Icons.palette_rounded,
                  title: 'Personalizzazione',
                  subtitle: 'Sfondo, cornici, angoli, Home, In evidenza',
                  onTap: () => context.push('/settings/look'),
                ),
                NavRow(
                  icon: Icons.sort_rounded,
                  title: 'Sorgenti',
                  subtitle: 'Ordine, qualità, badge',
                  onTap: () => context.push('/settings/sources'),
                ),
                NavRow(
                  icon: Icons.movie_filter_rounded,
                  title: 'Metadati e scheda del titolo',
                  subtitle: 'TMDB, voti MDBList, cataloghi, ricerca',
                  onTap: () => context.push('/settings/metadata'),
                ),
                NavRow(
                  icon: Icons.tune_rounded,
                  title: 'Player avanzato',
                  subtitle: 'Gesti, sottotitoli, immagine, ripresa',
                  onTap: () => context.push('/settings/player'),
                ),
                NavRow(
                  icon: Icons.download_for_offline_rounded,
                  title: 'Download e archiviazione',
                  subtitle: 'Stagioni, limiti, cache',
                  onTap: () => context.push('/settings/downloads'),
                ),
                NavRow(
                  icon: Icons.key_rounded,
                  title: 'Servizi',
                  subtitle: 'TorBox e TMDB (le tue chiavi)',
                  onTap: () => context.push('/settings/services'),
                ),
                NavRow(
                  icon: Icons.save_alt_rounded,
                  title: 'Dati e backup',
                  subtitle: 'Esporta, ripristina, cancella',
                  onTap: () => context.push('/settings/data'),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Aiuto',
              children: [
                NavRow(
                  icon: Icons.health_and_safety_outlined,
                  title: 'Diagnostica',
                  subtitle: 'Registro, player di prova senza rete',
                  onTap: () => context.push('/settings/diagnostics'),
                ),
                NavRow(
                  icon: Icons.info_outline_rounded,
                  title: 'Informazioni e licenze',
                  subtitle: 'Versione $appVersion',
                  onTap: () => context.push('/settings/about'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsPageScreen extends ConsumerWidget {
  const SettingsPageScreen({super.key, required this.page});
  final String page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (page) {
      'playback' => const _PlaybackPage(),
      'appearance' => const _AppearancePage(),
      'content' => const _ContentPage(),
      'catalogs' => const _CatalogsPage(),
      'services' => const _ServicesPage(),
      'sources' => const SourcesPage(),
      'metadata' => const MetadataPage(),
      'downloads' => const DownloadsSettingsPage(),
      'player' => const PlayerAdvancedPage(),
      'look' => const LookPage(),
      'data' => const _DataPage(),
      'diagnostics' => const _DiagnosticsPage(),
      'about' => const _AboutPage(),
      _ => SettingsPageFrame(
        title: 'Impostazioni',
        children: [Text('Pagina sconosciuta: $page')],
      ),
    };
  }
}

const _languages = {
  'ita': 'Italiano',
  'eng': 'Inglese',
  'fra': 'Francese',
  'spa': 'Spagnolo',
  'deu': 'Tedesco',
  'por': 'Portoghese',
  'jpn': 'Giapponese',
};

class _PlaybackPage extends ConsumerWidget {
  const _PlaybackPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsPageFrame(
      title: 'Riproduzione',
      children: [
        SettingsGroup(
          title: 'Lingue',
          children: [
            ChoiceRow<String>(
              title: 'Audio preferito',
              value: s.audioLanguage,
              options: _languages,
              onChanged: (v) => n.update((x) => x.copyWith(audioLanguage: v)),
            ),
            ChoiceRow<String>(
              title: 'Sottotitoli preferiti',
              value: s.subtitleLanguage,
              options: _languages,
              onChanged: (v) =>
                  n.update((x) => x.copyWith(subtitleLanguage: v)),
            ),
            ChoiceRow<String>(
              title: 'Lingua delle sorgenti',
              value: s.preferredStreamLanguage,
              options: const {
                'Italiano': 'Italiano',
                'Inglese': 'Inglese',
                'Francese': 'Francese',
                'Spagnolo': 'Spagnolo',
                'Tedesco': 'Tedesco',
              },
              onChanged: (v) =>
                  n.update((x) => x.copyWith(preferredStreamLanguage: v)),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Sottotitoli',
          footer: 'Se il film è già nella tua lingua vengono scelti solo i sottotitoli «forzati» (i dialoghi stranieri).',
          children: [
            SwitchRow(
              title: 'Attiva i sottotitoli all’avvio',
              value: s.subtitlesEnabledByDefault,
              onChanged: (v) =>
                  n.update((x) => x.copyWith(subtitlesEnabledByDefault: v)),
            ),
            SwitchRow(
              title: 'Rimuovi le descrizioni per non udenti',
              subtitle:
                  'Per i sottotitoli da addon: «[porta che sbatte]», «JOHN:»…',
              value: s.removeHearingImpaired,
              onChanged: (v) =>
                  n.update((x) => x.copyWith(removeHearingImpaired: v)),
            ),
            SliderRow(
              title: 'Dimensione (sottotitoli da addon)',
              value: s.subtitleScale,
              min: 0.6,
              max: 2,
              divisions: 14,
              format: (v) => '${(v * 100).round()}%',
              onChanged: (v) => n.update((x) => x.copyWith(subtitleScale: v)),
            ),
            SliderRow(
              title: 'Sincronia predefinita',
              value: s.subtitleOffsetMs / 1000,
              min: -10,
              max: 10,
              divisions: 80,
              format: (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)} s',
              onChanged: (v) => n.update(
                (x) => x.copyWith(subtitleOffsetMs: (v * 1000).round()),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Player',
          children: [
            ChoiceRow<double>(
              title: 'Velocità predefinita',
              value: s.playbackSpeed,
              options: {
                0.75: '0,75×',
                1.0: 'Normale',
                1.25: '1,25×',
                1.5: '1,5×',
              },
              onChanged: (v) => n.update((x) => x.copyWith(playbackSpeed: v)),
            ),
            SwitchRow(
              title: 'Pulsante «Salta intro»',
              subtitle: 'Dati volontari di IntroDB (nessuna chiave): possono essere di pochi secondi fuori per un’altra versione dell’episodio.',
              value: s.skipIntro,
              onChanged: (v) => n.update((x) => x.copyWith(skipIntro: v)),
            ),
            SwitchRow(
              title: 'Riprendi da dove eri',
              value: s.resumePlayback,
              onChanged: (v) => n.update((x) => x.copyWith(resumePlayback: v)),
            ),
            SwitchRow(
              title: 'Episodio successivo automatico',
              subtitle:
                  'Parte solo se la sorgente si apre senza chiederti nulla.',
              value: s.autoplayNext,
              onChanged: (v) => n.update((x) => x.copyWith(autoplayNext: v)),
            ),
          ],
        ),
      ],
    );
  }
}

class _AppearancePage extends ConsumerWidget {
  const _AppearancePage();

  static const _accents = [
    '#7C8CFF',
    '#4FD1C5',
    '#FF7AA2',
    '#FFB454',
    '#7BE495',
    '#B58CFF',
    '#5AB0FF',
    '#FF6B6B',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsPageFrame(
      title: 'Aspetto',
      children: [
        SettingsGroup(
          title: 'Modalità',
          footer: 'Cinematic tinge le schermate con i colori della locandina del titolo. AMOLED usa neri totali.',
          children: [
            SwitchRow(
              title: 'Dynamic Cinematic',
              subtitle: 'Sfondi e schede prendono i colori del film',
              value: s.cinematic,
              onChanged: (v) => n.update((x) => x.copyWith(cinematic: v)),
            ),
            SwitchRow(
              title: 'AMOLED (neri totali)',
              subtitle: 'Sfondo nero assoluto, bagliori ridotti',
              value: s.amoled,
              onChanged: (v) => n.update((x) => x.copyWith(amoled: v)),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Palette',
          footer: 'Una palette sostituisce il colore d’accento e aggiunge un secondo bagliore sullo sfondo. «Aether» usa il colore scelto sotto.',
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in AetherPalette.values)
                    ChoiceChip(
                      label: Text('${p.emoji} ${p.title}'),
                      selected: s.palette == p.name,
                      onSelected: (_) =>
                          n.update((x) => x.copyWith(palette: p.name)),
                    ),
                ],
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Testo',
          children: [
            ChoiceRow<String>(
              title: 'Carattere dei titoli',
              value: s.titleFont,
              options: {for (final f in TitleFont.values) f.name: f.title},
              onChanged: (v) => n.update((x) => x.copyWith(titleFont: v)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: TextFormField(
                initialValue: s.greetingName ?? '',
                maxLength: 24,
                decoration: const InputDecoration(
                  labelText: 'Saluto nella Home (il tuo nome)',
                  hintText: 'Vuoto = nessun saluto',
                ),
                onChanged: (v) => n.update(
                  (x) => x.copyWith(
                    greetingName: v.trim().isEmpty ? null : v.trim(),
                  ),
                ),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Vetro',
          footer: 'Il vetro sfocato è più impegnativo per i telefoni meno recenti: riduci gli effetti se noti scatti.',
          children: [
            SliderRow(
              title: 'Intensità del vetro',
              value: s.glassIntensity,
              min: 0,
              max: 1,
              divisions: 10,
              format: (v) => '${(v * 100).round()}%',
              onChanged: (v) => n.update((x) => x.copyWith(glassIntensity: v)),
            ),
            SwitchRow(
              title: 'Riduci gli effetti',
              subtitle: 'Superfici opache, niente sfocature né animazioni',
              value: s.reduceEffects,
              onChanged: (v) => n.update((x) => x.copyWith(reduceEffects: v)),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Colore d’accento',
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final hex in _accents)
                    Semantics(
                      button: true,
                      selected: s.accentHex.toLowerCase() == hex.toLowerCase(),
                      label: 'Colore $hex',
                      child: GestureDetector(
                        onTap: () =>
                            n.update((x) => x.copyWith(accentHex: hex)),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colorFromHex(hex),
                            border: Border.all(
                              color: Colors.white,
                              width:
                                  s.accentHex.toLowerCase() == hex.toLowerCase()
                                  ? 3
                                  : 0,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Anteprima',
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const GlassButton(
                    icon: Icons.play_arrow_rounded,
                    label: 'Guarda',
                    prominent: true,
                    onPressed: null,
                  ),
                  const SizedBox(width: 10),
                  GlassButton(icon: Icons.add_rounded, onPressed: () {}),
                  const SizedBox(width: 10),
                  const Pill('4K'),
                  const SizedBox(width: 6),
                  const Pill('HDR10', color: AetherTokens.warning),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ContentPage extends ConsumerWidget {
  const _ContentPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsPageFrame(
      title: 'Contenuti e cataloghi',
      children: [
        SettingsGroup(
          children: [
            NavRow(
              icon: Icons.view_list_rounded,
              title: 'Nomi, ordine e visibilità dei cataloghi',
              subtitle: 'Valgono in Home e Scopri',
              onTap: () => context.push('/settings/catalogs'),
            ),
            ChoiceRow<String>(
              title: 'Lingua di trame e dettagli',
              value: s.language,
              options: const {
                'it': 'Italiano',
                'en': 'Inglese',
                'fr': 'Francese',
                'es': 'Spagnolo',
                'de': 'Tedesco',
              },
              onChanged: (v) => n.update((x) => x.copyWith(language: v)),
            ),
            SwitchRow(
              title: 'Mostra «Continua a guardare»',
              value: s.showContinueWatching,
              onChanged: (v) =>
                  n.update((x) => x.copyWith(showContinueWatching: v)),
            ),
            SwitchRow(
              title: 'Nascondi i cataloghi per adulti',
              value: s.hideAdultCatalogs,
              onChanged: (v) =>
                  n.update((x) => x.copyWith(hideAdultCatalogs: v)),
            ),
          ],
        ),
        const _BadgesGroup(),
        SettingsGroup(
          title: 'Rete',
          footer: 'Attivalo solo per addon tuoi (un NAS, un Raspberry Pi). Gli indirizzi sul dispositivo stesso restano sempre bloccati.',
          children: [
            SwitchRow(
              title: 'Consenti addon sulla rete locale',
              value: s.allowLocalNetwork,
              onChanged: (v) =>
                  n.update((x) => x.copyWith(allowLocalNetwork: v)),
            ),
          ],
        ),
      ],
    );
  }
}

class _CatalogsPage extends ConsumerWidget {
  const _CatalogsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final addons = ref.watch(addonsProvider);
    // Every browsable catalog, hidden or not, in the order the viewer set.
    final all = visibleCatalogs(
      addons,
      const [],
      s.catalogOrder,
      hideAdult: false,
    );
    final ids = [for (final e in all) '${e.$1.id}/${e.$2.key}'];
    void move(String id, int delta) {
      final i = ids.indexOf(id);
      final j = i + delta;
      if (i < 0 || j < 0 || j >= ids.length) return;
      final list = [...ids];
      list.insert(j, list.removeAt(i));
      n.update((x) => x.copyWith(catalogOrder: list));
    }

    return SettingsPageFrame(
      title: 'Cataloghi',
      children: [
        if (all.isEmpty)
          const EmptyState(
            icon: Icons.view_list_rounded,
            title: 'Nessun catalogo',
            message: 'Installa un addon con cataloghi.',
          ),
        SettingsGroup(
          footer: 'Interruttore: mostra o nasconde. Frecce: cambiano il posto. Tocca il nome per rinominare.',
          children: [
            for (final (a, c) in all)
              Builder(
                builder: (context) {
                  final id = '${a.id}/${c.key}';
                  final hidden = s.hiddenHomeCatalogs.contains(id);
                  final title = s.catalogTitles[id] ?? c.name;
                  return ListTile(
                    contentPadding: const EdgeInsets.only(left: 16, right: 4),
                    leading: Switch(
                      value: !hidden,
                      onChanged: (v) => n.update(
                        (x) => x.copyWith(
                          hiddenHomeCatalogs: v
                              ? x.hiddenHomeCatalogs
                                    .where((e) => e != id)
                                    .toList()
                              : [...x.hiddenHomeCatalogs, id],
                        ),
                      ),
                    ),
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${a.displayName} · ${typeName(c.type)}'),
                    onTap: () => _rename(context, ref, id, c.name, title),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Sposta su',
                          icon: const Icon(Icons.keyboard_arrow_up_rounded),
                          onPressed: ids.indexOf(id) == 0
                              ? null
                              : () => move(id, -1),
                        ),
                        IconButton(
                          tooltip: 'Sposta giù',
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                          onPressed: ids.indexOf(id) == ids.length - 1
                              ? null
                              : () => move(id, 1),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
        Center(
          child: GlassButton(
            icon: Icons.restore_rounded,
            label: 'Ripristina nomi e ordine',
            onPressed: () => n.update(
              (x) => x.copyWith(
                catalogTitles: {},
                catalogOrder: [],
                hiddenHomeCatalogs: [],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    String id,
    String original,
    String current,
  ) async {
    final c = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Rinomina il catalogo'),
        content: TextField(controller: c, maxLength: 40, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, ''),
            child: const Text('Nome originale'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    c.dispose();
    if (name == null) return;
    await ref.read(settingsProvider.notifier).update((x) {
      final titles = {...x.catalogTitles};
      name.trim().isEmpty ? titles.remove(id) : titles[id] = name.trim();
      return x.copyWith(catalogTitles: titles);
    });
  }
}

class _ServicesPage extends ConsumerWidget {
  const _ServicesPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsPageFrame(
      title: 'Servizi',
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
            'Le chiavi sono tue: restano nel portachiavi sicuro del telefono, non vanno nei log né nei backup (a meno che tu non lo chieda), e puoi rimuoverle quando vuoi.',
          ),
        ),
        SettingsGroup(
          title: 'Debrid',
          footer: 'Se il servizio scelto non ha una chiave, Aether usa l’altro (se ce l’ha). Real-Debrid non permette di sapere in anticipo se un torrent è pronto: prima di aggiungerlo chiede conferma.',
          children: [
            ChoiceRow<String>(
              title: 'Servizio preferito',
              value: s.debridProvider,
              options: const {'torbox': 'TorBox', 'realdebrid': 'Real-Debrid'},
              onChanged: (v) => n.update((x) => x.copyWith(debridProvider: v)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _KeyCard(
          title: 'TorBox',
          description: 'Per riprodurre i torrent degli addon con la tua cache TorBox. Aether non cancella mai nulla dal tuo account e non avvia download senza chiederti conferma.',
          service: ServiceKey.torbox,
          verify: (ref) async {
            try {
              final plan = await ref.read(servicesProvider).torbox.check();
              return 'Connesso a TorBox ($plan).';
            } on DebridException catch (e) {
              return e.message;
            }
          },
        ),
        _KeyCard(
          title: 'Real-Debrid',
          description: 'Token personale dal tuo account Real-Debrid (account Premium). Aether non cancella nulla e non aggiunge torrent senza chiederti conferma.',
          service: ServiceKey.realdebrid,
          verify: (ref) async {
            try {
              final plan = await ref.read(servicesProvider).realDebrid.check();
              return 'Connesso a Real-Debrid ($plan).';
            } on DebridException catch (e) {
              return e.message;
            }
          },
        ),
        _KeyCard(
          title: 'TMDB',
          description: 'Per cast con foto, filmografie, trailer e dettagli. Chiave v3 o token v4 dal tuo account TMDB.',
          service: ServiceKey.tmdb,
          verify: (ref) async =>
              await ref.read(servicesProvider).tmdb.check() ??
              'TMDB accetta la chiave.',
        ),
        SettingsGroup(
          title: 'Dettagli del titolo',
          children: [
            SwitchRow(
              title: 'Voti da più servizi (MDBList)',
              value: s.showRatings,
              onChanged: (v) => n.update((x) => x.copyWith(showRatings: v)),
            ),
            SwitchRow(
              title: 'Titoli degli episodi tradotti (TheTVDB)',
              value: s.tvdbEpisodes,
              onChanged: (v) => n.update((x) => x.copyWith(tvdbEpisodes: v)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _KeyCard(
          title: 'MDBList',
          description: 'Voti di IMDb, Rotten Tomatoes, Metacritic, Trakt e altri nella scheda del titolo. Chiave dal tuo account MDBList.',
          service: ServiceKey.mdblist,
          verify: (ref) async =>
              await ref.read(servicesProvider).mdblist.check() ??
              'MDBList accetta la chiave.',
        ),
        _KeyCard(
          title: 'TheTVDB',
          description: 'Titoli e trame degli episodi nella tua lingua. Chiave di progetto TheTVDB v4.',
          service: ServiceKey.tvdb,
          verify: (ref) async =>
              await ref.read(servicesProvider).tvdb.check() ??
              'TheTVDB accetta la chiave.',
        ),
        _KeyCard(
          title: 'TheTVDB · PIN (facoltativo)',
          description: 'Solo se la tua chiave TheTVDB è di un abbonato e richiede il PIN.',
          service: ServiceKey.tvdbPin,
          verify: (ref) async =>
              await ref.read(servicesProvider).tvdb.check() ??
              'TheTVDB accetta chiave e PIN.',
        ),
        _KeyCard(
          title: 'fanart.tv',
          description: 'Logo trasparente del titolo mostrato dal player mentre prepara la sorgente. Chiave personale dal tuo account fanart.tv.',
          service: ServiceKey.fanart,
          verify: (ref) async {
            final url = await ref
                .read(servicesProvider)
                .fanart
                .logoUrl(FanartKind.movie, 'tt0111161', 'en');
            return url == null
                ? 'fanart.tv non ha risposto con un logo: controlla la chiave.'
                : 'fanart.tv accetta la chiave.';
          },
        ),
      ],
    );
  }
}

class _KeyCard extends ConsumerStatefulWidget {
  const _KeyCard({
    required this.title,
    required this.description,
    required this.service,
    required this.verify,
  });
  final String title;
  final String description;
  final ServiceKey service;
  final Future<String> Function(WidgetRef) verify;

  @override
  ConsumerState<_KeyCard> createState() => _KeyCardState();
}

class _KeyCardState extends ConsumerState<_KeyCard> {
  final _c = TextEditingController();
  bool _saved = false;
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ref.read(servicesProvider).secrets.serviceKey(widget.service).then((v) {
      if (mounted) setState(() => _saved = (v ?? '').isNotEmpty);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final r = await widget.verify(ref);
    if (mounted)
      setState(() {
        _status = r;
        _busy = false;
      });
  }

  @override
  Widget build(BuildContext context) {
    final secrets = ref.read(servicesProvider).secrets;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: GlassSurface(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                if (_saved)
                  const Pill('Chiave salvata', color: AetherTokens.success),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              widget.description,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (!_saved) ...[
              TextField(
                controller: _c,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: 'Incolla la chiave',
                  filled: true,
                  fillColor: Colors.white10,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              GlassButton(
                label: 'Salva e verifica',
                icon: Icons.verified_rounded,
                prominent: true,
                onPressed: _busy
                    ? null
                    : () async {
                        if (_c.text.trim().isEmpty) return;
                        await secrets.setServiceKey(widget.service, _c.text);
                        _c.clear();
                        setState(() => _saved = true);
                        await _verify();
                      },
              ),
            ] else
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  GlassButton(
                    label: _busy ? 'Verifico…' : 'Verifica',
                    icon: Icons.verified_rounded,
                    onPressed: _busy ? null : _verify,
                  ),
                  GlassButton(
                    label: 'Rimuovi',
                    icon: Icons.delete_outline_rounded,
                    onPressed: () async {
                      await secrets.setServiceKey(widget.service, null);
                      setState(() {
                        _saved = false;
                        _status = null;
                      });
                    },
                  ),
                ],
              ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_status!, style: const TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }
}

class _DataPage extends ConsumerStatefulWidget {
  const _DataPage();

  @override
  ConsumerState<_DataPage> createState() => _DataPageState();
}

class _DataPageState extends ConsumerState<_DataPage> {
  bool _keys = false;
  bool _addons = false;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(servicesProvider);
    return SettingsPageFrame(
      title: 'Dati e backup',
      children: [
        SettingsGroup(
          title: 'Esporta',
          footer: 'Il backup è un testo JSON copiato negli appunti. Le chiavi e gli indirizzi degli addon (che possono contenere la tua configurazione) sono SEGRETI: includili solo se conservi il file al sicuro.',
          children: [
            SwitchRow(
              title: 'Includi le chiavi dei servizi',
              value: _keys,
              onChanged: (v) => setState(() => _keys = v),
            ),
            SwitchRow(
              title: 'Includi gli indirizzi degli addon',
              value: _addons,
              onChanged: (v) => setState(() => _addons = v),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copia il backup negli appunti'),
              onTap: () async {
                final text = await BackupService(services).export(
                  settings: ref.read(settingsProvider),
                  includeKeys: _keys,
                  includeAddonAddresses: _addons,
                );
                await Clipboard.setData(ClipboardData(text: text));
                setState(
                  () => _message =
                      'Backup copiato (${(text.length / 1024).toStringAsFixed(1)} KB).',
                );
              },
            ),
          ],
        ),
        SettingsGroup(
          title: 'Ripristina',
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.paste_rounded),
              title: const Text('Ripristina dagli appunti'),
              subtitle: const Text(
                'Unisce libreria e cronologia; sostituisce le impostazioni.',
              ),
              onTap: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text == null) {
                  setState(() => _message = 'Gli appunti sono vuoti.');
                  return;
                }
                try {
                  final r = await BackupService(services).restore(
                    data!.text!,
                    applySettings: (s) =>
                        ref.read(settingsProvider.notifier).update((_) => s),
                  );
                  ref.read(addonsProvider.notifier).reload();
                  ref.read(libraryVersionProvider.notifier).bump();
                  setState(
                    () => _message =
                        'Ripristinato: ${r.libraryItems} elementi di libreria, ${r.addons} addon, ${r.keys} chiavi${r.addonProblems.isEmpty ? '' : '. Problemi: ${r.addonProblems.join('; ')}'}.',
                  );
                } on FormatException catch (e) {
                  setState(() => _message = e.message);
                }
              },
            ),
          ],
        ),
        SettingsGroup(
          title: 'Cancella',
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.history_toggle_off_rounded),
              title: const Text('Cancella la cronologia'),
              onTap: () async {
                await services.library.clearHistory();
                ref.read(libraryVersionProvider.notifier).bump();
                setState(() => _message = 'Cronologia cancellata.');
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.cached_rounded),
              title: const Text('Svuota la cache dei cataloghi'),
              onTap: () {
                services.addonClient.clearCache();
                ref.invalidate(catalogProvider);
                setState(() => _message = 'Cache svuotata.');
              },
            ),
          ],
        ),
        if (_message != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(_message!)),
      ],
    );
  }
}

class _DiagnosticsPage extends ConsumerStatefulWidget {
  const _DiagnosticsPage();

  @override
  ConsumerState<_DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<_DiagnosticsPage> {
  @override
  Widget build(BuildContext context) {
    final lines = AppLog.instance.lines;
    return SettingsPageFrame(
      title: 'Diagnostica',
      children: [
        SettingsGroup(
          title: 'Player',
          footer: 'Riproduce video inclusi nell’app: funziona anche in modalità aereo.',
          children: [
            NavRow(
              icon: Icons.play_circle_fill_rounded,
              title: 'Player di prova (senza rete)',
              subtitle: 'MP4 e MKV con più tracce audio e sottotitoli',
              onTap: () => context.push('/offline-test'),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Registro',
          footer: 'Resta solo su questo telefono. Chiavi, token e indirizzi degli addon vengono oscurati prima di scriverli.',
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copia il registro'),
              onTap: () =>
                  Clipboard.setData(ClipboardData(text: lines.join('\n'))),
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_rounded),
              title: const Text('Cancella il registro'),
              onTap: () => setState(AppLog.instance.clear),
            ),
          ],
        ),
        if (lines.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Nessun evento registrato.'),
          ),
        for (final l in lines.reversed.take(60))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              l,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: AetherTokens.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}

class _AboutPage extends StatelessWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context) => SettingsPageFrame(
    title: 'Informazioni',
    children: [
      Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: Image.asset(
            'assets/brand/icon.png',
            width: 104,
            height: 104,
            semanticLabel: 'Logo di Aether',
          ),
        ),
      ),
      const SizedBox(height: 14),
      const Text(
        'Aether $appVersion',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text(
        'Aether non fornisce nessun contenuto: gli addon li scegli e li installi tu, e ne rispondi. È un progetto indipendente, senza legami con Stremio, Nuvio, TMDB o TorBox.',
      ),
      const SizedBox(height: 18),
      SettingsGroup(
        title: 'Attribuzioni',
        children: [
          const ListTile(
            title: Text('TMDB'),
            subtitle: Text(
              'Questo prodotto usa le API di TMDB ma non è approvato né certificato da TMDB.',
            ),
          ),
          const ListTile(
            title: Text('Motore di riproduzione'),
            subtitle: Text(
              'media_kit (MIT) con libmpv / FFmpeg (LGPL): vedi le licenze qui sotto.',
            ),
          ),
          NavRow(
            icon: Icons.description_outlined,
            title: 'Licenze open source',
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Aether',
              applicationVersion: appVersion,
            ),
          ),
        ],
      ),
    ],
  );
}

class PersonScreen extends ConsumerStatefulWidget {
  const PersonScreen({super.key, required this.id, required this.name});
  final int id;
  final String name;

  @override
  ConsumerState<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends ConsumerState<PersonScreen> {
  late final Future<List<PersonCredit>> _future = ref
      .read(servicesProvider)
      .tmdb
      .filmography(
        widget.id,
        language: ref.read(settingsProvider).language == 'it'
            ? 'it-IT'
            : 'en-US',
      );
  bool _opening = false;

  Future<void> _open(PersonCredit c) async {
    if (_opening) return;
    setState(() => _opening = true);
    final imdb = await ref
        .read(servicesProvider)
        .tmdb
        .imdbIdOf(c.tmdbId, isMovie: c.isMovie);
    if (!mounted) return;
    setState(() => _opening = false);
    if (imdb == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'TMDB non indica il codice IMDb di questo titolo: non posso aprirlo negli addon.',
          ),
        ),
      );
      return;
    }
    openTitle(
      context,
      MetaItem(
        id: imdb,
        type: c.isMovie ? 'movie' : 'series',
        name: c.title,
        poster: c.poster,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageFrame(
      title: widget.name,
      onBack: () => context.pop(),
      children: [
        FutureBuilder<List<PersonCredit>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done)
              return const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              );
            final credits = snap.data ?? const [];
            if (credits.isEmpty)
              return const EmptyState(
                icon: Icons.person_search_rounded,
                title: 'Nessun titolo',
                message: 'TMDB non ha restituito titoli: controlla la chiave in Impostazioni ▸ Servizi.',
              );
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 120,
                childAspectRatio: 0.5,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: credits.length,
              itemBuilder: (context, i) {
                final c = credits[i];
                return GestureDetector(
                  onTap: () => _open(c),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: PosterImage(url: c.poster, title: c.title),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        c.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (c.role != null)
                        Text(
                          'nel ruolo di ${c.role}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (c.year != null)
                        Text(
                          c.year!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

/// Import of a badge pack (Fusion/Nuvio format) from a link, shown on the sources.
class _BadgesGroup extends ConsumerStatefulWidget {
  const _BadgesGroup();

  @override
  ConsumerState<_BadgesGroup> createState() => _BadgesGroupState();
}

class _BadgesGroupState extends ConsumerState<_BadgesGroup> {
  late final TextEditingController _c = TextEditingController(
    text: ref.read(settingsProvider).customBadgesUrl ?? '',
  );
  String? _status;
  bool _busy = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final rules = await ref.read(servicesProvider).badgeLoader.load(_c.text);
      await ref
          .read(settingsProvider.notifier)
          .update(
            (x) => x.copyWith(
              customBadges: rules,
              customBadgesUrl: _c.text.trim(),
            ),
          );
      if (mounted) setState(() => _status = '${rules.length} badge importati.');
    } on FormatException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    return SettingsGroup(
      title: 'Badge personalizzati',
      footer: 'Incolla l’indirizzo (https) di un file JSON di badge, per esempio nel formato «filters» di Nuvio/Fusion. Compaiono sulle sorgenti il cui nome contiene la parola o corrisponde al modello. Il file è trattato solo come dati.',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _c,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'https://…/badges.json',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                onPressed: _busy ? null : _import,
                child: Text(_busy ? 'Scarico…' : 'Importa'),
              ),
              if (s.customBadges.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    _c.clear();
                    await ref
                        .read(settingsProvider.notifier)
                        .update(
                          (x) => x.copyWith(
                            customBadges: const [],
                            customBadgesUrl: null,
                          ),
                        );
                    if (mounted) setState(() => _status = 'Badge rimossi.');
                  },
                  child: Text('Rimuovi (${s.customBadges.length})'),
                ),
            ],
          ),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(_status!),
          ),
      ],
    );
  }
}
