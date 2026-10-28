import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/version.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';
import 'about_eggs.dart';
import "settings_extra.dart";
import 'settings_pages2.dart';
import 'settings_services.dart';
import '../../design/palettes.dart';
import '../../core/metadata/tmdb_client.dart';
import '../../core/model/meta.dart';
import '../../core/util/app_log.dart';
import '../../data/backup.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../home/home_screen.dart';
import 'settings_widgets.dart';

/// "Altro": the doorway to addons, downloads and the settings.
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
              children: [
                HubRow(
                  icon: Icons.theaters_rounded,
                  color: const Color(0xFFFFC857),
                  title: 'Theater Mode',
                  subtitle: 'L’app in orizzontale, in stile cinema',
                  onTap: () => context.push('/theater'),
                ),
                HubRow(
                  icon: Icons.extension_rounded,
                  color: const Color(0xFF7C8CFF),
                  title: 'Addon',
                  subtitle: addons.isEmpty
                      ? 'Nessuno installato'
                      : '${addons.where((a) => a.enabled).length} attivi su ${addons.length}',
                  onTap: () => context.push('/addons'),
                ),
                HubRow(
                  icon: Icons.download_for_offline_rounded,
                  color: const Color(0xFF4CD6A0),
                  title: 'Download',
                  subtitle: 'File per guardare senza rete',
                  onTap: () => context.push('/downloads'),
                ),
              ],
            ),
            SettingsGroup(
              children: [
                HubRow(
                  icon: Icons.settings_rounded,
                  color: const Color(0xFF8E8E93),
                  title: 'Impostazioni',
                  subtitle: 'Aspetto, Home, Player, Sorgenti, Servizi…',
                  onTap: () => context.push('/settings/root'),
                ),
                HubRow(
                  icon: Icons.info_rounded,
                  color: const Color(0xFF5CC8FF),
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

/// A row in the style of iOS Settings: a small coloured tile with a white glyph, the title, a grey detail and a chevron.
class HubRow extends ConsumerWidget {
  const HubRow({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colored = ref.watch(settingsProvider).coloredIcons;
    final c = colored ? color : AetherTokens.textSecondary;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
      minTileHeight: 52,
      leading: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [c, Color.lerp(c, Colors.black, 0.18)!],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 17, color: Colors.white),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: AetherTokens.textTertiary,
      ),
      onTap: onTap,
    );
  }
}

/// Settings, topic by topic: everything about one thing (the Home, the player, the sources…) is on one page.
class _Topic {
  const _Topic(this.id, this.title, this.icon, this.color, this.subtitle);
  final String id;
  final String title;
  final IconData icon;
  final Color color;
  final String subtitle;
}

const _topicsMain = [
  _Topic(
    'look',
    'Aspetto',
    Icons.palette_rounded,
    Color(0xFFFF6FB5),
    'Tema, colori, vetro, sfondo, transizioni',
  ),
  _Topic(
    'home',
    'Home',
    Icons.home_rounded,
    Color(0xFFFF8A5B),
    'Sezioni, ordine, in evidenza',
  ),
  _Topic(
    'discover',
    'Scopri',
    Icons.explore_rounded,
    Color(0xFF4CD6A0),
    'Tipi, catalogo predefinito, filtri',
  ),
  _Topic(
    'player',
    'Player',
    Icons.play_circle_rounded,
    Color(0xFFFFA23B),
    'Lingue, sottotitoli, gesti, immagine',
  ),
  _Topic(
    'sources',
    'Sorgenti',
    Icons.view_list_rounded,
    Color(0xFF7C8CFF),
    'Ordine, righe, badge',
  ),
  _Topic(
    'catalogs',
    'Cataloghi e metadati',
    Icons.collections_bookmark_rounded,
    Color(0xFF5CC8FF),
    'Cataloghi, ricerca, TMDB',
  ),
  _Topic(
    'services',
    'Servizi',
    Icons.key_rounded,
    Color(0xFFB48CFF),
    'TorBox, Real-Debrid, TMDB, MDBList…',
  ),
];
const _topicsData = [
  _Topic(
    'downloads',
    'Download',
    Icons.download_rounded,
    Color(0xFF30C48D),
    'Rete, stagioni, limiti',
  ),
  _Topic(
    'data',
    'Archiviazione e dati',
    Icons.sd_storage_rounded,
    Color(0xFFA2845E),
    'Cache, backup, cancellazione',
  ),
  _Topic(
    'diagnostics',
    'Diagnostica',
    Icons.health_and_safety_rounded,
    Color(0xFF8E8E93),
    'Registro, player di prova',
  ),
];

class SettingsRootScreen extends StatelessWidget {
  const SettingsRootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget group(List<_Topic> topics) => SettingsGroup(
      children: [
        for (final t in topics)
          HubRow(
            icon: t.icon,
            color: t.color,
            title: t.title,
            subtitle: t.subtitle,
            onTap: () => context.push('/settings/${t.id}'),
          ),
      ],
    );
    return SettingsPageFrame(
      title: 'Impostazioni',
      children: [group(_topicsMain), group(_topicsData)],
    );
  }
}

