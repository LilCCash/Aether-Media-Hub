import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'liquid_dock.dart';

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
    return Scaffold(
      extendBody: true,
      body: shell,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: LiquidDock(
            items: _items,
            index: shell.currentIndex,
            onSelect: (i) =>
                shell.goBranch(i, initialLocation: i == shell.currentIndex),
          ),
        ),
      ),
    );
  }
}
