import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/mood.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/addons/addon_repository.dart';
import '../../core/model/manifest.dart';
import '../../core/model/meta.dart';
import '../../data/library_repository.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';

/// The ordered, visible catalogs of the enabled addons: what Home, and the layout screen, show.
List<(InstalledAddon, ManifestCatalog)> visibleCatalogs(List<InstalledAddon> addons, List<String> hidden, List<String> order, {bool hideAdult = true}) {
  final list = <(InstalledAddon, ManifestCatalog)>[];
  for (final a in addons.where((a) => a.enabled && !(hideAdult && a.manifest.behaviorHints.adult))) {
    for (final c in a.manifest.catalogs.where((c) => c.isBrowsable && a.isCatalogVisible(c))) {
      if (!hidden.contains('${a.id}/${c.key}')) list.add((a, c));
    }
  }
  final position = {for (var i = 0; i < order.length; i++) order[i]: i};
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((x, y) {
    final px = position['${x.$2.$1.id}/${x.$2.$2.key}'] ?? 1 << 20;
    final py = position['${y.$2.$1.id}/${y.$2.$2.key}'] ?? 1 << 20;
    return px != py ? px.compareTo(py) : x.$1.compareTo(y.$1);
  });
  return indexed.map((e) => e.$2).toList();
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final addons = ref.watch(addonsProvider);
    ref.watch(libraryVersionProvider);
    final library = ref.watch(servicesProvider).library;
    final rows = visibleCatalogs(addons, settings.hiddenHomeCatalogs, settings.catalogOrder, hideAdult: settings.hideAdultCatalogs);
    final continueList = settings.showContinueWatching ? library.continueWatching : const <WatchProgress>[];
    final heroSource = rows.firstOrNull;
    final heroItems = heroSource == null ? const AsyncData<List<MetaItem>>([]) : ref.watch(catalogProvider(CatalogQuery(heroSource.$1.id, heroSource.$2.key)));
    final hero = (heroItems.value ?? const <MetaItem>[]).where((m) => m.background != null || m.poster != null).take(6).toList();
    final tint = ref.watch(moodColorProvider(hero.isEmpty ? null : (hero.first.background ?? hero.first.poster))).value;

    return AetherBackdrop(
      tint: tint,
      child: RefreshIndicator(
        onRefresh: () async {
          ref.read(servicesProvider).addonClient.clearCache();
          ref.invalidate(catalogProvider);
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (addons.where((a) => a.enabled).isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.extension_rounded,
                  title: 'Nessun addon installato',
                  message: 'Aether non include contenuti: aggiungi un addon (per esempio Cinemeta per i cataloghi) per riempire la Home.',
                  action: GlassButton(icon: Icons.add_rounded, label: 'Aggiungi un addon', prominent: true, onPressed: () => context.push('/addons')),
                ),
              )
            else ...[
              SliverToBoxAdapter(child: hero.isEmpty ? SizedBox(height: MediaQuery.paddingOf(context).top + 24) : HeroCarousel(items: hero)),
              if (continueList.isNotEmpty) SliverToBoxAdapter(child: _ContinueRow(items: continueList)),
              for (final (addon, catalog) in rows) SliverToBoxAdapter(child: CatalogRow(addon: addon, catalog: catalog)),
              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ],
          ],
        ),
      ),
    );
  }
}

class HeroCarousel extends ConsumerStatefulWidget {
  const HeroCarousel({super.key, required this.items});
  final List<MetaItem> items;

  @override
  ConsumerState<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends ConsumerState<HeroCarousel> {
  final _controller = PageController();
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 7), (_) {
      final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      if (!mounted || reduce || widget.items.length < 2 || !_controller.hasClients) return;
      _controller.animateToPage((_page + 1) % widget.items.length, duration: AetherTokens.slow, curve: AetherTokens.ease);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height * 0.58).clamp(380.0, 560.0);
    return SizedBox(
      height: height,
      child: Stack(children: [
        PageView.builder(
          controller: _controller,
          itemCount: widget.items.length,
          onPageChanged: (i) => setState(() => _page = i),
          itemBuilder: (context, i) => _HeroPage(item: widget.items[i]),
        ),
        Positioned(
          bottom: 14,
          left: 0,
          right: 0,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < widget.items.length; i++)
              AnimatedContainer(duration: AetherTokens.medium, margin: const EdgeInsets.symmetric(horizontal: 3), width: i == _page ? 18 : 6, height: 6, decoration: BoxDecoration(color: Colors.white.withValues(alpha: i == _page ? 0.95 : 0.35), borderRadius: BorderRadius.circular(3))),
          ]),
        ),
      ]),
    );
  }
}

