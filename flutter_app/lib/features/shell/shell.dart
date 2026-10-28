import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design/glass.dart';
import '../../design/tokens.dart';

/// The frame of the five main sections: a floating glass tab bar over the content.
class AetherShell extends StatelessWidget {
  const AetherShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const _items = [
    (Icons.home_rounded, 'Home'),
    (Icons.explore_rounded, 'Scopri'),
    (Icons.search_rounded, 'Cerca'),
    (Icons.video_library_rounded, 'Libreria'),
    (Icons.more_horiz_rounded, 'Altro'),
  ];

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    return Scaffold(
      extendBody: true,
      body: shell,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: GlassSurface(
            radius: 28,
            strong: true,
            blur: AetherTokens.blurHigh,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: shell.currentIndex == i,
                    label: _items[i].$2,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => shell.goBranch(i, initialLocation: i == shell.currentIndex),
                      child: AnimatedContainer(
                        duration: look.reduceEffects ? Duration.zero : AetherTokens.medium,
                        curve: AetherTokens.ease,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(color: shell.currentIndex == i ? look.accent.withValues(alpha: 0.22) : Colors.transparent, borderRadius: BorderRadius.circular(22)),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(_items[i].$1, size: 24, color: shell.currentIndex == i ? look.accent : AetherTokens.textSecondary),
                          const SizedBox(height: 2),
                          Text(_items[i].$2, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: shell.currentIndex == i ? AetherTokens.textPrimary : AetherTokens.textTertiary)),
                        ]),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
