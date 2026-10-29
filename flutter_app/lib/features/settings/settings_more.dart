import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/hooks.dart';
import '../../app/providers.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';
import '../../design/widgets.dart' show PosterImage;
import 'settings_extra.dart';
import 'settings_widgets.dart';

bool _watchlist(AppSettings s) => s.notifyWatchlist;
double _days(AppSettings s) => s.calendarDays.toDouble();
bool _backdrop(AppSettings s) => s.animatedBackdrop;
bool _alt(AppSettings s) => s.alternatePosters;
String _mode(AppSettings s) => s.themeMode;
int _lead(AppSettings s) => s.notifyLeadMin;
String _daysFmt(double v) => '${v.round()} giorni';

/// The settings that are shared by the whole app: look extras (light theme, shareable themes, animated art, other posters).
class ThemeExtrasPage extends ConsumerWidget {
  const ThemeExtrasPage({super.key});

  static const _prefix = 'aether-theme:';

  /// The theme as a short text that can be sent to a friend.
  static String export(AppSettings s) {
    final m = <String, Object?>{
      'palette': s.palette,
      'accentHex': s.accentHex,
      'amoled': s.amoled,
      'titleFont': s.titleFont,
      'themeMode': s.themeMode,
      'uiFont': s.ext['uiFont'],
      'customBackgroundHex': s.ext['customBackgroundHex'],
    }..removeWhere((_, v) => v == null);
    return _prefix + base64Url.encode(utf8.encode(jsonEncode(m)));
  }

  /// Applies a theme text; `null` when it is not one.
  static AppSettings? import(AppSettings s, String text) {
    final t = text.trim();
    if (!t.startsWith(_prefix)) return null;
    try {
      final m = jsonDecode(
        utf8.decode(base64Url.decode(t.substring(_prefix.length))),
      );
      if (m is! Map) return null;
      var out = s;
      final hex = m['accentHex'];
      if (m['palette'] is String) {
        out = out.copyWith(palette: m['palette'] as String);
      }
      if (hex is String && RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(hex)) {
        out = out.copyWith(accentHex: hex);
      }
      if (m['amoled'] is bool) out = out.copyWith(amoled: m['amoled'] as bool);
      if (m['titleFont'] is String) {
        out = out.copyWith(titleFont: m['titleFont'] as String);
      }
      for (final k in const ['themeMode', 'uiFont', 'customBackgroundHex']) {
        final v = m[k];
        if (v is String &&
            (k != 'customBackgroundHex' ||
                RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(v))) {
          out = out.withExt(k, v);
        }
      }
      return out;
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    void say(String m) =>
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    return SettingsPageFrame(
      title: 'Aspetto',
      children: [
        SettingsGroup(
          title: 'Tema chiaro e condivisione',
          children: [
            NavRow(
              icon: Icons.ios_share_rounded,
              title: 'Copia il mio tema',
              subtitle: 'Palette, accento, font e modalità, come testo da condividere',
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: export(s)));
                say('Tema copiato negli appunti');
              },
            ),
            NavRow(
              icon: Icons.content_paste_rounded,
              title: 'Incolla un tema',
              subtitle: 'Applica il tema che hai copiato da un altro Aether',
              onTap: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                final applied = import(s, data?.text ?? '');
                if (applied == null) {
                  say('Negli appunti non c’è un tema di Aether');
                } else {
                  n.update((_) => applied);
                  say('Tema applicato');
                }
              },
            ),
          ],
        ),
        SettingsGroup(
          title: 'Sfondi animati e locandine',
          children: [
            const PrefSwitch(
              'animatedBackdrop',
              'Sfondo animato nelle schede',
              _backdrop,
              subtitle: 'Lenta panoramica sull’immagine in cima alla scheda del titolo',
            ),
            const PrefSwitch(
              'alternatePosters',
              'Locandine alternative',
              _alt,
              subtitle: 'Mostra «Cambia locandina» nella scheda e usa la scelta ovunque',
            ),
            NavRow(
              icon: Icons.restore_rounded,
              title: 'Ripristina le locandine originali',
              subtitle: s.posterOverrides.isEmpty
                  ? 'Nessuna locandina cambiata'
                  : '${s.posterOverrides.length} locandine cambiate',
              onTap: () {
                n.update((x) => x.withExt('posterOverrides', null));
                PosterImage.overrides = const {};
                say('Locandine originali ripristinate');
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Calendar of the releases and the notifications for new episodes.
class CalendarSettingsPage extends ConsumerWidget {
  const CalendarSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsPageFrame(
      title: 'Contenuti e scoperta',
      children: [
        SettingsGroup(
          title: 'Calendario e notifiche',
          children: [
            SwitchRow(
              title: 'Avvisami dei nuovi episodi',
              subtitle: 'Notifica sul telefono quando esce un episodio delle serie che segui',
              value: s.notifyNewEpisodes,
              onChanged: (v) async {
                if (v &&
                    !await ref.read(notifierProvider).requestPermission()) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Consenti le notifiche di Aether nelle impostazioni del telefono',
                        ),
                      ),
                    );
                  }
                  return;
                }
                n.update((x) => x.withExt('notifyNewEpisodes', v));
              },
            ),
            const PrefChoice<int>('notifyLeadMin', 'Quando avvisare', _lead, {
              0: 'All’uscita',
              60: '1 ora prima',
              360: '6 ore prima',
              1440: '1 giorno prima',
            }),
            const PrefSwitch(
              'notifyWatchlist',
              'Segui anche watchlist e preferiti',
              _watchlist,
              subtitle: 'Altrimenti solo le serie che stai guardando',
            ),
            const PrefSlider(
              'calendarDays',
              'Calendario: giorni in avanti',
              _days,
              min: 7,
              max: 90,
              divisions: 12,
              integer: true,
              format: _daysFmt,
            ),
            NavRow(
              icon: Icons.event_rounded,
              title: 'Apri il calendario',
              onTap: () => context.push('/calendar'),
            ),
            NavRow(
              icon: Icons.insights_rounded,
              title: 'Statistiche di visione',
              onTap: () => context.push('/stats'),
            ),
          ],
        ),
      ],
    );
  }
}

/// What the viewer does not want to see anywhere (Home, Scopri, Cerca, titoli simili, filmografie).
class HiddenContentSettingsPage extends StatelessWidget {
  const HiddenContentSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const SettingsPageFrame(
    title: 'Contenuti e scoperta',
    children: [
      SettingsGroup(
        title: 'Contenuti da nascondere',
        children: [
          PrefSwitch(
            'hideTalkShows',
            'Nascondi i talk show',
            _hideTalk,
            subtitle: 'Non compaiono in Home, Scopri, Cerca, titoli simili, stessi attori e filmografie',
          ),
        ],
      ),
    ],
  );
}

bool _hideTalk(AppSettings s) => s.hideTalkShows;

/// The theme on top of the look page, like iOS Settings: the choice dark / light / automatic.
class ThemeQuickSettings extends StatelessWidget {
  const ThemeQuickSettings({super.key});

  @override
  Widget build(BuildContext context) => const SettingsGroup(
    title: 'Tema',
    children: [
      PrefChoice<String>('themeMode', 'Aspetto dell’app', _mode, {
        'dark': 'Scuro',
        'light': 'Chiaro',
        'auto': 'Automatico',
      }),
    ],
  );
}