Widget _only(Set<String> titles, Widget child) =>
    GroupFilter(titles: titles, child: child);

/// The groups of every topic, in the order they appear: some come from the page that builds them, listed here by their title.
Widget _topicPage(String page) {
  switch (page) {
    case 'look':
      return MergedSettingsPage(
        title: 'Aspetto',
        parts: [
          _only({'Stili pronti', 'Transizioni'}, const LookPage()),
          const _AppearancePage(),
          _only({
            'Interfaccia',
            'Colori',
            'Sfondo',
            'Schede e locandine',
            'Movimento',
          }, const LookPage()),
        ],
      );
    case 'home':
      return MergedSettingsPage(
        title: 'Home',
        parts: [
          _only({'In evidenza', 'Sezioni della Home'}, const LookPage()),
        ],
      );
    case 'discover':
      return MergedSettingsPage(
        title: 'Scopri',
        parts: [
          _only({'Scopri'}, const MetadataPage()),
        ],
      );
    case 'player':
      return MergedSettingsPage(
        title: 'Player',
        parts: [
          _only({'Lingue'}, const _PlaybackPage()),
          _only({'Lingue di riserva'}, const PlayerAdvancedPage()),
          _only({'Sottotitoli'}, const _PlaybackPage()),
          _only({'Stile dei sottotitoli'}, const PlayerAdvancedPage()),
          _only({'Player'}, const _PlaybackPage()),
          _only({
            'Controlli e gesti',
            'Ripresa e fine episodio',
            'Immagine (motore libmpv)',
            'In sottofondo',
          }, const PlayerAdvancedPage()),
        ],
      );
    case 'sources':
      return const MergedSettingsPage(
        title: 'Sorgenti',
        parts: [SourcesPage()],
      );
    case 'catalogs':
      return MergedSettingsPage(
        title: 'Cataloghi e metadati',
        parts: [
          _only({'Cataloghi e lingua', 'Rete'}, const _ContentPage()),
          _only({'Cataloghi e cache', 'Metadati TMDB'}, const MetadataPage()),
          _only({'Badge personalizzati'}, const _ContentPage()),
        ],
      );
    case 'downloads':
      return MergedSettingsPage(
        title: 'Download',
        parts: [
          _only({
            'Download',
            'Download di una stagione',
          }, const DownloadsSettingsPage()),
        ],
      );
    case 'data':
      return MergedSettingsPage(
        title: 'Archiviazione e dati',
        parts: [
          _only({'Archiviazione'}, const DownloadsSettingsPage()),
          const _DataPage(),
        ],
      );
  }
  return const SizedBox.shrink();
}

