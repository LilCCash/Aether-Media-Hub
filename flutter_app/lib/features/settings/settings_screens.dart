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
import '../../core/model/content_filter.dart';
import '../../core/model/meta.dart';
import '../../core/util/app_log.dart';
import '../../data/backup.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../home/home_screen.dart';
import 'settings_more.dart';
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
                HubRow(
                  icon: Icons.event_rounded,
                  color: const Color(0xFFFFB454),
                  title: 'Calendario',
                  subtitle: 'Le prossime uscite delle tue serie',
                  onTap: () => context.push('/calendar'),
                ),
                HubRow(
                  icon: Icons.insights_rounded,
                  color: const Color(0xFFFF6B8B),
                  title: 'Statistiche',
                  subtitle: 'Quanto e cosa hai guardato',
                  onTap: () => context.push('/stats'),
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
    'Tema, stile, Home, effetti',
  ),
  _Topic(
    'theater',
    'Theater Mode',
    Icons.theaters_rounded,
    Color(0xFFFFC857),
    'L’app in orizzontale, in stile cinema',
  ),
  _Topic(
    'player',
    'Riproduzione',
    Icons.play_circle_rounded,
    Color(0xFFFFA23B),
    'Lingue, sottotitoli, controlli, sorgenti',
  ),
  _Topic(
    'content',
    'Contenuti e scoperta',
    Icons.grid_view_rounded,
    Color(0xFF4CD6A0),
    'Cataloghi, Scopri, ricerca, metadati',
  ),
  _Topic(
    'casting',
    'Casting',
    Icons.cast_connected_rounded,
    Color(0xFF30C4C4),
    'Rete locale e trasmissione',
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
    'storage',
    'Archiviazione',
    Icons.sd_storage_rounded,
    Color(0xFFA2845E),
    'Cache, download, stagioni',
  ),
  _Topic(
    'data',
    'Account e dati',
    Icons.account_circle_rounded,
    Color(0xFF5CA8FF),
    'Backup, ripristino, cancellazione',
  ),
  _Topic(
    'advanced',
    'Avanzate',
    Icons.build_rounded,
    Color(0xFF8E8E93),
    'Diagnostica e registro',
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
            onTap: () => context.push(
              t.id == 'theater' ? '/theater' : '/settings/${t.id}',
            ),
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

/// Which page builds each group of settings (a group is found by its title).
final Map<String, Widget> _host = {
  for (final t in [
    'Stili pronti',
    'Transizioni',
    'Interfaccia',
    'Colori',
    'Sfondo',
    'Schede e locandine',
    'Movimento',
    'In evidenza',
    'Sezioni della Home',
  ])
    t: const LookPage(),
  for (final t in [
    'Modalità',
    'Palette',
    'Testo',
    'Liquid Glass',
    'Colore d’accento',
    'Anteprima',
  ])
    t: const _AppearancePage(),
  for (final t in ['Tema chiaro e condivisione', 'Sfondi animati e locandine'])
    t: const ThemeExtrasPage(),
  for (final t in ['Lingue', 'Sottotitoli', 'Player']) t: const _PlaybackPage(),
  for (final t in [
    'Lingue di riserva',
    'Stile dei sottotitoli',
    'Controlli e gesti',
    'Ripresa e fine episodio',
    'Prossimo episodio e titoli di coda',
    'Fonti e schermata di blocco',
    'Immagine (motore libmpv)',
    'In sottofondo',
  ])
    t: const PlayerAdvancedPage(),
  for (final t in [
    'Ordine e scelta',
    'Aspetto delle righe',
    'Badge da mostrare',
  ])
    t: const SourcesPage(),
  for (final t in ['Cataloghi e lingua', 'Badge personalizzati', 'Rete'])
    t: const _ContentPage(),
  for (final t in ['Scopri', 'Cataloghi e cache']) t: const MetadataPage(),
  'Calendario e notifiche': const CalendarSettingsPage(),
  'Contenuti da nascondere': const HiddenContentSettingsPage(),
  for (final t in [
    'Archiviazione',
    'Download',
    'Download di una stagione',
    'Addon usati per le stagioni',
  ])
    t: const DownloadsSettingsPage(),
};

/// The groups [titles], one after the other, each from the page that builds it.
List<Widget> _groups(List<String> titles) => [
  for (final t in titles) _only({t}, _host[t]!),
];

/// A part of a topic with its own page: the topic page lists them like iOS Settings, each opens its groups as open sections.
class _Sub {
  const _Sub(
    this.id,
    this.title,
    this.icon,
    this.color,
    this.subtitle,
    this.groups,
  );
  final String id;
  final String title;
  final IconData icon;
  final Color color;
  final String subtitle;
  final List<String> groups;
}

const _subs = <String, List<_Sub>>{
  'look': [
    _Sub(
      'colors',
      'Colori e stile',
      Icons.palette_rounded,
      Color(0xFFFF6FB5),
      'Stili pronti, palette, colore d’accento',
      [
        'Stili pronti',
        'Modalità',
        'Palette',
        'Colore d’accento',
        'Colori',
        'Anteprima',
      ],
    ),
    _Sub(
      'glass',
      'Vetro, sfondo ed effetti',
      Icons.blur_on_rounded,
      Color(0xFF4FD1C5),
      'Liquid Glass, sfondo, movimento',
      [
        'Liquid Glass',
        'Sfondo',
        'Movimento',
        'Transizioni',
        'Sfondi animati e locandine',
      ],
    ),
    _Sub(
      'text',
      'Testo e interfaccia',
      Icons.text_fields_rounded,
      Color(0xFF5CC8FF),
      'Caratteri, schede, locandine',
      ['Testo', 'Interfaccia', 'Schede e locandine'],
    ),
    _Sub(
      'home',
      'Home',
      Icons.home_rounded,
      Color(0xFFFF8A5B),
      'In evidenza e sezioni',
      ['In evidenza', 'Sezioni della Home'],
    ),
    _Sub(
      'light',
      'Tema chiaro e condivisione',
      Icons.light_mode_rounded,
      Color(0xFFFFC857),
      'Chiaro o automatico, copia e incolla un tema',
      ['Tema chiaro e condivisione'],
    ),
  ],
  'player': [
    _Sub(
      'lang',
      'Lingue e sottotitoli',
      Icons.subtitles_rounded,
      Color(0xFFFFC857),
      'Audio, sottotitoli e il loro stile',
      ['Lingue', 'Lingue di riserva', 'Sottotitoli', 'Stile dei sottotitoli'],
    ),
    _Sub(
      'controls',
      'Player e controlli',
      Icons.play_circle_rounded,
      Color(0xFFFFA23B),
      'Motore, gesti, prossimo episodio',
      [
        'Player',
        'Controlli e gesti',
        'Ripresa e fine episodio',
        'Prossimo episodio e titoli di coda',
        'In sottofondo',
      ],
    ),
    _Sub(
      'image',
      'Immagine e schermata di blocco',
      Icons.tune_rounded,
      Color(0xFFB48CFF),
      'HDR, qualità, sorgenti di riserva',
      ['Immagine (motore libmpv)', 'Fonti e schermata di blocco'],
    ),
    _Sub(
      'sources',
      'Sorgenti',
      Icons.link_rounded,
      Color(0xFF4CD6A0),
      'Ordine, aspetto delle righe, badge',
      [
        'Ordine e scelta',
        'Aspetto delle righe',
        'Badge da mostrare',
        'Badge personalizzati',
      ],
    ),
  ],
  'content': [
    _Sub(
      'catalogs',
      'Cataloghi e Scopri',
      Icons.explore_rounded,
      Color(0xFF4CD6A0),
      'Lingua, categorie, cache',
      ['Scopri', 'Cataloghi e lingua', 'Cataloghi e cache'],
    ),
    _Sub(
      'calendar',
      'Calendario e notifiche',
      Icons.notifications_active_rounded,
      Color(0xFFFF8A5B),
      'Nuovi episodi, uscite',
      ['Calendario e notifiche'],
    ),
    _Sub(
      'hidden',
      'Contenuti da nascondere',
      Icons.visibility_off_rounded,
      Color(0xFFFF6B6B),
      'Per esempio i talk show',
      ['Contenuti da nascondere'],
    ),
  ],
};

/// A topic with parts: the parts as rows (with a few quick settings on top for the look).
Widget _hubPage(String topic, String title) => _Hub(topic: topic, title: title);

class _Hub extends StatelessWidget {
  const _Hub({required this.topic, required this.title});
  final String topic;
  final String title;

  @override
  Widget build(BuildContext context) => SettingsPageFrame(
    title: title,
    children: [
      if (topic == 'look') const ThemeQuickSettings(),
      SettingsGroup(
        children: [
          for (final p in _subs[topic]!)
            HubRow(
              icon: p.icon,
              color: p.color,
              title: p.title,
              subtitle: p.subtitle,
              onTap: () => context.push('/settings/$topic.${p.id}'),
            ),
        ],
      ),
    ],
  );
}

Widget _subPage(String page) {
  final topic = page.split('.').first;
  final sub = _subs[topic]?.where((p) => '$topic.${p.id}' == page).firstOrNull;
  if (sub == null) {
    return SettingsPageFrame(
      title: 'Impostazioni',
      children: [Text('Pagina sconosciuta: $page')],
    );
  }
  return MergedSettingsPage(title: sub.title, parts: _groups(sub.groups));
}

/// The groups of every topic, in the order they appear. The topics and their order follow the iOS app's Settings.
Widget _topicPage(String page) {
  switch (page) {
    case 'look':
      return _hubPage('look', 'Aspetto');
    case 'player':
      return _hubPage('player', 'Riproduzione');
    case 'content':
      return _hubPage('content', 'Contenuti e scoperta');
    case 'casting':
      return MergedSettingsPage(title: 'Casting', parts: _groups(['Rete']));
    case 'storage':
      return MergedSettingsPage(
        title: 'Archiviazione',
        parts: _groups([
          'Archiviazione',
          'Download',
          'Download di una stagione',
          'Addon usati per le stagioni',
        ]),
      );
    case 'data':
      return const MergedSettingsPage(
        title: 'Account e dati',
        parts: [_DataPage()],
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
      'advanced' || 'diagnostics' => const _DiagnosticsPage(),
      'about' => const _AboutPage(),
      'look' ||
      'player' ||
      'content' ||
      'casting' ||
      'storage' ||
      'data' => _topicPage(page),
      // Older links
      'appearance' || 'home' => _topicPage('look'),
      'playback' => _topicPage('player'),
      'sources' || 'metadata' || 'catalogs' => _topicPage('content'),
      'downloads' => _topicPage('storage'),
      _ when page.contains('.') => _subPage(page),
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

String _engineMode(AppSettings s) => s.playerEngine;

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
            if (Platform.isIOS) ...[
              const PrefChoice<String>(
                'playerEngine',
                'Player video (iPhone)',
                _engineMode,
                {
                  'auto': 'Automatico',
                  'av': 'Player di sistema (AVPlayer)',
                  'mpv': 'libmpv',
                },
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                  'Player di sistema: serve a Picture in Picture e ad AirPlay; converte al volo ogni file che non legge (MKV…). '
                  'libmpv: apre tutto così com’è, ma senza Picture in Picture né video su AirPlay. '
                  'Automatico: sistema per MP4, MOV e HLS, libmpv per il resto.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
            ],
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
            PrefSlider(
              'dockOpacity',
              'Opacità della barra in basso',
              (x) => x.dockOpacity,
              min: 0,
              max: 1,
              divisions: 20,
              format: (v) =>
                  v < 0.1 ? 'Quasi invisibile' : '${(v * 100).round()}%',
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
                if (!context.mounted) return;
                context.go('/onboarding');
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

  static const _notThere = [
    'Account e sincronizzazione cloud (le API di Stremio e Nuvio non sono documentate per terzi)',
    'Plugin di scraper di Nuvio e qualsiasi esecuzione di codice scaricato',
    'Motore torrent integrato (i torrent si risolvono solo con un servizio debrid configurato)',
    'Trakt / Simkl',
    'Widget e notifiche di nuovi episodi',
    'Tema chiaro',
  ];

  static const _licenses = [
    (
      'media_kit, libmpv e FFmpeg',
      'LGPL: motore di riproduzione per MKV, AVI, TS e altri formati.',
      'Il motore usa media_kit (MIT) con libmpv (LGPL-2.1 o successiva) e FFmpeg (LGPL-2.1 o successiva), che includono libass, dav1d, FreeType, HarfBuzz, FriBidi, libplacebo e altre librerie con le rispettive licenze (LGPL, BSD, MIT, ISC, MPL). Le librerie sono quelle pubblicate dal pacchetto media_kit_libs; il codice sorgente completo è disponibile presso i rispettivi progetti.',
    ),
    (
      'Flutter e pacchetti Dart',
      'BSD-3-Clause e MIT: Flutter, Riverpod, go_router, Dio, file_picker e altri.',
      'Aether è scritto con Flutter (BSD-3-Clause) e usa pacchetti open source con licenze permissive (MIT, BSD, Apache-2.0). L’elenco completo con i testi delle licenze è in «Licenze open source» qui sotto.',
    ),
    (
      'liquid_glass_renderer',
      'MIT: il vetro con rifrazione della barra in basso e dei pannelli.',
      'Il Liquid Glass con rifrazione usa il pacchetto liquid_glass_renderer (MIT). Richiede Impeller e Flutter GPU; senza, Aether usa il vetro sfocato.',
    ),
    (
      'TMDB e fanart.tv',
      'Dati e immagini: servono le tue chiavi gratuite.',
      'Questo prodotto usa le API di TMDB ma non è approvato né certificato da TMDB. I loghi dei titoli vengono da fanart.tv con la tua chiave. Le immagini e i dati appartengono ai rispettivi proprietari.',
    ),
    (
      'Protocollo degli addon Stremio',
      'Specifica consultata; nessun codice copiato.',
      'Aether implementa il protocollo pubblico degli addon descritto in stremio-addon-sdk (MIT). Il codice di stremio-web (GPL-2.0), stremio-core e NuvioMobile (GPL-3.0) è stato studiato solo come riferimento di comportamento: nessun codice, grafica, nome o icona è stato copiato o tradotto.',
    ),
  ];

  @override
  Widget build(BuildContext context) => SettingsPageFrame(
    title: 'Informazioni',
    children: [
      const SizedBox(height: 4),
      const Center(child: AboutLogo()),
      const SizedBox(height: 10),
      const Center(
        child: Text(
          'Aether',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
      ),
      Center(
        child: Text(
          'Versione $appVersion',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      const SizedBox(height: 14),
      const Center(child: TheaterLogo()),
      const SizedBox(height: 18),
      SettingsGroup(
        title: 'Cos’è',
        icon: Icons.auto_awesome_rounded,
        children: const [
          _AboutText(
            'Aether è un media center che parla il protocollo degli addon Stremio. È un’app indipendente: codice, nome, interfaccia e icona sono originali e non è affiliata a Stremio né a Nuvio.',
          ),
          _AboutText(
            'Aether non fornisce contenuti: mostra e riproduce ciò che gli addon che installi restituiscono. Gli addon sono servizi di terze parti e la responsabilità di ciò che installi è tua.',
          ),
        ],
      ),
      SettingsGroup(
        title: 'Privacy',
        icon: Icons.privacy_tip_rounded,
        children: const [
          _AboutText(
            'Nessun account, nessun analytics, nessun invio di dati a server di Aether. Cronologia, libreria e impostazioni restano sul dispositivo; gli indirizzi degli addon (che possono contenere chiavi) e le chiavi dei servizi sono nell’archivio sicuro del sistema. Per «Salta intro» Aether chiede a IntroDB i tempi dell’episodio (codice IMDb, stagione ed episodio); si può spegnere in Impostazioni ▸ Riproduzione.',
          ),
        ],
      ),
      SettingsGroup(
        title: 'Cosa non c’è',
        icon: Icons.remove_circle_outline_rounded,
        children: [
          for (final line in _notThere)
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.remove_circle_outline_rounded,
                size: 18,
                color: AetherTokens.textTertiary,
              ),
              title: Text(
                line,
                style: const TextStyle(
                  fontSize: 13,
                  color: AetherTokens.textSecondary,
                ),
              ),
            ),
        ],
      ),
      SettingsGroup(
        title: 'Componenti di terze parti',
        icon: Icons.inventory_2_rounded,
        children: [
          for (final l in _licenses)
            NavRow(
              icon: Icons.description_outlined,
              title: l.$1,
              subtitle: l.$2,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPageFrame(
                    title: l.$1,
                    children: [
                      Text(
                        l.$2,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      Text(l.$3),
                    ],
                  ),
                ),
              ),
            ),
          NavRow(
            icon: Icons.menu_book_rounded,
            title: 'Licenze open source (elenco completo)',
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

class _AboutText extends StatelessWidget {
  const _AboutText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, color: AetherTokens.textSecondary),
      ),
    ),
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
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final hide = ref.watch(
              settingsProvider.select((s) => s.hideTalkShows),
            );
            final credits = [
              for (final c in snap.data ?? const <PersonCredit>[])
                if (!hide || !c.genreIds.contains(kTmdbTalkGenre)) c,
            ];
            if (credits.isEmpty) {
              return const EmptyState(
                icon: Icons.person_search_rounded,
                title: 'Nessun titolo',
                message: 'TMDB non ha restituito titoli: controlla la chiave in Impostazioni ▸ Servizi.',
              );
            }
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
