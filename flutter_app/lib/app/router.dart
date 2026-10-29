import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/model/meta.dart';
import '../features/addons/addons_screen.dart';
import '../features/calendar/calendar_screen.dart';
import '../features/stats/stats_screen.dart';
import '../features/detail/detail_screen.dart';
import '../features/discover/discover_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/player/offline_test_screen.dart';
import '../features/player/player_screen.dart';
import '../features/player/preparing_player.dart';
import '../features/player/player_session.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screens.dart';
import '../features/shell/shell.dart';
import '../features/theater/theater_screen.dart';
import 'hooks.dart' show locationForLink;
import 'providers.dart';
import '../data/prefs_ext.dart';
import 'transitions.dart';

/// Where a title page lives; the catalog item travels as `extra` so the page shows something at once.
void openTitle(BuildContext context, MetaItem item) {
  TitleOrigin.capture(context);
  context.push(
    '/title/${Uri.encodeComponent(item.type)}/${Uri.encodeComponent(item.id)}',
    extra: item,
  );
}

final routerProvider = Provider<GoRouter>((ref) {
  PageTransitionKind titleKind() {
    final s = ref.read(settingsProvider);
    final k = transitionKindOf(s.titleTransition);
    if (k != PageTransitionKind.auto) return k;
    return s.cinematic ? PageTransitionKind.zoom : PageTransitionKind.slide;
  }

  PageTransitionKind slideKind() => PageTransitionKind.slide;

  final onboardingDone = ref.read(settingsProvider).onboardingDone;
  return GoRouter(
    initialLocation: onboardingDone ? '/home' : '/onboarding',
    redirect: (context, state) {
      // `stremio://…/manifest.json` and `aether://addon?url=…` open the addon page with the preview of that address.
      final u = state.uri;
      if (u.scheme == 'aether') {
        final loc = locationForLink(u);
        if (loc != null) return loc;
      }
      if (u.scheme == 'stremio' || u.scheme == 'aether') {
        return '/addons?install=${Uri.encodeQueryComponent(u.toString())}';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/onboarding',
        builder: (_, __) => const OnboardingScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AetherShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/discover',
                builder: (_, __) => const DiscoverScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/search',
                builder: (_, __) => const SearchScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/library',
                builder: (_, __) => const LibraryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/more', builder: (_, __) => const MoreScreen()),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/title/:type/:id',
        pageBuilder: (_, state) => AetherPage(
          key: state.pageKey,
          kind: titleKind,
          child: DetailScreen(
            type: Uri.decodeComponent(state.pathParameters['type']!),
            id: Uri.decodeComponent(state.pathParameters['id']!),
            preview: state.extra is MetaItem ? state.extra as MetaItem : null,
          ),
        ),
      ),
      GoRoute(
        path: '/player',
        builder: (_, state) {
          final args = state.extra as PlayerArgs;
          return args.prepare == null
              ? PlayerScreen(args: args)
              : PreparingPlayer(args: args);
        },
      ),
      GoRoute(path: '/theater', builder: (_, __) => const TheaterScreen()),
      GoRoute(
        path: '/offline-test',
        pageBuilder: (_, state) => AetherPage(
          key: state.pageKey,
          kind: slideKind,
          child: const OfflineTestScreen(),
        ),
      ),
      GoRoute(
        path: '/addons',
        pageBuilder: (_, state) => AetherPage(
          key: state.pageKey,
          kind: slideKind,
          child: AddonsScreen(installUrl: state.uri.queryParameters['install']),
        ),
      ),
      GoRoute(
        path: '/calendar',
        pageBuilder: (_, state) => AetherPage(
          key: state.pageKey,
          kind: slideKind,
          child: const CalendarScreen(),
        ),
      ),
      GoRoute(
        path: '/stats',
        pageBuilder: (_, state) => AetherPage(
          key: state.pageKey,
          kind: slideKind,
          child: const StatsScreen(),
        ),
      ),
      GoRoute(
        path: '/downloads',
        pageBuilder: (_, state) => AetherPage(
          key: state.pageKey,
          kind: slideKind,
          child: const DownloadsScreen(),
        ),
      ),
      GoRoute(
        path: '/settings/:page',
        pageBuilder: (_, state) => AetherPage(
          key: state.pageKey,
          kind: slideKind,
          child: SettingsPageScreen(page: state.pathParameters['page']!),
        ),
      ),
      GoRoute(
        path: '/person/:id',
        builder: (_, state) => PersonScreen(
          id: int.parse(state.pathParameters['id']!),
          name: state.uri.queryParameters['name'] ?? '',
        ),
      ),
    ],
    errorBuilder: (_, state) =>
        Scaffold(body: Center(child: Text('Pagina non trovata: ${state.uri}'))),
  );
});