class _HeroPage extends ConsumerWidget {
  const _HeroPage({required this.item});
  final MetaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(servicesProvider).library;
    ref.watch(libraryVersionProvider);
    return GestureDetector(
      onTap: () => openTitle(context, item),
      child: Stack(fit: StackFit.expand, children: [
        PosterImage(url: item.background ?? item.poster, title: item.name, radius: 0),
        const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x66000000), Colors.transparent, Color(0xE605060D)], stops: [0, 0.4, 1]))),
        Positioned(
          left: AetherTokens.pageMargin,
          right: AetherTokens.pageMargin,
          bottom: 38,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 6),
            Text([if (item.releaseInfo != null) item.releaseInfo!, ...item.genres.take(3)].join(' · '), style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AetherTokens.textSecondary)),
            const SizedBox(height: 14),
            Row(children: [
              GlassButton(icon: Icons.play_arrow_rounded, label: 'Guarda', prominent: true, onPressed: () => openTitle(context, item)),
              const SizedBox(width: 10),
              GlassButton(
                icon: library.isInWatchlist(item.id) ? Icons.check_rounded : Icons.add_rounded,
                tooltip: library.isInWatchlist(item.id) ? 'Rimuovi dalla watchlist' : 'Aggiungi alla watchlist',
                onPressed: () async {
                  await library.toggleWatchlist(item);
                  ref.read(libraryVersionProvider.notifier).bump();
                },
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _ContinueRow extends ConsumerWidget {
  const _ContinueRow({required this.items});
  final List<WatchProgress> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader(title: 'Continua a guardare'),
      SizedBox(
        height: 150,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: AetherTokens.pageMargin),
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, i) {
            final p = items[i];
            return GestureDetector(
              onTap: () => openTitle(context, MetaItem(id: p.metaId, type: p.type, name: p.name, poster: p.poster)),
              child: SizedBox(
                width: 230,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Stack(fit: StackFit.expand, children: [
                      PosterImage(url: p.poster, title: p.name),
                      Positioned(left: 10, right: 10, bottom: 10, child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: p.fraction, minHeight: 4, backgroundColor: Colors.white24))),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  if (p.season != null && p.episode != null) Text('S${p.season} · E${p.episode}', style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

class CatalogRow extends ConsumerWidget {
  const CatalogRow({super.key, required this.addon, required this.catalog});
  final InstalledAddon addon;
  final ManifestCatalog catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final key = '${addon.id}/${catalog.key}';
    final title = settings.catalogTitles[key] ?? catalog.name;
    final async = ref.watch(catalogProvider(CatalogQuery(addon.id, catalog.key)));
    return async.when(
      loading: () => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionHeader(title: title, subtitle: addon.displayName),
        SizedBox(height: 200, child: ListView.separated(padding: const EdgeInsets.symmetric(horizontal: 20), scrollDirection: Axis.horizontal, itemCount: 5, separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (_, __) => const Skeleton(width: 120, height: 180, radius: 16))),
      ]),
      error: (e, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionHeader(title: title, subtitle: addon.displayName),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GlassSurface(padding: const EdgeInsets.all(14), child: Row(children: [
            const Icon(Icons.cloud_off_rounded, size: 20, color: AetherTokens.warning),
            const SizedBox(width: 10),
            Expanded(child: Text('$e', style: Theme.of(context).textTheme.bodySmall)),
            GlassButton(icon: Icons.refresh_rounded, tooltip: 'Riprova', size: 40, onPressed: () => ref.invalidate(catalogProvider(CatalogQuery(addon.id, catalog.key)))),
          ])),
        ),
      ]),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        final landscape = items.first.landscape;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionHeader(title: title, subtitle: '${addon.displayName} · ${_typeName(catalog.type)}'),
          SizedBox(
            height: landscape ? 150 : 232,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: AetherTokens.pageMargin),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) => PosterCard(item: items[i], width: landscape ? 220 : 120, onTap: () => openTitle(context, items[i])),
            ),
          ),
        ]);
      },
    );
  }
}

String _typeName(String type) => switch (type) { 'movie' => 'Film', 'series' => 'Serie', 'anime' => 'Anime', 'tv' => 'TV', 'channel' => 'Canali', _ => type };
String typeName(String type) => _typeName(type);
