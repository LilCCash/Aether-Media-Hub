import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/prefs_ext.dart';

import '../../design/glass.dart';
import '../../design/tokens.dart';

/// Set by [MergedSettingsPage]: the parts it stacks draw only their content, the merged page owns the frame.
class _Embedded extends InheritedWidget {
  const _Embedded({required super.child});
  static bool of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<_Embedded>() != null;
  @override
  bool updateShouldNotify(_Embedded old) => false;
}

/// Lets a settings page show only some of the groups of another page (so one topic can gather groups that are built elsewhere).
class GroupFilter extends InheritedWidget {
  const GroupFilter({super.key, required this.titles, required super.child});
  final Set<String> titles;
  static Set<String>? of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<GroupFilter>()?.titles;
  @override
  bool updateShouldNotify(GroupFilter old) => old.titles != titles;
}

/// Icon and colour of each settings group, by its title (the colour says what kind of setting it is).
const kGroupStyles = <String, (IconData, Color)>{
  'Modalità': (Icons.dark_mode_rounded, Color(0xFF7C8CFF)),
  'Palette': (Icons.palette_rounded, Color(0xFFFF6FB5)),
  'Testo': (Icons.text_fields_rounded, Color(0xFF5CC8FF)),
  'Liquid Glass': (Icons.blur_on_rounded, Color(0xFF4FD1C5)),
  'Colore d’accento': (Icons.colorize_rounded, Color(0xFFFF8A5B)),
  'Anteprima': (Icons.visibility_rounded, Color(0xFFB48CFF)),
  'Stili pronti': (Icons.auto_awesome_rounded, Color(0xFFFFC857)),
  'Transizioni': (Icons.animation_rounded, Color(0xFFB48CFF)),
  'Interfaccia': (Icons.dashboard_customize_rounded, Color(0xFF5CC8FF)),
  'Colori': (Icons.color_lens_rounded, Color(0xFFFF6FB5)),
  'Sfondo': (Icons.wallpaper_rounded, Color(0xFF4CD6A0)),
  'Schede e locandine': (Icons.style_rounded, Color(0xFFFF8A5B)),
  'Movimento': (Icons.motion_photos_on_rounded, Color(0xFF7C8CFF)),
  'In evidenza': (Icons.star_rounded, Color(0xFFFFC857)),
  'Sezioni della Home': (Icons.home_rounded, Color(0xFFFF8A5B)),
  'Scopri': (Icons.explore_rounded, Color(0xFF4CD6A0)),
  'Lingue': (Icons.translate_rounded, Color(0xFF5CC8FF)),
  'Prossimo episodio e titoli di coda': (
    Icons.skip_next_rounded,
    Color(0xFF4FD1C5),
  ),
  'Tema chiaro e condivisione': (Icons.light_mode_rounded, Color(0xFFFFC857)),
  'Sfondi animati e locandine': (Icons.animation_rounded, Color(0xFFFF6FB5)),
  'Calendario e notifiche': (
    Icons.notifications_active_rounded,
    Color(0xFFFF8A5B),
  ),
  'Fonti e schermata di blocco': (Icons.lock_clock_rounded, Color(0xFF5CC8FF)),
  'Lingue di riserva': (Icons.language_rounded, Color(0xFF7C8CFF)),
  'Sottotitoli': (Icons.subtitles_rounded, Color(0xFFFFC857)),
  'Stile dei sottotitoli': (Icons.format_color_text_rounded, Color(0xFFFF6FB5)),
  'Player': (Icons.play_circle_rounded, Color(0xFFFF8A5B)),
  'Controlli e gesti': (Icons.touch_app_rounded, Color(0xFF4CD6A0)),
  'Ripresa e fine episodio': (Icons.skip_next_rounded, Color(0xFF7C8CFF)),
  'Immagine (motore libmpv)': (Icons.tune_rounded, Color(0xFFB48CFF)),
  'In sottofondo': (Icons.picture_in_picture_alt_rounded, Color(0xFF5CC8FF)),
  'Ordine e scelta': (Icons.low_priority_rounded, Color(0xFF7C8CFF)),
  'Aspetto delle righe': (Icons.view_agenda_rounded, Color(0xFFFF6FB5)),
  'Badge da mostrare': (Icons.sell_rounded, Color(0xFFFFC857)),
  'Badge personalizzati': (Icons.new_label_rounded, Color(0xFFFF8A5B)),
  'Cataloghi e lingua': (Icons.view_list_rounded, Color(0xFF4CD6A0)),
  'Cataloghi e cache': (Icons.storage_rounded, Color(0xFF5CC8FF)),
  'Metadati TMDB': (Icons.movie_filter_rounded, Color(0xFF4FD1C5)),
  'Rete': (Icons.wifi_rounded, Color(0xFF5CC8FF)),
  'Download': (Icons.download_rounded, Color(0xFF4CD6A0)),
  'Download di una stagione': (Icons.video_library_rounded, Color(0xFF7C8CFF)),
  'Addon usati per le stagioni': (Icons.extension_rounded, Color(0xFF7C8CFF)),
  'Cos’è': (Icons.auto_awesome_rounded, Color(0xFF7C8CFF)),
  'Privacy': (Icons.privacy_tip_rounded, Color(0xFF4CD6A0)),
  'Cosa non c’è': (Icons.remove_circle_outline_rounded, Color(0xFFFF8A5B)),
  'Componenti di terze parti': (Icons.inventory_2_rounded, Color(0xFFB48CFF)),
  'Archiviazione': (Icons.sd_storage_rounded, Color(0xFFB48CFF)),
  'Esporta': (Icons.upload_rounded, Color(0xFF4CD6A0)),
  'Ripristina': (Icons.settings_backup_restore_rounded, Color(0xFF5CC8FF)),
  'Cancella': (Icons.delete_forever_rounded, Color(0xFFFF6B6B)),
  'Registro': (Icons.receipt_long_rounded, Color(0xFF5CC8FF)),
  'Attribuzioni': (Icons.favorite_rounded, Color(0xFFFF6FB5)),
  'Servizio debrid preferito': (Icons.bolt_rounded, Color(0xFFFFC857)),
  'IntroDB (nessuna chiave)': (Icons.fast_forward_rounded, Color(0xFF4FD1C5)),
};

