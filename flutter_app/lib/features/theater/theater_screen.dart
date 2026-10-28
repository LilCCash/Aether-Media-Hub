import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/model/meta.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../discover/discover_screen.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../search/search_screen.dart';

/// Theater Mode: the same catalogs and the same pages as the rest of the app, dressed as a landscape cinema. A rail on the left,
/// the title in focus over the whole screen, rows of 16:9 cards, and an entrance with a curtain that opens (skipped with reduced
/// effects). It is an interface, not a second app: Discover, Search and Library are the normal screens, in landscape.
class TheaterScreen extends ConsumerStatefulWidget {
  const TheaterScreen({super.key});

  @override
  ConsumerState<TheaterScreen> createState() => _TheaterScreenState();
}

class _TheaterScreenState extends ConsumerState<TheaterScreen> {
  int _tab = 0;
  MetaItem? _focus;
  bool _curtain = true;

  static const _items = [
    (Icons.home_rounded, 'Home'),
    (Icons.explore_rounded, 'Scopri'),
    (Icons.search_rounded, 'Cerca'),
    (Icons.video_library_rounded, 'Libreria'),
  ];

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _curtain = false);
    });
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    final fast =
        look.reduceEffects ||
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Row(
            children: [
              SafeArea(
                right: false,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: GlassSurface(
                    radius: 30,
                    strong: true,
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 6,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < _items.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: GlassButton(
                              icon: _items[i].$1,
                              tooltip: _items[i].$2,
                              size: 48,
                              selected: _tab == i,
                              onPressed: () => setState(() => _tab = i),
                            ),
                          ),
                        const SizedBox(height: 16),
                        GlassButton(
                          icon: Icons.close_rounded,
                          tooltip: 'Esci da Theater Mode',
                          size: 48,
                          onPressed: () => context.go('/home'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    _TheaterHome(
                      focus: _focus,
                      onFocus: (m) => setState(() => _focus = m),
                    ),
                    const DiscoverScreen(),
                    const SearchScreen(),
                    const LibraryScreen(),
                  ],
                ),
              ),
            ],
          ),
          // The curtain: black that fades away once, so the first frame is not abrupt.
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _curtain ? 1 : 0,
              duration: fast ? Duration.zero : AetherTokens.slow * 2,
              curve: Curves.easeInOutCubic,
              child: const ColoredBox(
                color: Colors.black,
                child: SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TheaterHome extends ConsumerWidget {
  const _TheaterHome({required this.focus, required this.onFocus});
  final MetaItem? focus;
  final ValueChanged<MetaItem> onFocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final addons = ref.watch(addonsProvider);
    final rows = visibleCatalogs(
      addons,
      s.hiddenHomeCatalogs,
      s.catalogOrder,
      hideAdult: s.hideAdultCatalogs,
    );
    final first = rows.firstOrNull;
    final firstItems = first == null
        ? const <MetaItem>[]
        : (ref
                  .watch(
                    catalogProvider(CatalogQuery(first.$1.id, first.$2.key)),
                  )
                  .value ??
              const <MetaItem>[]);
    final shown =
        focus ??
        firstItems
            .where((m) => m.background != null || m.poster != null)
            .firstOrNull;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (shown != null)
          PosterImage(
            url: shown.background ?? shown.poster,
            title: shown.name,
            radius: 0,
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0xF205060D), Color(0x9905060D), Color(0x2205060D)],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0xE605060D)],
              stops: [0.35, 1],
            ),
          ),
        ),
        SafeArea(
          left: false,
          child: addons.where((a) => a.enabled).isEmpty
              ? const EmptyState(
                  icon: Icons.extension_rounded,
                  title: 'Nessun addon installato',
                  message: 'Installa un addon da Altro ▸ Addon per riempire Theater Mode.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 18, 24, 0),
                      child: shown == null
                          ? const SizedBox(height: 120)
                          : SizedBox(
                              height: 150,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Text(
                                    'THEATER MODE',
                                    style: TextStyle(
                                      fontSize: 10,
                                      letterSpacing: 4,
                                      fontWeight: FontWeight.w800,
                                      color: AetherLook.of(context).accent,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    shown.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .displaySmall,
                                  ),
                                  Text(
                                    [
                                      if (shown.releaseInfo != null)
                                        shown.releaseInfo!,
                                      ...shown.genres.take(3),
                                    ].join(' · '),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: AetherTokens.textSecondary,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  GlassButton(
                                    icon: Icons.play_arrow_rounded,
                                    label: 'Guarda',
                                    prominent: true,
                                    size: 40,
                                    onPressed: () => openTitle(context, shown),
                                  ),
                                ],
                              ),
                            ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 16),
                        children: [
                          for (final (addon, catalog) in rows)
                            _TheaterRow(
                              addonId: addon.id,
                              catalogKey: catalog.key,
                              title:
                                  s.catalogTitles['${addon.id}/${catalog.key}'] ??
                                  catalog.name,
                              focus: focus,
                              onFocus: onFocus,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _TheaterRow extends ConsumerWidget {
  const _TheaterRow({
    required this.addonId,
    required this.catalogKey,
    required this.title,
    required this.focus,
    required this.onFocus,
  });
  final String addonId;
  final String catalogKey;
  final String title;
  final MetaItem? focus;
  final ValueChanged<MetaItem> onFocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(catalogProvider(CatalogQuery(addonId, catalogKey)));
    return async.maybeWhen(
      data: (items) => items.isEmpty
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                SizedBox(
                  height: 112,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    scrollDirection: Axis.horizontal,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, i) {
                      final m = items[i];
                      final selected = focus?.id == m.id;
                      return Semantics(
                        button: true,
                        label: m.name,
                        child: GestureDetector(
                          // First tap puts the title in focus (the big picture and the Guarda button); a second tap opens it.
                          onTap: () =>
                              selected ? openTitle(context, m) : onFocus(m),
                          child: AnimatedContainer(
                            duration: AetherTokens.medium,
                            width: 190,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: selected
                                    ? AetherLook.of(context).accent
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                            child: PosterImage(
                              url: m.background ?? m.poster,
                              title: m.name,
                              radius: 14,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
      orElse: () => const SizedBox.shrink(),
    );
  }
}
