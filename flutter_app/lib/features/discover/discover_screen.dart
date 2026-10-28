import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/addons/addon_repository.dart';
import '../../core/model/manifest.dart';
import '../../core/model/meta.dart';
import '../../design/glass.dart';
import '../../design/widgets.dart';
import '../home/home_screen.dart';

/// Browse one catalog at a time as a grid, with a type filter, a catalog choice, an optional genre and endless scrolling (`skip`).
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  String? _type;
  String? _catalogKey; // "addonId/type/id"
  String? _genre;
  final List<MetaItem> _items = [];
  final Set<String> _seen = {};
  bool _loading = false;
  bool _end = false;
  String? _error;
  int _generation = 0;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600)
        _loadMore();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<(InstalledAddon, ManifestCatalog)> _catalogs() {
    final s = ref.read(settingsProvider);
    return visibleCatalogs(
      ref.read(addonsProvider),
      s.hiddenHomeCatalogs,
      s.catalogOrder,
      hideAdult: s.hideAdultCatalogs,
    );
  }

  (InstalledAddon, ManifestCatalog)? _selected(
    List<(InstalledAddon, ManifestCatalog)> all,
  ) {
    final ofType = all
        .where((e) => _type == null || e.$2.type == _type)
        .toList();
    if (ofType.isEmpty) return null;
    return ofType.firstWhere(
      (e) => '${e.$1.id}/${e.$2.key}' == _catalogKey,
      orElse: () => ofType.first,
    );
  }

  void _reset() {
    _generation++;
    _items.clear();
    _seen.clear();
    _end = false;
    _error = null;
    _loading = false;
    setState(() {});
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _end) return;
    final all = _catalogs();
    final sel = _selected(all);
    if (sel == null) return;
    final gen = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(servicesProvider)
          .addonClient
          .catalog(
            sel.$1.base,
            sel.$2,
            extra: {
              if (_genre != null) 'genre': _genre!,
              if (_items.isNotEmpty) 'skip': '${_items.length}',
            },
          );
      if (gen != _generation || !mounted) return;
      final fresh = page.items.where((m) => _seen.add(m.id)).toList();
      setState(() {
        _items.addAll(fresh);
        if (fresh.isEmpty) _end = true;
      });
    } on Object catch (e) {
      if (gen != _generation || !mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (gen == _generation && mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(addonsProvider);
    final all = _catalogs();
    final types = {for (final e in all) e.$2.type}.toList();
    final sel = _selected(all);
    if (sel != null && _items.isEmpty && !_loading && !_end && _error == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => mounted ? _loadMore() : null,
      );
    }
    final genres = sel?.$2.genres ?? const <String>[];
    return AetherBackdrop(
      child: SafeArea(
        bottom: false,
        child: all.isEmpty
            ? const EmptyState(
                icon: Icons.explore_off_rounded,
                title: 'Niente da esplorare',
                message: 'Installa un addon con cataloghi per sfogliare film e serie.',
              )
            : CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                      child: Text(
                        'Scopri',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 56,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final t in types)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: GlassButton(
                                label: typeName(t),
                                selected: (_type ?? types.first) == t,
                                size: 40,
                                onPressed: () {
                                  _type = t;
                                  _catalogKey = null;
                                  _genre = null;
                                  _reset();
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 52,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final e in all.where(
                            (e) => e.$2.type == (_type ?? types.first),
                          ))
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: GlassButton(
                                label:
                                    ref
                                        .read(settingsProvider)
                                        .catalogTitles['${e.$1.id}/${e.$2.key}'] ??
                                    e.$2.name,
                                size: 36,
                                selected:
                                    sel != null &&
                                    e.$1.id == sel.$1.id &&
                                    e.$2.key == sel.$2.key,
                                onPressed: () {
                                  _catalogKey = '${e.$1.id}/${e.$2.key}';
                                  _genre = null;
                                  _reset();
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (genres.isNotEmpty)
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 48,
                        child: ListView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          scrollDirection: Axis.horizontal,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: GlassButton(
                                label: 'Tutti i generi',
                                size: 34,
                                selected: _genre == null,
                                onPressed: () {
                                  _genre = null;
                                  _reset();
                                },
                              ),
                            ),
                            for (final g in genres)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: GlassButton(
                                  label: g,
                                  size: 34,
                                  selected: _genre == g,
                                  onPressed: () {
                                    _genre = g;
                                    _reset();
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 130,
                            childAspectRatio: 0.52,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemCount: _items.length,
                      itemBuilder: (context, i) => PosterCard(
                        item: _items[i],
                        width: 130,
                        onTap: () => openTitle(context, _items[i]),
                      ),
                    ),
                  ),
                  if (_loading)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  if (_error != null)
                    SliverToBoxAdapter(
                      child: ErrorState(message: _error!, onRetry: _loadMore),
                    ),
                  if (!_loading &&
                      _error == null &&
                      _items.isEmpty &&
                      sel != null)
                    const SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.movie_filter_rounded,
                        title: 'Nessun risultato',
                        message: 'Questo catalogo non ha restituito titoli.',
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 120)),
                ],
              ),
      ),
    );
  }
}
