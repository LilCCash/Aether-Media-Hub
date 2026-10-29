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
  static bool restoring = false;
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
              // `uri` ignores pages opened with push (settings, titles, the player): the last match is the one on screen.
              final cfg = router.routerDelegate.currentConfiguration;
              final path = cfg.matches.isEmpty
                  ? cfg.uri.path
                  : cfg.last.matchedLocation;
              // Low on the screen, as the system tab bar sits: a little above the edge, not above the whole home indicator.
              final inset = MediaQuery.viewPaddingOf(context).bottom;
              final bottom = inset > 0 ? (inset * 0.3).clamp(6.0, 14.0) : 10.0;
              final tab = _tabs.indexWhere((t) => path.startsWith(t.$3));
              final inMore =
                  path.startsWith('/settings/') ||
                  path == '/addons' ||
                  path == '/downloads';
              // The pages opened from «Altro» belong to that tab: the bar keeps pointing at it.
              if (tab >= 0) {
                DockState.index = tab;
              } else if (inMore) {
                DockState.index = 4;
              }
              if (path == '/more' && !DockState.restoring) {
                DockState.moreStack = [];
              } else if (inMore) {
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
                        bottom: false,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(12, 0, 12, bottom),
                          child: LiquidDock(
                            items: [for (final t in _tabs) (t.$1, t.$2)],
                            index: DockState.index,
                            opacity: dockOpacity,
                            onSelect: (i) {
                              // The tab already open, on a page deeper than its main one (a settings page, a title): back to the main page.
                              if (i == DockState.index && path != _tabs[i].$3) {
                                if (i == 4) DockState.moreStack = [];
                                for (
                                  var n = 0;
                                  n < 12 && router.canPop();
                                  n++
                                ) {
                                  router.pop();
                                }
                                return;
                              }
                              final back = i == 4 && DockState.index != 4
                                  ? [...DockState.moreStack]
                                  : const <String>[];
                              if (back.isEmpty) {
                                router.go(_tabs[i].$3);
                                return;
                              }
                              // «Altro» reopens the settings page that was open when the viewer left: the pages are pushed once
                              // «Altro» is really the page on screen, not before the router has settled on it.
                              DockState.restoring = true;
                              void settle() {
                                final m = router.routerDelegate.currentConfiguration;
                                if (m.matches.isEmpty ||
                                    m.last.matchedLocation != '/more') {
                                  return;
                                }
                                router.routerDelegate.removeListener(settle);
                                for (final p in back) {
                                  router.push(p);
                                }
                                DockState.restoring = false;
                              }

                              router.routerDelegate.addListener(settle);
                              router.go('/more');
                              Future<void>.delayed(
                                const Duration(seconds: 2),
                                () {
                                  router.routerDelegate.removeListener(settle);
                                  DockState.restoring = false;
                                },
                              );
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