/// Colours for the icons of the settings sections (the «Icone colorate» setting).
const kSectionColors = [
  Color(0xFF7C8CFF),
  Color(0xFFFF8A5B),
  Color(0xFF4CD6A0),
  Color(0xFFFF6FB5),
  Color(0xFF5CC8FF),
  Color(0xFFFFC857),
  Color(0xFFB48CFF),
  Color(0xFFFF6B6B),
];

Color sectionColor(String key) =>
    kSectionColors[key.codeUnits.fold<int>(0, (a, b) => a + b) %
        kSectionColors.length];

class SettingsPageFrame extends StatelessWidget {
  const SettingsPageFrame({
    super.key,
    required this.title,
    required this.children,
    this.onBack,
  });
  final String title;
  final List<Widget> children;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    if (_Embedded.of(context)) return Column(children: children);
    return Scaffold(
      body: AetherBackdrop(
        child: SafeArea(
          child: ListView(
            // No bounce: at the bottom of a long page the glass underneath used to shake.
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              Row(
                children: [
                  GlassButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    tooltip: 'Indietro',
                    onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// One settings page made of several: every part keeps its own groups, the frame (title, back button, scrolling) is shared.
class MergedSettingsPage extends StatelessWidget {
  const MergedSettingsPage({
    super.key,
    required this.title,
    required this.parts,
  });
  final String title;
  final List<Widget> parts;

  @override
  Widget build(BuildContext context) => SettingsPageFrame(
    title: title,
    children: [_Embedded(child: Column(children: parts))],
  );
}

/// A group of rows. With a [title] it is a collapsible «tendina» (closed unless [open]); without one it is a plain card.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    required this.children,
    this.icon,
    this.open = false,
  });
  final String? title;
  final String? footer;
  final List<Widget> children;
  final IconData? icon;
  final bool open;

  @override
  Widget build(BuildContext context) {
    final only = GroupFilter.of(context);
    if (title != null && only != null && !only.contains(title)) {
      return const SizedBox.shrink();
    }
    final style = title == null ? null : kGroupStyles[title!];
    final body = Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 16),
          children[i],
        ],
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                footer!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
      ],
    );
    if (title == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: GlassSurface(child: body),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassSurface(
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: open,
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            minTileHeight: 48,
            childrenPadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            leading: (icon ?? style?.$1) == null
                ? null
                : _ColoredIcon(icon ?? style!.$1, title!, color: style?.$2),
            title: Text(
              title!,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14.5,
              ),
            ),
            children: [const Divider(height: 1), body],
          ),
        ),
      ),
    );
  }
}

/// An icon on a soft tinted tile; the tint follows the section unless «Icone colorate» is off.
class _ColoredIcon extends ConsumerWidget {
  const _ColoredIcon(this.icon, this.key_, {this.color});
  final IconData icon;
  final String key_;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colored = ref.watch(settingsProvider).coloredIcons;
    final c = colored
        ? (color ?? sectionColor(key_))
        : AetherTokens.textSecondary;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 17, color: Colors.white),
    );
  }
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    value: value,
    onChanged: onChanged,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
  );
}

class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.format,
    this.divisions,
  });
  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final String Function(double)? format;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title)),
            Text(
              format?.call(value) ?? value.toStringAsFixed(2),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final String title;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    title: Text(title),
    trailing: DropdownButton<T>(
      value: options.containsKey(value) ? value : options.keys.first,
      underline: const SizedBox(),
      dropdownColor: AetherTokens.inkRaised,
      items: [
        for (final e in options.entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: (v) => v == null ? null : onChanged(v),
    ),
  );
}

class NavRow extends StatelessWidget {
  const NavRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    leading: _ColoredIcon(icon, title),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );
}
