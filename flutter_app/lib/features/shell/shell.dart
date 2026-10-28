import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/prefs_ext.dart';
import 'liquid_dock.dart';

/// The frame of the five main sections. The tab bar itself is [DockOverlay], which sits above every page of the app.
class AetherShell extends StatelessWidget {
  const AetherShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(body: shell);
}

/// Whether the tab bar is hidden for now (while the sources are being chosen) and which tab was last on screen.
class DockState {
  DockState._();
  static final hidden = ValueNotifier<int>(0);
  static int index = 0;

  /// The pages opened from «Altro» (settings…), so coming back to that tab finds them as they were left.
  static List<String> moreStack = [];
  static void hide() => hidden.value++;
  static void show() {
    if (hidden.value > 0) hidden.value--;
  }
}

/// For a page that covers the whole screen (the player, Theater Mode): the tab bar stays away while it is open.
mixin HidesDock<T extends StatefulWidget> on State<T> {
  bool _hid = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_hid) {
        _hid = true;
        DockState.hide();
      }
    });
  }

  @override
  void dispose() {
    if (_hid) {
      _hid = false;
      scheduleMicrotask(DockState.show);
    }
    super.dispose();
  }
}

const _tabs = [
  (Icons.home_rounded, 'Home', '/home'),
  (Icons.explore_rounded, 'Scopri', '/discover'),
  (Icons.search_rounded, 'Cerca', '/search'),
  (Icons.video_library_rounded, 'Libreria', '/library'),
  (Icons.more_horiz_rounded, 'Altro', '/more'),
];

const _noDock = ['/player', '/theater', '/onboarding', '/offline-test'];

/// The floating tab bar over every page: titles, settings, addons… It goes away only on the player and when the sources open.
class DockOverlay extends ConsumerWidget {
  const DockOverlay({super.key, required this.router, required this.child});
  final GoRouter router;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dockOpacity = ref.watch(settingsProvider).dockOpacity;
    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              router.routerDelegate,
              DockState.hidden,
            ]),
            builder: (context, _) {
              final path = router.routerDelegate.currentConfiguration.uri.path;
              final tab = _tabs.indexWhere((t) => path.startsWith(t.$3));
              if (tab >= 0) DockState.index = tab;
              if (path == '/more') {
                DockState.moreStack = [];
              } else if (path.startsWith('/settings/') ||
                  path == '/addons' ||
                  path == '/downloads') {
                DockState.moreStack =
                    path.startsWith('/settings/') &&
                        path != '/settings/root' &&
                        path != '/settings/about'
                    ? ['/settings/root', path]
                    : [path];
              }
              final show =
                  DockState.hidden.value == 0 &&
                  !_noDock.any((p) => path.startsWith(p));
              return IgnorePointer(
                ignoring: !show,
                child: AnimatedSlide(
                  offset: show ? Offset.zero : const Offset(0, 1.2),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: show ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Material(
                      type: MaterialType.transparency,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                          child: LiquidDock(
                            items: [for (final t in _tabs) (t.$1, t.$2)],
                            index: DockState.index,
                            opacity: dockOpacity,
                            onSelect: (i) {
                              final back = i == 4 && DockState.index != 4
                                  ? [...DockState.moreStack]
                                  : const <String>[];
                              router.go(_tabs[i].$3);
                              // «Altro» reopens the settings page that was open when the viewer left.
                              Future<void>.microtask(() {
                                for (final p in back) {
                                  router.push(p);
                                }
                              });
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
