import 'package:flutter/material.dart';

import '../../design/image_cache.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';
import '../player/subtitle_style.dart';
import '../home/home_screen.dart' show visibleCatalogs, typeName;
import 'settings_extra.dart';
import 'settings_widgets.dart';

const _badgeKinds = {
  'quality': 'Risoluzione (4K, 1080p…)',
  'codec': 'Codec video (HEVC, H.264…)',
  'hdr': 'HDR e Dolby Vision',
  'audio': 'Audio (Atmos, DTS, Dolby…)',
  'language': 'Lingue',
  'size': 'Dimensione del file',
  'format': 'Formato del file (MKV, MP4…)',
};

/// Settings ▸ Sorgenti: how the list of sources is ordered, filtered and drawn.
bool _bg(AppSettings s) => s.backgroundDownloads;

class SourcesPage extends ConsumerWidget {
  const SourcesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsPageFrame(
      title: 'Sorgenti',
      children: [
        SettingsGroup(
          title: 'Ordine e scelta',
          footer: '«Per addon» rispetta l’ordine degli addon (Addon ▸ frecce): dentro ogni addon le sorgenti migliori vengono prima. «Per qualità» mescola tutto in un’unica lista.',
          children: [
            const PrefChoice<String>(
              'streamOrdering',
              'Ordine delle sorgenti',
              _ordering,
              {'byAddon': 'Per addon', 'byQuality': 'Per qualità'},
            ),
            const PrefChoice<int>(
              'qualityCap',
              'Qualità massima',
              _cap,
              kQualityOptions,
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
            const PrefSwitch(
              'autoSelectStream',
              'Scegli automaticamente la sorgente migliore',
              _auto,
              subtitle: 'Tocca «Guarda» e parte la prima sorgente che si apre senza chiedere nulla',
            ),
          ],
        ),
        SettingsGroup(
          title: 'Aspetto delle righe',
          children: [
            const PrefChoice<String>(
              'badgeStyle',
              'Stile dei badge',
              _badgeStyle,
              {
                'filled': 'Pieni',
                'outline': 'Con contorno',
                'plain': 'Solo testo',
              },
            ),
            const PrefSwitch(
              'showAddonLogo',
              'Nome dell’addon sulla riga',
              _logo,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Badge da mostrare',
          children: [
            for (final e in _badgeKinds.entries)
              SwitchRow(
                title: e.value,
                value: !s.hiddenBadges.contains(e.key),
                onChanged: (v) => n.update((x) {
                  final hidden = {...x.hiddenBadges};
                  v ? hidden.remove(e.key) : hidden.add(e.key);
                  return x.withExt('hiddenBadges', hidden.toList());
                }),
              ),
          ],
        ),
      ],
    );
  }

  static String _ordering(AppSettings s) => s.streamOrdering;
  static int _cap(AppSettings s) => s.qualityCap;
  static bool _auto(AppSettings s) => s.autoSelectStream;
  static String _badgeStyle(AppSettings s) => s.badgeStyle;
  static bool _logo(AppSettings s) => s.showAddonLogo;
}

/// Settings ▸ Metadati: what TMDB and MDBList add to the title page, and how often catalogs refresh.
class MetadataPage extends ConsumerWidget {
  const MetadataPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsPageFrame(
      title: 'Cataloghi e ricerca',
      children: [
        const _DiscoverGroup(),
        SettingsGroup(
          title: 'Cataloghi e cache',
          children: [
            const PrefSlider(
              'catalogRefreshMin',
              'Aggiorna i cataloghi ogni',
              _refresh,
              min: 0,
              max: 120,
              divisions: 24,
              integer: true,
              format: _minutes,
            ),
            const PrefSwitch(
              'cacheMetadata',
              'Salva in cache metadati e cataloghi',
              _cache,
            ),
            const PrefChoice<String>(
              'searchSort',
              'Ordinamento dei risultati',
              _sort,
              {
                'relevance': 'Rilevanza',
                'year': 'Anno (più recenti)',
                'name': 'Nome',
              },
            ),
            const PrefSwitch(
              'searchLibrary',
              'Cerca anche nella libreria',
              _searchLib,
            ),
            const PrefSwitch(
              'saveSearchHistory',
              'Salva le ricerche recenti',
              _history,
            ),
          ],
        ),
      ],
    );
  }

  static double _refresh(AppSettings s) => s.catalogRefreshMin.toDouble();
  static String _minutes(double v) =>
      v == 0 ? 'ogni volta' : '${v.round()} min';
  static bool _cache(AppSettings s) => s.cacheMetadata;
  static String _sort(AppSettings s) => s.searchSort;
  static bool _searchLib(AppSettings s) => s.searchLibrary;
  static bool _history(AppSettings s) => s.saveSearchHistory;
}

/// Settings ▸ Download e archiviazione, including the season-download policy.
class DownloadsSettingsPage extends ConsumerWidget {
  const DownloadsSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final addons = ref.watch(addonsProvider);
    return SettingsPageFrame(
      title: 'Download e archiviazione',
      children: [
        SettingsGroup(
          title: 'Download',
          children: [
            const PrefSlider(
              'maxDownloads',
              'Download simultanei',
              _max,
              min: 1,
              max: 5,
              divisions: 4,
              integer: true,
              format: _int,
            ),
            const PrefSwitch(
              'backgroundDownloads',
              'Scarica anche con l’app chiusa (iOS)',
              _bg,
              subtitle: 'Il sistema porta avanti i download in background',
            ),
            const PrefSwitch(
              'downloadOverCellular',
              'Scarica anche con dati mobili',
              _cell,
            ),
            const PrefSwitch(
              'deleteAfterWatching',
              'Elimina i download dopo la visione',
              _del,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Download di una stagione',
          footer: 'Per ogni episodio Aether cerca le sorgenti negli addon, applica queste regole e prova la successiva se una non si può usare. Gli episodi senza sorgente adatta vengono saltati.',
          children: [
            const PrefChoice<int>(
              'seasonQuality',
              'Qualità',
              _sq,
              kQualityOptions,
            ),
            PrefChoice<String>('seasonLanguage', 'Lingua', _sl, {
              'preferred': 'Lingua audio preferita',
              'any': 'Qualsiasi',
              for (final e in kLangOptions.entries)
                if (e.key != 'off') e.key: e.value,
            }),
            const PrefChoice<String>('seasonSizePolicy', 'Peso dei file', _sp, {
              'preferSmaller': 'File più leggeri',
              'any': 'Qualsiasi peso (qualità prioritaria)',
            }),
          ],
        ),
        if (addons.isNotEmpty)
          SettingsGroup(
            title: 'Addon usati per le stagioni',
            children: [
              for (final a in addons)
                SwitchRow(
                  title: a.displayName,
                  value: !s.seasonDisabledAddons.contains(a.id),
                  onChanged: (v) => n.update((x) {
                    final off = {...x.seasonDisabledAddons};
                    v ? off.remove(a.id) : off.add(a.id);
                    return x.withExt('seasonDisabledAddons', off.toList());
                  }),
                ),
            ],
          ),
        SettingsGroup(
          title: 'Archiviazione',
          children: [
            const PrefSlider(
              'imageCacheMB',
              'Limite della cache delle immagini',
              _img,
              min: 50,
              max: 1000,
              divisions: 19,
              integer: true,
              format: _mb,
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.image_not_supported_outlined),
              title: const Text('Svuota la cache delle immagini'),
              onTap: () async {
                await AetherImageCache.manager.emptyCache();
                PaintingBinding.instance.imageCache.clear();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Cache delle immagini svuotata.'),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  static double _img(AppSettings s) => s.imageCacheMB.toDouble();
  static String _mb(double v) => '${v.round()} MB (dal prossimo avvio)';
  static double _max(AppSettings s) => s.maxDownloads.toDouble();
  static String _int(double v) => '${v.round()}';
  static bool _cell(AppSettings s) => s.downloadOverCellular;
  static bool _del(AppSettings s) => s.deleteAfterWatching;
  static int _sq(AppSettings s) => s.seasonQuality;
  static String _sl(AppSettings s) => s.seasonLanguage;
  static String _sp(AppSettings s) => s.seasonSizePolicy;
}

/// Settings ▸ Player avanzato.
class PlayerAdvancedPage extends ConsumerWidget {
  const PlayerAdvancedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsPageFrame(
      title: 'Player avanzato',
      children: [
        SettingsGroup(
          title: 'Controlli e gesti',
          children: [
            const PrefSwitch(
              'gestures',
              'Gesti (luminosità, volume, doppio tocco)',
              _gest,
            ),
            const PrefSlider(
              'skipBackSec',
              'Salto indietro',
              _sb,
              min: 5,
              max: 60,
              divisions: 11,
              integer: true,
              format: _sec,
            ),
            const PrefSlider(
              'skipForwardSec',
              'Salto avanti',
              _sf,
              min: 5,
              max: 60,
              divisions: 11,
              integer: true,
              format: _sec,
            ),
            const PrefSlider(
              'controlsHideSec',
              'Nascondi i controlli dopo',
              _hide,
              min: 2,
              max: 15,
              divisions: 13,
              integer: true,
              format: _sec,
            ),
            const PrefSwitch(
              'holdToSpeed',
              'Tieni premuto per accelerare',
              _hold,
            ),
            const PrefSlider(
              'holdSpeed',
              'Velocità con pressione prolungata',
              _hs,
              min: 1.25,
              max: 4,
              divisions: 11,
              format: _x,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Ripresa e fine episodio',
          children: [
            const PrefSlider(
              'resumeRewindSec',
              'Riavvolgi alla ripresa di',
              _rw,
              min: 0,
              max: 30,
              divisions: 30,
              integer: true,
              format: _sec,
            ),
            const PrefSlider(
              'watchedThreshold',
              'Segna come visto oltre',
              _thr,
              min: 0.5,
              max: 0.99,
              divisions: 49,
              format: _pct,
            ),
            const PrefSlider(
              'nextCountdownSec',
              'Conto alla rovescia del prossimo episodio',
              _cd,
              min: 3,
              max: 30,
              divisions: 27,
              integer: true,
              format: _sec,
            ),
            const PrefSlider(
              'sleepTimerMin',
              'Timer di spegnimento predefinito',
              _sleep,
              min: 0,
              max: 120,
              divisions: 24,
              integer: true,
              format: _sleepFmt,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Prossimo episodio e titoli di coda',
          footer: 'I titoli di coda si riconoscono dai dati di IntroDB quando ci sono, altrimenti dagli ultimi secondi del video.',
          children: const [
            PrefSwitch(
              'skipCredits',
              'Scheda «Prossimo episodio» nei titoli di coda',
              _skipCredits,
              subtitle: 'Con l’anteprima dell’episodio, «Guarda ora» e «Resta»',
            ),
            PrefSwitch(
              'nextPreview',
              'Anteprima con l’immagine dell’episodio',
              _nextPreview,
            ),
            PrefSwitch(
              'autoNextAtCredits',
              'Passa da solo al prossimo episodio all’inizio dei titoli',
              _autoNextCredits,
              subtitle: 'Parte il conto alla rovescia; si può annullare',
            ),
            PrefSlider(
              'creditsSec',
              'Titoli di coda: ultimi secondi',
              _creditsSec,
              min: 20,
              max: 300,
              divisions: 28,
              integer: true,
              format: _sec,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Fonti e schermata di blocco',
          children: const [
            PrefSwitch(
              'autoSwitchSource',
              'Cambia fonte da sola se non parte',
              _autoSwitch,
              subtitle: 'Prova fino a tre fonti alternative',
            ),
            PrefSwitch(
              'nowPlaying',
              'Controlli nella schermata di blocco (iPhone)',
              _nowPlaying,
              subtitle: 'Titolo, avanzamento, play/pausa, ±10 s e episodio successivo',
            ),
          ],
        ),
        SettingsGroup(
          title: 'Lingue di riserva',
          children: [
            const PrefChoice<String>(
              'fallbackAudio',
              'Audio di riserva',
              _fa,
              kLangOptions,
            ),
            const PrefChoice<String>(
              'fallbackSubtitle',
              'Sottotitoli di riserva',
              _fs,
              kLangOptions,
            ),
          ],
        ),
        const SettingsGroup(
          title: 'Stile dei sottotitoli',
          icon: Icons.subtitles_rounded,
          children: [SubtitleStyleControls()],
        ),
        SettingsGroup(
          title: 'Immagine (motore libmpv)',
          footer: 'Valgono per i video riprodotti da Aether. Non provate su un telefono.',
          children: [
            const PrefSwitch('hwDecoding', 'Decodifica hardware', _hw),
            const PrefSwitch('deband', 'Riduci le bande di colore', _db),
            const PrefChoice<String>(
              'toneMapping',
              'HDR su schermo SDR: tone mapping',
              _tone,
              {
                'auto': 'Automatico',
                'bt.2390': 'BT.2390 (fedele)',
                'hable': 'Hable (filmico)',
                'mobius': 'Mobius (morbido)',
                'reinhard': 'Reinhard',
                'spline': 'Spline',
                'clip': 'Taglia i picchi',
              },
            ),
            const PrefSwitch(
              'hdrComputePeak',
              'Misura il picco di luce scena per scena',
              _hdrPeak,
            ),
            const PrefSlider(
              'targetPeak',
              'Luminosità dello schermo (nit, 0 = automatica)',
              _targetPeak,
              min: 0,
              max: 1000,
              divisions: 20,
              integer: true,
              format: _nit,
            ),
            const PrefSlider(
              'imgBrightness',
              'Luminosità',
              _ib,
              min: -50,
              max: 50,
              divisions: 20,
              integer: true,
              format: _int,
            ),
            const PrefSlider(
              'imgContrast',
              'Contrasto',
              _ic,
              min: -50,
              max: 50,
              divisions: 20,
              integer: true,
              format: _int,
            ),
            const PrefSlider(
              'imgSaturation',
              'Saturazione',
              _is,
              min: -50,
              max: 50,
              divisions: 20,
              integer: true,
              format: _int,
            ),
            const PrefSlider(
              'imgGamma',
              'Gamma',
              _ig,
              min: -50,
              max: 50,
              divisions: 20,
              integer: true,
              format: _int,
            ),
            const PrefSlider(
              'bufferSec',
              'Buffer (0 = automatico)',
              _buf,
              min: 0,
              max: 120,
              divisions: 24,
              integer: true,
              format: _sec,
            ),
          ],
        ),
        SettingsGroup(
          title: 'In sottofondo',
          footer: 'Su Android l’audio continua con lo schermo spento solo se il sistema lo permette; non verificato su un telefono.',
          children: [
            const PrefSwitch(
              'autoPip',
              'Picture-in-Picture automatico (Android)',
              _pip,
            ),
            const PrefSwitch(
              'backgroundAudio',
              'Continua l’audio in background',
              _bg,
            ),
          ],
        ),
      ],
    );
  }

  static bool _gest(AppSettings s) => s.gestures;
  static double _sb(AppSettings s) => s.skipBackSec.toDouble();
  static double _sf(AppSettings s) => s.skipForwardSec.toDouble();
  static double _hide(AppSettings s) => s.controlsHideSec.toDouble();
  static bool _hold(AppSettings s) => s.holdToSpeed;
  static double _hs(AppSettings s) => s.holdSpeed;
  static double _rw(AppSettings s) => s.resumeRewindSec.toDouble();
  static double _thr(AppSettings s) => s.watchedThreshold;
  static double _cd(AppSettings s) => s.nextCountdownSec.toDouble();
  static double _sleep(AppSettings s) => s.sleepTimerMin.toDouble();
  static String _fa(AppSettings s) => s.fallbackAudio;
  static String _fs(AppSettings s) => s.fallbackSubtitle;
  static bool _skipCredits(AppSettings s) => s.skipCredits;
  static bool _nextPreview(AppSettings s) => s.nextPreview;
  static bool _autoNextCredits(AppSettings s) => s.autoNextAtCredits;
  static double _creditsSec(AppSettings s) => s.creditsSec.toDouble();
  static bool _autoSwitch(AppSettings s) => s.autoSwitchSource;
  static bool _nowPlaying(AppSettings s) => s.nowPlaying;
  static String _tone(AppSettings s) => s.toneMapping;
  static bool _hdrPeak(AppSettings s) => s.hdrComputePeak;
  static double _targetPeak(AppSettings s) => s.targetPeak.toDouble();
  static String _nit(double v) => v == 0 ? 'automatica' : '${v.round()} nit';
  static bool _hw(AppSettings s) => s.hwDecoding;
  static bool _db(AppSettings s) => s.deband;
  static double _ib(AppSettings s) => s.imgBrightness.toDouble();
  static double _ic(AppSettings s) => s.imgContrast.toDouble();
  static double _is(AppSettings s) => s.imgSaturation.toDouble();
  static double _ig(AppSettings s) => s.imgGamma.toDouble();
  static double _buf(AppSettings s) => s.bufferSec.toDouble();
  static bool _pip(AppSettings s) => s.autoPip;
  static bool _bg(AppSettings s) => s.backgroundAudio;
  static String _sec(double v) => '${v.round()} s';
  static String _int(double v) => '${v.round()}';
  static String _x(double v) => '${v.toStringAsFixed(2)}×';
  static String _pct(double v) => '${(v * 100).round()}%';
  static String _sleepFmt(double v) => v == 0 ? 'spento' : '${v.round()} min';
}

/// Settings ▸ Personalizzazione: the things that change the feel of the app.
class LookPage extends ConsumerWidget {
  const LookPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final sections = s.homeSections;
    void move(int i, int d) {
      final list = [...sections];
      final j = i + d;
      if (j < 0 || j >= list.length) return;
      final t = list.removeAt(i);
      list.insert(j, t);
      n.update((x) => x.withHomeSections(list));
    }

    return SettingsPageFrame(
      title: 'Personalizzazione',
      children: [
        SettingsGroup(
          title: 'Stili pronti',
          icon: Icons.auto_awesome_rounded,
          footer: 'Un tocco cambia insieme palette, sfondo animato, cornici, angoli, carattere e vetro. Poi puoi ritoccare ogni voce qui sotto.',
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final p in kStylePresets)
                    ActionChip(
                      avatar: Text(p.emoji),
                      label: Text(p.name),
                      onPressed: () => n.update((x) => p.apply(x)),
                    ),
                ],
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: 'Transizioni',
          icon: Icons.slow_motion_video_rounded,
          footer: 'Come si apre la pagina di un titolo. «Automatica» usa lo zoom dalla locandina quando Dynamic Cinematic è attivo.',
          children: const [
            PrefChoice<String>(
              'titleTransition',
              'Apertura di un titolo',
              _transition,
              {
                'auto': 'Automatica',
                'zoom': 'Zoom dalla locandina',
                'fade': 'Dissolvenza',
                'slide': 'Scorrimento',
                'none': 'Nessuna',
              },
            ),
          ],
        ),
        SettingsGroup(
          title: 'Interfaccia',
          icon: Icons.text_fields_rounded,
          children: [
            const PrefChoice<String>('density', 'Densità', _density, {
              'comfortable': 'Comoda',
              'compact': 'Compatta',
            }),
            PrefSlider(
              'textScale',
              'Dimensione del testo',
              (x) => x.textScale,
              min: 0.85,
              max: 1.3,
              divisions: 9,
              format: _pct,
            ),
            const PrefChoice<String>(
              'uiFont',
              'Carattere dell’interfaccia',
              _uiFont,
              {
                'system': 'Sistema',
                'serif': 'Con grazie',
                'mono': 'Monospaziato',
              },
            ),
            const PrefSwitch(
              'coloredIcons',
              'Icone colorate nelle impostazioni',
              _colored,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Colori',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Colore d’accento personalizzato (vale con la palette «Aether»)',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            _AccentField(
              value: s.accentHex,
              onChanged: (v) => n.update((x) => x.copyWith(accentHex: v)),
            ),
            const PrefColor(
              'customBackgroundHex',
              'Colore dello sfondo',
              _bgColor,
              allowNone: true,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Sfondo',
          children: [
            const PrefChoice<String>('backdropStyle', 'Stile', _bd, {
              'aurora': 'Aurora',
              'flow': 'Onde',
              'spotlight': 'Faro',
              'plain': 'Tinta unita',
            }),
            const PrefSlider(
              'backdropIntensity',
              'Intensità dei bagliori',
              _bi,
              min: 0,
              max: 1.5,
              divisions: 15,
              format: _pct,
            ),
            const PrefSwitch('halos', 'Aloni colorati dello sfondo', _halos),
          ],
        ),
        SettingsGroup(
          title: 'Schede e locandine',
          children: [
            const PrefChoice<String>('cardChrome', 'Cornice', _chrome, {
              'standard': 'Standard',
              'outline': 'Contorno',
              'shadow': 'Ombra',
              'glow': 'Alone',
            }),
            const PrefChoice<String>('cornerStyle', 'Angoli', _corner, {
              'sharp': 'Netti',
              'standard': 'Standard',
              'rounded': 'Morbidi',
              'bubble': 'Bolle',
            }),
            const PrefChoice<String>(
              'posterSize',
              'Dimensione delle locandine',
              _size,
              {'small': 'Piccola', 'medium': 'Media', 'large': 'Grande'},
            ),
            const PrefSwitch(
              'posterRatings',
              'Voto sulle locandine',
              _posterRatings,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Movimento',
          children: [
            const PrefSwitch(
              'animations',
              'Animazioni',
              _anim,
              subtitle: 'Spento = nessuna dissolvenza né zoom lento',
            ),
          ],
        ),
        SettingsGroup(
          title: 'In evidenza',
          children: [
            const PrefChoice<String>('heroStyle', 'Aspetto', _hero, {
              'card': 'Card',
              'fullBleed': 'Schermo intero',
            }),
            const PrefSwitch(
              'heroAutoScroll',
              'Scorrimento automatico',
              _heroAuto,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Sezioni della Home',
          footer: 'Sposta con le frecce, spegni quelle che non vuoi.',
          children: [
            SwitchRow(
              title: 'Mostra «Continua a guardare»',
              value: s.showContinueWatching,
              onChanged: (v) =>
                  n.update((x) => x.copyWith(showContinueWatching: v)),
            ),
            for (var i = 0; i < sections.length; i++)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 4, right: 4),
                leading: Switch(
                  value: sections[i].visible,
                  onChanged: (v) {
                    final list = [...sections];
                    list[i] = HomeSection(sections[i].id, v);
                    n.update((x) => x.withHomeSections(list));
                  },
                ),
                title: Text(
                  kHomeSectionTitles[sections[i].id] ?? sections[i].id,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Sposta su',
                      icon: const Icon(Icons.keyboard_arrow_up_rounded),
                      onPressed: i == 0 ? null : () => move(i, -1),
                    ),
                    IconButton(
                      tooltip: 'Sposta giù',
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      onPressed: i == sections.length - 1
                          ? null
                          : () => move(i, 1),
                    ),
                  ],
                ),
              ),
            TextButton(
              onPressed: () => n.update((x) => x.withExt('homeSections', null)),
              child: const Text('Ripristina la Home'),
            ),
          ],
        ),
      ],
    );
  }

  static String _transition(AppSettings s) => s.titleTransition;
  static String _density(AppSettings s) =>
      s.ext['density'] == 'compact' ? 'compact' : 'comfortable';
  static String _uiFont(AppSettings s) => s.uiFont;
  static bool _colored(AppSettings s) => s.coloredIcons;
  static String? _bgColor(AppSettings s) => s.customBackgroundHex;
  static String _bd(AppSettings s) => s.backdropStyle;
  static double _bi(AppSettings s) => s.backdropIntensity;
  static bool _halos(AppSettings s) => s.halos;
  static String _chrome(AppSettings s) => s.cardChrome;
  static String _corner(AppSettings s) => s.cornerStyle;
  static String _size(AppSettings s) => s.posterSize;
  static bool _posterRatings(AppSettings s) => s.posterRatings;
  static bool _anim(AppSettings s) => s.animations;
  static String _hero(AppSettings s) => s.heroStyle;
  static bool _heroAuto(AppSettings s) => s.heroAutoScroll;
  static String _pct(double v) => '${(v * 100).round()}%';
}

class _AccentField extends StatelessWidget {
  const _AccentField({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
    child: SizedBox(
      width: 170,
      child: TextFormField(
        key: ValueKey(value),
        initialValue: value,
        maxLength: 7,
        decoration: const InputDecoration(
          labelText: 'Esadecimale (#RRGGBB)',
          counterText: '',
        ),
        onFieldSubmitted: (v) {
          final t = v.trim().startsWith('#') ? v.trim() : '#${v.trim()}';
          if (RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(t))
            onChanged(t.toUpperCase());
        },
      ),
    ),
  );
}

/// A ready-made look: one tap sets palette, animated background, frame, corners, fonts and glass together.
class StylePreset {
  const StylePreset(this.name, this.emoji, this._apply);
  final String name;
  final String emoji;
  final AppSettings Function(AppSettings) _apply;
  AppSettings apply(AppSettings s) => _apply(s);
}

AppSettings _preset(
  AppSettings s, {
  required String palette,
  required String backdrop,
  required String chrome,
  required String corner,
  String titleFont = 'standard',
  String uiFont = 'system',
  double glass = 0.45,
  bool amoled = false,
  bool compact = false,
  String poster = 'medium',
  double intensity = 1,
}) => s
    .copyWith(
      palette: palette,
      titleFont: titleFont,
      glassIntensity: glass,
      amoled: amoled,
    )
    .withExt('backdropStyle', backdrop)
    .withExt('cardChrome', chrome)
    .withExt('cornerStyle', corner)
    .withExt('uiFont', uiFont)
    .withExt('density', compact ? 'compact' : 'comfortable')
    .withExt('posterSize', poster)
    .withExt('backdropIntensity', intensity);

final kStylePresets = <StylePreset>[
  StylePreset(
    'Aether',
    '✨',
    (s) => _preset(
      s,
      palette: 'aether',
      backdrop: 'aurora',
      chrome: 'standard',
      corner: 'standard',
    ),
  ),
  StylePreset(
    'Cinema',
    '🎞️',
    (s) => _preset(
      s,
      palette: 'cinema',
      backdrop: 'spotlight',
      chrome: 'outline',
      corner: 'sharp',
      titleFont: 'serif',
      glass: 0.3,
      poster: 'large',
    ),
  ),
  StylePreset(
    'Neon',
    '🌌',
    (s) => _preset(
      s,
      palette: 'midnight',
      backdrop: 'flow',
      chrome: 'glow',
      corner: 'bubble',
      titleFont: 'mono',
      glass: 0.6,
      intensity: 1.3,
    ),
  ),
  StylePreset(
    'Minimale',
    '▫️',
    (s) => _preset(
      s,
      palette: 'aether',
      backdrop: 'plain',
      chrome: 'standard',
      corner: 'rounded',
      glass: 0.2,
      amoled: true,
      compact: true,
      poster: 'small',
    ),
  ),
  StylePreset(
    'Pastello',
    '🍬',
    (s) => _preset(
      s,
      palette: 'candy',
      backdrop: 'aurora',
      chrome: 'shadow',
      corner: 'rounded',
      glass: 0.7,
    ),
  ),
  StylePreset(
    'Oceano',
    '🌊',
    (s) => _preset(
      s,
      palette: 'ocean',
      backdrop: 'flow',
      chrome: 'standard',
      corner: 'bubble',
      glass: 0.5,
      intensity: 1.2,
    ),
  ),
  StylePreset(
    'Tramonto',
    '🌅',
    (s) => _preset(
      s,
      palette: 'sunset',
      backdrop: 'aurora',
      chrome: 'glow',
      corner: 'rounded',
      glass: 0.55,
      intensity: 1.2,
    ),
  ),
];

/// Settings ▸ Scopri: which types appear, and which catalog opens first for each.
class _DiscoverGroup extends ConsumerWidget {
  const _DiscoverGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final cats = visibleCatalogs(
      ref.watch(addonsProvider),
      s.hiddenHomeCatalogs,
      s.catalogOrder,
      hideAdult: s.hideAdultCatalogs,
    );
    final types = {for (final e in cats) e.$2.type}.toList();
    if (types.isEmpty) return const SizedBox.shrink();
    return SettingsGroup(
      title: 'Scopri',
      icon: Icons.explore_rounded,
      footer: 'Scegli i tipi che compaiono in Scopri e il catalogo che si apre per primo.',
      children: [
        for (final t in types) ...[
          SwitchRow(
            title: typeName(t),
            value: !s.discoverHidden.contains(t),
            onChanged: (v) => n.update((x) {
              final h = {...x.discoverHidden};
              v ? h.remove(t) : h.add(t);
              return x.withExt('discoverHidden', h.toList());
            }),
          ),
          if (!s.discoverHidden.contains(t))
            ChoiceRow<String>(
              title: '   Catalogo iniziale',
              value: s.discoverDefaultFor(t) ?? '',
              options: {
                '': 'Il primo disponibile',
                for (final e in cats.where((e) => e.$2.type == t))
                  '${e.$1.id}/${e.$2.key}':
                      s.catalogTitles['${e.$1.id}/${e.$2.key}'] ?? e.$2.name,
              },
              onChanged: (k) => n.update(
                (x) => x.withDiscoverDefault(t, k.isEmpty ? null : k),
              ),
            ),
        ],
      ],
    );
  }
}