class SettingsPageScreen extends ConsumerWidget {
  const SettingsPageScreen({super.key, required this.page});
  final String page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (page) {
      'root' => const SettingsRootScreen(),
      'services' => const ServicesPage(),
      'catalogs-edit' => const _CatalogsPage(),
      'diagnostics' => const _DiagnosticsPage(),
      'about' => const _AboutPage(),
      'look' ||
      'home' ||
      'discover' ||
      'player' ||
      'sources' ||
      'catalogs' ||
      'downloads' ||
      'data' => _topicPage(page),
      // Older links
      'appearance' => _topicPage('look'),
      'playback' => _topicPage('player'),
      'content' || 'metadata' => _topicPage('catalogs'),
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
          title: 'Liquid Glass',
          icon: Icons.blur_on_rounded,
          footer: 'Come il cursore di iOS: a sinistra il vetro è trasparente, a destra è più denso e colorato. Il vero Liquid Glass (rifrazione) richiede un telefono con GPU recente; altrimenti l’app usa il vetro sfocato. Riduci gli effetti se noti scatti.',
          children: [
            PrefSwitch(
              'liquidGlass',
              'Liquid Glass con rifrazione',
              (x) => x.liquidGlass,
              subtitle: 'Barra in basso, pulsanti principali e pannelli',
            ),
            SliderRow(
              title: 'Trasparente ↔ Colorato',
              value: s.glassIntensity,
              min: 0,
              max: 1,
              divisions: 20,
              format: (v) => v < 0.15
                  ? 'Trasparente'
                  : (v > 0.85 ? 'Colorato' : '${(v * 100).round()}%'),
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
          title: 'Cataloghi e lingua',
          children: [
            NavRow(
              icon: Icons.view_list_rounded,
              title: 'Nomi, ordine e visibilità dei cataloghi',
              subtitle: 'Valgono in Home e Scopri',
              onTap: () => context.push('/settings/catalogs-edit'),
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
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('Crea un file di backup…'),
              subtitle: const Text('Lo condividi o lo salvi dove vuoi'),
              onTap: () async {
                final text = await BackupService(services).export(
                  settings: ref.read(settingsProvider),
                  includeKeys: _keys,
                  includeAddonAddresses: _addons,
                );
                final day = DateTime.now().toIso8601String().substring(0, 10);
                final file = File(
                  '${Directory.systemTemp.path}/aether-backup-$day.json',
                );
                await file.writeAsString(text, flush: true);
                await SharePlus.instance.share(
                  ShareParams(
                    files: [XFile(file.path)],
                    subject: 'Backup di Aether',
                  ),
                );
                setState(() => _message = 'Backup creato.');
              },
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
              leading: const Icon(Icons.file_open_rounded),
              title: const Text('Ripristina da un file…'),
              subtitle: const Text(
                'Unisce libreria e cronologia; sostituisce le impostazioni.',
              ),
              onTap: () async {
                try {
                  final picked = await FilePicker.pickFiles(type: FileType.any);
                  final path = picked.isEmpty ? null : picked.first.path;
                  if (path == null) return;
                  final text = await File(path).readAsString();
                  final r = await BackupService(services).restore(
                    text,
                    applySettings: (s) =>
                        ref.read(settingsProvider.notifier).update((_) => s),
                  );
                  ref.read(addonsProvider.notifier).reload();
                  ref.read(libraryVersionProvider.notifier).bump();
                  setState(
                    () => _message =
                        'Ripristinato: ${r.libraryItems} elementi di libreria, ${r.addons} addon, ${r.keys} chiavi.',
                  );
                } on FormatException catch (e) {
                  setState(() => _message = e.message);
                } on Object {
                  setState(() => _message = 'Non riesco a leggere quel file.');
                }
              },
            ),
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
              leading: const Icon(Icons.search_off_rounded),
              title: const Text('Cancella le ricerche recenti'),
              onTap: () async {
                await services.store.remove('search.recent.v1');
                setState(() => _message = 'Ricerche recenti cancellate.');
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(
                Icons.delete_forever_rounded,
                color: AetherTokens.danger,
              ),
              title: const Text('Elimina tutti i dati locali…'),
              subtitle: const Text(
                'Libreria, impostazioni, addon, download e chiavi',
              ),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Eliminare tutto?'),
                    content: const Text(
                      'Libreria, cronologia, impostazioni, addon installati, download e chiavi di questo dispositivo verranno cancellati. Non si può annullare.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Annulla'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Elimina tutto'),
                      ),
                    ],
                  ),
                );
                if (ok != true) return;
                await services.wipe();
                await ref
                    .read(settingsProvider.notifier)
                    .update((_) => const AppSettings());
                ref.read(addonsProvider.notifier).reload();
                ref.read(libraryVersionProvider.notifier).bump();
                if (mounted) context.go('/onboarding');
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
            SwitchRow(
              title: 'Conserva il registro (solo su questo dispositivo)',
              value: ref.watch(settingsProvider).keepLog,
              onChanged: (v) {
                AppLog.instance.enabled = v;
                ref
                    .read(settingsProvider.notifier)
                    .update((x) => x.withExt('keepLog', v));
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('Esporta il registro…'),
              onTap: () async {
                final f = File(
                  '${Directory.systemTemp.path}/aether-registro.txt',
                );
                await f.writeAsString(lines.join('\n'), flush: true);
                await SharePlus.instance.share(
                  ShareParams(
                    files: [XFile(f.path)],
                    subject: 'Registro di Aether',
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_rounded),
              title: const Text('Cancella il registro'),
              onTap: () => setState(AppLog.instance.clear),
            ),
            if (lines.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Nessun evento registrato.'),
              ),
            for (final l in lines.reversed.take(60))
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 2,
                ),
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
      const Center(child: AboutLogo()),
      const SizedBox(height: 12),
      const Center(child: TheaterLogo()),
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
