import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/orientation.dart';

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
import 'theater_more.dart';
import 'theater_prefs.dart';
import 'theater_sound.dart';

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
    (Icons.tune_rounded, 'Altro'),
  ];

  @override
  void initState() {
    super.initState();
    AppOrientation.setBase(
      AppOrientation.landscape,
      ui: SystemUiMode.immersiveSticky,
    );
    final prefs = ref.read(settingsProvider).theater;
    final reduce = ref.read(settingsProvider).reduceEffects;
    if (prefs.intro && !reduce) {
      // The entrance: the curtain stays closed while the sound climbs, then it opens.
      if (prefs.sound) TheaterSound.playIntro();
      _introTimer = Timer(const Duration(milliseconds: 2600), () {
        if (mounted) setState(() => _curtain = false);
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _curtain = false);
      });
    }
  }

  Timer? _introTimer;

  @override
  void dispose() {
    _introTimer?.cancel();
    AppOrientation.setBase(AppOrientation.portrait);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    final prefs = ref.watch(settingsProvider).theater;
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
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                for (var i = 0; i < _items.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: GlassButton(
                                      icon: _items[i].$1,
                                      label: prefs.railLabels
                                          ? _items[i].$2
                                          : null,
                                      tooltip: _items[i].$2,
                                      size: 48,
                                      selected: _tab == i,
                                      onPressed: () => setState(() => _tab = i),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
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
                    const TheaterMore(),
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
              child: ColoredBox(
                color: Colors.black,
                child: SizedBox.expand(
                  child: Center(
                    child: Text(
                      'THEATER MODE',
                      style: TextStyle(
                        fontSize: 18,
                        letterSpacing: 10,
                        fontWeight: FontWeight.w800,
                        color: prefs.accent.color,
                      ),
                    ),
                  ),
                ),
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
    final prefs = s.theater;
    final accent = prefs.accent.color;
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
        if (shown != null && prefs.background != 0)
          PosterImage(
            url: shown.background ?? shown.poster,
            title: shown.name,
            radius: 0,
          ),
        if (prefs.background == 2)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.6, -1.1),
                radius: 1.3,
                colors: [accent.withValues(alpha: 0.35), Colors.transparent],
              ),
            ),
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
                                      color: accent,
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
                              prefs: prefs,
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
    required this.prefs,
  });
  final TheaterPrefs prefs;
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
                if (prefs.sprockets) const _Sprockets(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                  child: Text(
                    prefs.rowStyle == 2 ? title.toUpperCase() : title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontFamily: prefs.rowStyle == 1 ? 'serif' : null,
                      letterSpacing: prefs.rowStyle == 2 ? 2 : null,
                      fontSize: prefs.rowStyle == 2 ? 13 : null,
                    ),
                  ),
                ),
                SizedBox(
                  height:
                      prefs.rowHeight +
                      (prefs.titles ? 22 : 0) +
                      (prefs.details ? 16 : 0) +
                      6,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    scrollDirection: Axis.horizontal,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, i) {
                      final m = items[i];
                      final selected = focus?.id == m.id;
                      final accent = prefs.accent.color;
                      return Semantics(
                        button: true,
                        label: m.name,
                        child: GestureDetector(
                          // First tap puts the title in focus (the big picture and the Guarda button); a second tap opens it.
                          onTap: () =>
                              selected ? openTitle(context, m) : onFocus(m),
                          child: SizedBox(
                            width: prefs.cardWidth,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AnimatedContainer(
                                  duration: AetherTokens.medium,
                                  height: prefs.rowHeight,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      prefs.radius + 2,
                                    ),
                                    border: Border.all(
                                      color: selected
                                          ? accent
                                          : (prefs.border == 2
                                                ? accent.withValues(alpha: 0.6)
                                                : (prefs.border == 1
                                                      ? Colors.white24
                                                      : Colors.transparent)),
                                      width: selected || prefs.border == 2
                                          ? 2
                                          : 1,
                                    ),
                                    boxShadow: selected && prefs.glow
                                        ? [
                                            BoxShadow(
                                              color: accent.withValues(
                                                alpha: 0.45,
                                              ),
                                              blurRadius: 16,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: PosterImage(
                                    url: prefs.portraitCards
                                        ? (m.poster ?? m.background)
                                        : (m.background ?? m.poster),
                                    title: m.name,
                                    radius: prefs.radius,
                                  ),
                                ),
                                if (prefs.titles)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 4,
                                      left: 2,
                                    ),
                                    child: Text(
                                      m.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                if (prefs.details)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 2),
                                    child: Text(
                                      [
                                        if (m.releaseInfo != null)
                                          m.releaseInfo!,
                                        ...m.genres.take(1),
                                      ].join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(fontSize: 10.5),
                                    ),
                                  ),
                              ],
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

/// The holes along the edge of a film strip, drawn above a row.
class _Sprockets extends StatelessWidget {
  const _Sprockets();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
    child: LayoutBuilder(
      builder: (context, c) => Row(
        children: [
          for (var i = 0; i < (c.maxWidth / 16).floor().clamp(0, 80); i++)
            Container(
              width: 8,
              height: 5,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
        ],
      ),
    ),
  );
}
