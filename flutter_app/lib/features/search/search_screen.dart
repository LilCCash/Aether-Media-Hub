import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/catalog/result_filters.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../home/home_screen.dart';

const _recentKey = 'search.recent.v1';

/// Global search: every enabled addon with a searchable catalog answers in parallel and results appear as they arrive.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  List<String> _recent = [];
  ResultFilters _filters = ResultFilters.none;

  @override
  void initState() {
    super.initState();
    ref.read(servicesProvider).store.read(_recentKey).then((raw) {
      if (raw != null && mounted)
        setState(
          () => _recent = raw.split('\n').where((e) => e.isNotEmpty).toList(),
        );
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  Future<void> _remember(String q) async {
    _recent = [q, ..._recent.where((e) => e != q)].take(8).toList();
    await ref
        .read(servicesProvider)
        .store
        .write(_recentKey, _recent.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    final searchable = ref
        .watch(addonsProvider)
        .where(
          (a) => a.enabled && a.manifest.catalogs.any((c) => c.isSearchable),
        )
        .isNotEmpty;
    return AetherBackdrop(
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Text(
                'Cerca',
                style: Theme.of(context).textTheme.displaySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GlassSurface(
                radius: 20,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _controller,
                  onChanged: _onChanged,
                  onSubmitted: (v) {
                    setState(() => _query = v.trim());
                    if (v.trim().length >= 2) _remember(v.trim());
                  },
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Film, serie, anime…',
                    icon: const Icon(Icons.search_rounded),
                    suffixIcon: _controller.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Cancella',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(() {
                              _controller.clear();
                              _query = '';
                            }),
                          ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: !searchable
                  ? EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'Nessun addon con ricerca',
                      message:
                          'Installa un addon che offre cataloghi con ricerca.',
                      action: GlassButton(
                        label: 'Gestisci gli addon',
                        icon: Icons.extension_rounded,
                        onPressed: () => context.push('/addons'),
                      ),
                    )
                  : _query.length < 2
                  ? _recentList()
                  : _results(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recentList() {
    if (_recent.isEmpty)
      return const EmptyState(
        icon: Icons.manage_search_rounded,
        title: 'Cerca in tutti i tuoi addon',
        message: 'Scrivi almeno due lettere.',
      );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        Row(
          children: [
            Text(
              'Ricerche recenti',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            TextButton(
              onPressed: () async {
                setState(() => _recent = []);
                await ref.read(servicesProvider).store.remove(_recentKey);
              },
              child: const Text('Cancella'),
            ),
          ],
        ),
        for (final r in _recent)
          ListTile(
            leading: const Icon(Icons.history_rounded),
            title: Text(r),
            onTap: () => setState(() {
              _controller.text = r;
              _query = r;
            }),
          ),
      ],
    );
  }

  Widget _results() {
    final async = ref.watch(searchProvider(_query));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorState(message: '$e'),
      data: (state) {
        if (state.groups.isEmpty && !state.loading) {
          return EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Nessun risultato per «$_query»',
            message: state.errors.isEmpty
                ? null
                : '${state.errors.length} addon non hanno risposto.',
          );
        }
        final every = [for (final g in state.groups) ...g.items];
        final groups = [
          for (final g in state.groups)
            if (_filters.type == null || g.type == _filters.type)
              SearchGroup(
                g.addonName,
                g.catalogName,
                g.type,
                _filters.copyWith(type: null).apply(g.items),
              ),
        ].where((g) => g.items.isNotEmpty).toList();
        return ListView(
          padding: const EdgeInsets.only(bottom: 120),
          children: [
            FilterBar(
              filters: _filters,
              types: {for (final g in state.groups) g.type}.toList()..sort(),
              genres: ResultFilters.genresOf(every),
              decades: ResultFilters.decadesOf(every),
              typeName: typeName,
              onChanged: (f) => setState(() => _filters = f),
            ),
            if (groups.isEmpty && _filters.active)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Nessun risultato con questi filtri.'),
              ),
            if (state.loading)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'In attesa di ${state.pending} addon…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            for (final g in groups) ...[
              SectionHeader(
                title: g.catalogName,
                subtitle: '${g.addonName} · ${typeName(g.type)}',
              ),
              SizedBox(
                height: 232,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AetherTokens.pageMargin,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: g.items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) => PosterCard(
                    item: g.items[i],
                    onTap: () => openTitle(context, g.items[i]),
                  ),
                ),
              ),
            ],
            if (state.errors.isNotEmpty && !state.loading)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Non hanno risposto: ${state.errors.keys.join(', ')}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        );
      },
    );
  }
}
