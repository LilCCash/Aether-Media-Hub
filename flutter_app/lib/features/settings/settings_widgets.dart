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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 60),
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
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            leading: icon == null ? null : _ColoredIcon(icon!, title!),
            title: Text(
              title!,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
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
  const _ColoredIcon(this.icon, this.key_);
  final IconData icon;
  final String key_;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colored = ref.watch(settingsProvider).coloredIcons;
    final c = colored ? sectionColor(key_) : AetherTokens.textSecondary;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 19, color: c),
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
