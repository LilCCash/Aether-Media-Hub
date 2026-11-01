import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/sync/trakt_catalog.dart';
import '../../data/prefs_ext.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';

final traktCatalogProvider = Provider<TraktCatalogService>((ref) {
  final s = ref.watch(servicesProvider);
  return TraktCatalogService(s.sync.trakt, s.tmdb);
});

final traktLinkedProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(servicesProvider).sync.trakt.linked,
);

final traktShelfProvider = FutureProvider.autoDispose
    .family<List<TraktShelf>, (TraktCatalogKind, int, String)>(
      (ref, a) => ref.watch(traktCatalogProvider).items(a.$1, a.$2, a.$3),
    );

final traktListsProvider = FutureProvider.autoDispose<List<TraktListInfo>>(
  (ref) => ref.watch(traktCatalogProvider).lists(),
);

final traktListItemsProvider = FutureProvider.autoDispose
    .family<List<TraktShelf>, (int, int, String)>(
      (ref, a) => ref.watch(traktCatalogProvider).listItems(a.$1, a.$2, a.$3),
    );

/// Altro ▸ Trakt: i cataloghi di Trakt (in tendenza, popolari, consigliati, la tua lista, le tue liste, da riprendere, calendario).
class TraktScreen extends ConsumerWidget {
  const TraktScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final linked = ref.watch(traktLinkedProvider).value ?? false;
    final lang = s.advancedConfig.language;
    final kinds = [
      for (final k in TraktCatalogKind.values)
        if (!s.traktHidden.contains(k.name) && (!k.needsLogin || linked)) k,
    ];
    return Scaffold(
      body: AetherBackdrop(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 120),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    GlassButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      tooltip: 'Indietro',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Trakt',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                    GlassButton(
                      icon: Icons.tune_rounded,
                      tooltip: 'Opzioni di Trakt',
                      onPressed: () => context.push('/settings/trakt'),
                    ),
                  ],
                ),
              ),
              if (!linked)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    'Collega il tuo account (Impostazioni ▸ Servizi ▸ Trakt) per vedere watchlist, consigliati, liste e calendario. Intanto ci sono i cataloghi pubblici.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              for (final k in kinds)
                _Shelf(
                  title: k.title,
                  data: ref.watch(traktShelfProvider((k, s.traktItems, lang))),
                ),
              if (linked && s.traktLists)
                ...(ref.watch(traktListsProvider).value ?? const []).map(
                  (l) => _Shelf(
                    title: '${l.name} (${l.count})',
                    data: ref.watch(
                      traktListItemsProvider((l.id, s.traktItems, lang)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Shelf extends StatelessWidget {
  const _Shelf({required this.title, required this.data});
  final String title;
  final AsyncValue<List<TraktShelf>> data;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        data.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(20),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text('Trakt non risponde.', style: style),
          ),
          data: (items) => items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Text('Niente da mostrare.', style: style),
                )
              : SizedBox(
                  height: AetherLook.of(context).rowHeight(250),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AetherTokens.pageMargin,
                    ),
                    scrollDirection: Axis.horizontal,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PosterCard(
                          item: items[i].meta,
                          onTap: () => openTitle(context, items[i].meta),
                        ),
                        if (items[i].note != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(items[i].note!, style: style),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Opzioni dei cataloghi di Trakt: quali mostrare e quanti titoli.
class TraktCatalogSettingsPage extends ConsumerWidget {
  const TraktCatalogSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final hidden = s.traktHidden;
    return Scaffold(
      appBar: AppBar(title: const Text('Trakt: cataloghi')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          SwitchListTile(
            title: const Text('Sincronizza all\'apertura dell\'app'),
            subtitle: const Text(
              'Porta da Trakt i titoli visti e la watchlist, e manda a Trakt quelli visti qui',
            ),
            value: s.traktSyncOnLaunch,
            onChanged: (v) =>
                n.update((x) => x.withExt('traktSyncOnLaunch', v)),
          ),
          SwitchListTile(
            title: const Text('Le tue liste personali'),
            value: s.traktLists,
            onChanged: (v) => n.update((x) => x.withExt('traktLists', v)),
          ),
          ListTile(
            title: Text('Titoli per catalogo: ${s.traktItems}'),
            subtitle: Slider(
              value: s.traktItems.toDouble(),
              min: 5,
              max: 50,
              divisions: 9,
              onChanged: (v) =>
                  n.update((x) => x.withExt('traktItems', v.round())),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Cataloghi da mostrare',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          for (final k in TraktCatalogKind.values)
            SwitchListTile(
              title: Text(k.title),
              subtitle: k.needsLogin
                  ? const Text('Richiede l\'account collegato')
                  : null,
              value: !hidden.contains(k.name),
              onChanged: (v) => n.update(
                (x) => x.withExt('traktHidden', [
                  for (final h in hidden)
                    if (h != k.name) h,
                  if (!v) k.name,
                ]),
              ),
            ),
        ],
      ),
    );
  }
}
