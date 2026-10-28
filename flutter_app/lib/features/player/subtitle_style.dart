import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';
import '../../design/tokens.dart';
import '../settings/settings_extra.dart';
import '../settings/settings_widgets.dart';

/// An external subtitle line: a solid outline is painted under the fill, so it stays readable on any picture and whatever colour
/// the viewer picked. (A text style with only shadows turned unreadable on bright scenes.)
class SubtitleText extends StatelessWidget {
  const SubtitleText({
    super.key,
    required this.text,
    required this.scale,
    required this.color,
    required this.bold,
    required this.outline,
    required this.outlineColor,
    required this.background,
    this.base = 22,
  });
  final String text;
  final double scale;
  final Color color;
  final bool bold;
  final bool outline;
  final Color outlineColor;
  final Color background;
  final double base;

  factory SubtitleText.fromSettings(
    AppSettings s,
    String text, {
    double base = 22,
  }) => SubtitleText(
    text: text,
    scale: s.subtitleScale,
    color: colorFromHex(s.subColor),
    bold: s.subBold,
    outline: s.subOutline,
    outlineColor: colorFromHex(s.subOutlineColor),
    background: colorFromHex(s.subBgColor).withValues(alpha: s.subBgOpacity),
    base: base,
  );

  @override
  Widget build(BuildContext context) {
    // The outline is drawn with solid shadows around the glyphs (a stroked foreground paint is not drawn reliably on every
    // renderer, and the fill colour must always be the one the viewer chose).
    final r = (1.6 * scale.clamp(0.8, 1.6)).toDouble();
    final shadows = outline
        ? [
            for (var i = 0; i < 12; i++)
              Shadow(
                color: outlineColor,
                offset: Offset(
                  r * math.cos(i * math.pi / 6),
                  r * math.sin(i * math.pi / 6),
                ),
              ),
          ]
        : const [Shadow(blurRadius: 4, color: Color(0xCC000000))];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: base * scale,
          fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
          height: 1.25,
          color: color,
          decoration: TextDecoration.none,
          shadows: shadows,
        ),
      ),
    );
  }
}

/// A little screen showing, live, how subtitles look with the current choices.
class SubtitlePreview extends ConsumerWidget {
  const SubtitlePreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Three bands: dark, mid and bright, because subtitles fail on bright pictures first.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF1B2A4A),
                      Color(0xFF8A9BB8),
                      Color(0xFFF2EBD3),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: 6 + s.subBottom * 1.2,
                    left: 10,
                    right: 10,
                  ),
                  child: SubtitleText.fromSettings(
                    s,
                    'Così appaiono i sottotitoli.\nDue righe di esempio.',
                    base: 15,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The subtitle appearance controls, shared by Settings ▸ Riproduzione and the player's subtitle panel.
class SubtitleStyleControls extends ConsumerWidget {
  const SubtitleStyleControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return Column(
      children: [
        const SubtitlePreview(),
        SliderRow(
          title: 'Dimensione',
          value: s.subtitleScale,
          min: 0.6,
          max: 2,
          divisions: 14,
          format: (v) => '${(v * 100).round()}%',
          onChanged: (v) => n.update((x) => x.copyWith(subtitleScale: v)),
        ),
        const PrefColor('subColor', 'Colore del testo', _color),
        PrefSwitch('subBold', 'Grassetto', (x) => x.subBold),
        PrefSwitch('subOutline', 'Contorno', (x) => x.subOutline),
        if (s.subOutline)
          const PrefColor('subOutlineColor', 'Colore del contorno', _outline),
        const PrefColor('subBgColor', 'Colore dello sfondo', _bg),
        PrefSlider(
          'subBgOpacity',
          'Opacità dello sfondo',
          (x) => x.subBgOpacity,
          min: 0,
          max: 1,
          divisions: 10,
          format: (v) => v == 0 ? 'nessuno' : '${(v * 100).round()}%',
        ),
        PrefSlider(
          'subBottom',
          'Distanza dal bordo inferiore',
          (x) => x.subBottom,
          min: 0,
          max: 40,
          divisions: 20,
          format: (v) => '${v.round()}%',
        ),
        TextButton(
          onPressed: () => n.update(
            (x) => x
                .withExt('subColor', null)
                .withExt('subBold', null)
                .withExt('subOutline', null)
                .withExt('subOutlineColor', null)
                .withExt('subBgColor', null)
                .withExt('subBgOpacity', null)
                .withExt('subBottom', null)
                .copyWith(subtitleScale: 1.0),
          ),
          child: const Text('Ripristina lo stile predefinito'),
        ),
      ],
    );
  }

  static String? _color(AppSettings s) => s.subColor;
  static String? _outline(AppSettings s) => s.subOutlineColor;
  static String? _bg(AppSettings s) => s.subBgColor;
}
