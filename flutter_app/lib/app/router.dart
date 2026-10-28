import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/model/meta.dart';
import '../features/addons/addons_screen.dart';
import '../features/detail/detail_screen.dart';
import '../features/discover/discover_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/player/offline_test_screen.dart';
import '../features/player/player_screen.dart';
import '../features/player/player_session.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screens.dart';
import '../features/shell/shell.dart';
import '../features/theater/theater_screen.dart';
import 'providers.dart';

/// Where a title page lives; the catalog item travels as `extra` so the page shows something at once.
void openTitle(BuildContext context, MetaItem item) => context.push(
  '/title/${Uri.encodeComponent(item.type)}/${Uri.encodeComponent(item.id)}',
  extra: item,
);

final routerProvider = Provider<GoRouter>((ref) {
  final onboardingDone = ref.read(settingsProvider).onboardingDone;
  return GoRouter(
    initialLocation: onboardingDone ? '/home' : '/onboarding',
    redirect: (context, state) {
      // `stremio://…/manifest.json` and `aether://addon?url=…` open the addon page with the preview of that address.
      final u = state.uri;
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
        builder: (_, state) => DetailScreen(
          type: Uri.decodeComponent(state.pathParameters['type']!),
          id: Uri.decodeComponent(state.pathParameters['id']!),
          preview: state.extra is MetaItem ? state.extra as MetaItem : null,
        ),
      ),
      GoRoute(
        path: '/player',
        builder: (_, state) => PlayerScreen(args: state.extra as PlayerArgs),
      ),
      GoRoute(path: '/theater', builder: (_, __) => const TheaterScreen()),
      GoRoute(
        path: '/offline-test',
        builder: (_, __) => const OfflineTestScreen(),
      ),
      GoRoute(
        path: '/addons',
        builder: (_, state) =>
            AddonsScreen(installUrl: state.uri.queryParameters['install']),
      ),
      GoRoute(path: '/downloads', builder: (_, __) => const DownloadsScreen()),
      GoRoute(
        path: '/settings/:page',
        builder: (_, state) =>
            SettingsPageScreen(page: state.pathParameters['page']!),
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
