import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../design/glass.dart';
import '../settings/settings_widgets.dart';
import 'theater_prefs.dart';

/// «Altro» of Theater Mode: its own look settings, the debrid service, and the way to the classic settings pages (which open
/// on top, in landscape).
class TheaterMore extends ConsumerWidget {
  const TheaterMore({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final t = s.theater;
    void set(TheaterPrefs Function(TheaterPrefs) f) =>
        n.update((x) => x.copyWith(theater: f(x.theater)));
    return AetherBackdrop(
      child: SafeArea(
        left: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(8, 16, 24, 40),
          children: [
            Text('Altro', style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 12),
            SettingsGroup(
              title: 'Colori',
              children: [
                ChoiceRow<int>(
                  title: 'Colore d’accento',
                  value: t.palette,
                  options: {
                    for (final p in TheaterPalette.values) p.index: p.title,
                  },
                  onChanged: (v) => set((x) => x.copyWith(palette: v)),
                ),
                ChoiceRow<int>(
                  title: 'Sfondo',
                  value: t.background,
                  options: const {
                    0: 'Nero puro',
                    1: 'Sfumato',
                    2: 'Sala (fascio di luce)',
                  },
                  onChanged: (v) => set((x) => x.copyWith(background: v)),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Locandine',
              children: [
                ChoiceRow<int>(
                  title: 'Dimensione',
                  value: t.cardSize,
                  options: const {0: 'Piccole', 1: 'Medie', 2: 'Grandi'},
                  onChanged: (v) => set((x) => x.copyWith(cardSize: v)),
                ),
                SwitchRow(
                  title: 'Locandine verticali',
                  value: t.portraitCards,
                  onChanged: (v) => set((x) => x.copyWith(portraitCards: v)),
                ),
                SwitchRow(
                  title: 'Titolo sotto ogni locandina',
                  value: t.titles,
                  onChanged: (v) => set((x) => x.copyWith(titles: v)),
                ),
                SwitchRow(
                  title: 'Anno e genere',
                  value: t.details,
                  onChanged: (v) => set((x) => x.copyWith(details: v)),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Cornici',
              children: [
                ChoiceRow<int>(
                  title: 'Angoli',
                  value: t.corners,
                  options: const {0: 'Netti', 1: 'Morbidi', 2: 'Arrotondati'},
                  onChanged: (v) => set((x) => x.copyWith(corners: v)),
                ),
                ChoiceRow<int>(
                  title: 'Bordo',
                  value: t.border,
                  options: const {
                    0: 'Nessuno',
                    1: 'Sottile',
                    2: 'Colore d’accento',
                  },
                  onChanged: (v) => set((x) => x.copyWith(border: v)),
                ),
                SwitchRow(
                  title: 'Alone sulla locandina selezionata',
                  value: t.glow,
                  onChanged: (v) => set((x) => x.copyWith(glow: v)),
                ),
                ChoiceRow<int>(
                  title: 'Titoli delle righe',
                  value: t.rowStyle,
                  options: const {
                    0: 'Normale',
                    1: 'Con grazie',
                    2: 'Maiuscoletto',
                  },
                  onChanged: (v) => set((x) => x.copyWith(rowStyle: v)),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Righe e barra',
              children: [
                SwitchRow(
                  title: 'Fori della pellicola sulle righe',
                  value: t.sprockets,
                  onChanged: (v) => set((x) => x.copyWith(sprockets: v)),
                ),
                SwitchRow(
                  title: 'Nomi accanto alle icone della barra',
                  value: t.railLabels,
                  onChanged: (v) => set((x) => x.copyWith(railLabels: v)),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Servizio debrid',
              footer: 'Vale anche per il resto dell’app. Le chiavi si inseriscono in Servizi.',
              children: [
                ChoiceRow<String>(
                  title: 'Servizio preferito',
                  value: s.debridProvider,
                  options: const {
                    'torbox': 'TorBox',
                    'realdebrid': 'Real-Debrid',
                  },
                  onChanged: (v) =>
                      n.update((x) => x.copyWith(debridProvider: v)),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Avvio',
              footer: 'Con «Riduci gli effetti» attivo l’introduzione viene saltata. Il suono è generato dall’app: non è musica di nessuno.',
              children: [
                SwitchRow(
                  title: 'Introduzione cinematografica',
                  value: t.intro,
                  onChanged: (v) => set((x) => x.copyWith(intro: v)),
                ),
                SwitchRow(
                  title: 'Suono d’ingresso',
                  value: t.sound,
                  onChanged: (v) => set((x) => x.copyWith(sound: v)),
                ),
              ],
            ),
            SettingsGroup(
              title: 'Il resto dell’app',
              children: [
                NavRow(
                  icon: Icons.tune_rounded,
                  title: 'Impostazioni complete (esce da Theater Mode)',
                  onTap: () => context.go('/more'),
                ),
                NavRow(
                  icon: Icons.extension_rounded,
                  title: 'Addon',
                  onTap: () => context.push('/addons'),
                ),
                NavRow(
                  icon: Icons.download_rounded,
                  title: 'Download',
                  onTap: () => context.push('/downloads'),
                ),
                NavRow(
                  icon: Icons.key_rounded,
                  title: 'Servizi e chiavi',
                  onTap: () => context.push('/settings/services'),
                ),
              ],
            ),
            Center(
              child: Text(
                'Interfaccia di Theater Mode ${TheaterPrefs.version}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
