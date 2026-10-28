import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/addons/addon_repository.dart';
import '../../core/catalog/result_filters.dart';
import '../../data/prefs_ext.dart';
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
  int? _year;
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

  /// The loaded titles that match the year chosen (addons have no year filter, so it is applied here).
  List<MetaItem> get _visible => _year == null
      ? _items
      : _items.where((m) => ResultFilters.yearOf(m) == _year).toList();

  Widget _gap(Widget w) =>
      Padding(padding: const EdgeInsets.only(right: 8), child: w);

  /// With a year chosen, keep loading pages (a few at most) until enough titles of that year show up.
  Future<void> _fillForYear() async {
    for (
      var i = 0;
      i < 6 && _year != null && !_end && _visible.length < 18;
      i++
    ) {
      await _loadMore();
    }
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
    final wanted =
        _catalogKey ??
        ref
            .read(settingsProvider)
            .discoverDefaultFor(_type ?? ofType.first.$2.type);
    return ofType.firstWhere(
      (e) => '${e.$1.id}/${e.$2.key}' == wanted,
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
    _loadMore().then((_) => _fillForYear());
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
    final hidden = ref.watch(settingsProvider).discoverHidden;
    final types = {for (final e in all) e.$2.type}
        .where((t) => !hidden.contains(t))
        .toList();
    if (types.isNotEmpty && (_type == null || !types.contains(_type))) {
      _type = types.first;
    }
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
                      height: 54,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        scrollDirection: Axis.horizontal,
                        children: [
                          if (types.length > 1)
                            _gap(
                              DropChip<String>(
                                label: 'Tipo',
                                icon: Icons.category_rounded,
                                value: _type ?? types.first,
                                options: {
                                  for (final t in types) t: typeName(t),
                                },
                                onSelected: (t) {
                                  _type = t;
                                  _catalogKey = null;
                                  _genre = null;
                                  _reset();
                                },
                              ),
                            ),
                          _gap(
                            DropChip<String>(
                              label: 'Catalogo',
                              icon: Icons.view_list_rounded,
                              value: sel == null
                                  ? null
                                  : '${sel.$1.id}/${sel.$2.key}',
                              options: {
                                for (final e in all.where(
                                  (e) => e.$2.type == (_type ?? types.first),
                                ))
                                  '${e.$1.id}/${e.$2.key}':
                                      ref
                                          .read(settingsProvider)
                                          .catalogTitles['${e.$1.id}/${e.$2.key}'] ??
                                      e.$2.name,
                              },
                              onSelected: (k) {
                                _catalogKey = k;
                                _genre = null;
                                _reset();
                              },
                            ),
                          ),
                          if (genres.isNotEmpty)
                            _gap(
                              DropChip<String>(
                                label: 'Genere',
                                icon: Icons.theater_comedy_rounded,
                                value: _genre ?? '',
                                options: {
                                  '': 'Tutti i generi',
                                  for (final g in genres) g: g,
                                },
                                onSelected: (g) {
                                  _genre = g.isEmpty ? null : g;
                                  _reset();
                                },
                              ),
                            ),
                          _gap(
                            DropChip<int>(
                              label: 'Anno',
                              icon: Icons.calendar_month_rounded,
                              value: _year ?? 0,
                              options: {
                                0: 'Tutti gli anni',
                                for (
                                  var y = DateTime.now().year;
                                  y >= 1950;
                                  y--
                                )
                                  y: '$y',
                              },
                              onSelected: (y) {
                                setState(() => _year = y == 0 ? null : y);
                                _fillForYear();
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
                      itemCount: _visible.length,
                      itemBuilder: (context, i) => PosterCard(
                        item: _visible[i],
                        width: 130,
                        onTap: () => openTitle(context, _visible[i]),
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
                      _visible.isEmpty &&
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
