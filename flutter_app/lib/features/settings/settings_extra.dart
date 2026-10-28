import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';
import '../../design/tokens.dart';
import 'settings_widgets.dart';

/// Rows bound to a key of [AppSettings.ext]: they read through the validating getter and write the plain value.
class PrefSwitch extends ConsumerWidget {
  const PrefSwitch(this.k, this.title, this.get, {super.key, this.subtitle});
  final String k;
  final String title;
  final bool Function(AppSettings) get;
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SwitchRow(
    title: title,
    subtitle: subtitle,
    value: get(ref.watch(settingsProvider)),
    onChanged: (v) =>
        ref.read(settingsProvider.notifier).update((x) => x.withExt(k, v)),
  );
}

class PrefChoice<T> extends ConsumerWidget {
  const PrefChoice(this.k, this.title, this.get, this.options, {super.key});
  final String k;
  final String title;
  final T Function(AppSettings) get;
  final Map<T, String> options;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ChoiceRow<T>(
    title: title,
    value: get(ref.watch(settingsProvider)),
    options: options,
    onChanged: (v) =>
        ref.read(settingsProvider.notifier).update((x) => x.withExt(k, v)),
  );
}

class PrefSlider extends ConsumerWidget {
  const PrefSlider(
    this.k,
    this.title,
    this.get, {
    super.key,
    required this.min,
    required this.max,
    this.divisions,
    this.format,
    this.integer = false,
  });
  final String k;
  final String title;
  final double Function(AppSettings) get;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double)? format;
  final bool integer;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SliderRow(
    title: title,
    value: get(ref.watch(settingsProvider)),
    min: min,
    max: max,
    divisions: divisions,
    format: format,
    onChanged: (v) => ref
        .read(settingsProvider.notifier)
        .update((x) => x.withExt(k, integer ? v.round() : v)),
  );
}

/// A row of colour dots (plus a hex field) bound to a key.
class PrefColor extends ConsumerWidget {
  const PrefColor(
    this.k,
    this.title,
    this.get, {
    super.key,
    this.allowNone = false,
  });
  final String k;
  final String title;
  final String? Function(AppSettings) get;
  final bool allowNone;

  static const _colors = [
    '#FFFFFF',
    '#FFE066',
    '#FFD173',
    '#FF9500',
    '#FF5A5F',
    '#FF6FB5',
    '#9B5CFF',
    '#4C8DFF',
    '#1FB6FF',
    '#12D6B0',
    '#59DB9E',
    '#000000',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = get(ref.watch(settingsProvider));
    void set(String? v) =>
        ref.read(settingsProvider.notifier).update((x) => x.withExt(k, v));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (allowNone)
                ChoiceChip(
                  label: const Text('Predefinito'),
                  selected: current == null,
                  onSelected: (_) => set(null),
                ),
              for (final c in _colors)
                Semantics(
                  button: true,
                  label: 'Colore $c',
                  selected: current?.toLowerCase() == c.toLowerCase(),
                  child: GestureDetector(
                    onTap: () => set(c),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colorFromHex(c),
                        border: Border.all(
                          color: current?.toLowerCase() == c.toLowerCase()
                              ? Colors.white
                              : Colors.white24,
                          width: current?.toLowerCase() == c.toLowerCase()
                              ? 3
                              : 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: 170,
              child: TextFormField(
                key: ValueKey(current),
                initialValue: current ?? '',
                maxLength: 7,
                decoration: const InputDecoration(
                  labelText: 'Esadecimale (#RRGGBB)',
                  counterText: '',
                ),
                onFieldSubmitted: (v) {
                  final t = v.trim().startsWith('#')
                      ? v.trim()
                      : '#${v.trim()}';
                  if (RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(t))
                    set(t.toUpperCase());
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const kLangOptions = {
  'off': 'Nessuna',
  'ita': 'Italiano',
  'eng': 'Inglese',
  'fra': 'Francese',
  'spa': 'Spagnolo',
  'deu': 'Tedesco',
  'por': 'Portoghese',
  'jpn': 'Giapponese',
};

const kQualityOptions = {
  0: 'Massima disponibile',
  2160: 'Fino a 4K',
  1080: 'Fino a 1080p',
  720: 'Fino a 720p',
};
