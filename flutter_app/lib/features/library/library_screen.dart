import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/model/meta.dart';
import '../../data/library_repository.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  int _tab = 0;
  static const _tabs = ['Continua', 'Watchlist', 'Preferiti', 'Cronologia'];

  @override
  Widget build(BuildContext context) {
    ref.watch(libraryVersionProvider);
    final lib = ref.watch(servicesProvider).library;
    return AetherBackdrop(
      child: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 6), child: Text('Libreria', style: Theme.of(context).textTheme.displaySmall)),
          SizedBox(
            height: 52,
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), scrollDirection: Axis.horizontal, children: [
              for (var i = 0; i < _tabs.length; i++) Padding(padding: const EdgeInsets.only(right: 8), child: GlassButton(label: _tabs[i], size: 38, selected: _tab == i, onPressed: () => setState(() => _tab = i))),
            ]),
          ),
          Expanded(child: switch (_tab) {
            0 => _progressList(lib.continueWatching, 'Niente da riprendere', 'I film e gli episodi che inizi a guardare compaiono qui.', lib),
            1 => _grid(lib.watchlist, 'Watchlist vuota', 'Aggiungi titoli con il pulsante + nella loro scheda.'),
            2 => _grid(lib.favorites, 'Nessun preferito', 'Tocca il cuore nella scheda di un titolo.'),
            _ => _progressList(lib.history, 'Cronologia vuota', 'Ciò che guardi viene ricordato solo su questo dispositivo.', lib, clearable: true),
          }),
        ]),
      ),
    );
  }

  Widget _grid(List<MetaItem> items, String title, String message) {
    if (items.isEmpty) return EmptyState(icon: Icons.video_library_outlined, title: title, message: message);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, childAspectRatio: 0.52, crossAxisSpacing: 12, mainAxisSpacing: 12),
      itemCount: items.length,
      itemBuilder: (context, i) => PosterCard(item: items[i], width: 130, onTap: () => openTitle(context, items[i])),
    );
  }

  Widget _progressList(List<WatchProgress> items, String title, String message, LibraryRepository lib, {bool clearable = false}) {
    if (items.isEmpty) return EmptyState(icon: Icons.history_rounded, title: title, message: message);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      itemCount: items.length + (clearable ? 1 : 0),
      itemBuilder: (context, i) {
        if (clearable && i == items.length) {
          return Padding(padding: const EdgeInsets.only(top: 16), child: Center(child: GlassButton(icon: Icons.delete_outline_rounded, label: 'Cancella la cronologia', onPressed: () async {
            final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('Cancellare la cronologia?'), content: const Text('Si perdono anche i punti di ripresa.'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annulla')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancella'))]));
            if (ok == true) {
              await lib.clearHistory();
              ref.read(libraryVersionProvider.notifier).bump();
            }
          })));
        }
        final p = items[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GestureDetector(
            onTap: () => openTitle(context, MetaItem(id: p.metaId, type: p.type, name: p.name, poster: p.poster)),
            child: GlassSurface(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                SizedBox(width: 56, height: 84, child: PosterImage(url: p.poster, title: p.name, radius: 10)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                  if (p.season != null) Text('Stagione ${p.season} · Episodio ${p.episode}', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: p.completed ? 1 : p.fraction, minHeight: 4, backgroundColor: Colors.white12)),
                  const SizedBox(height: 4),
                  Text(p.completed ? 'Visto' : '${(p.fraction * 100).round()}%', style: const TextStyle(fontSize: 11, color: AetherTokens.textTertiary)),
                ])),
                IconButton(tooltip: 'Rimuovi dalla cronologia', icon: const Icon(Icons.close_rounded, size: 20), onPressed: () async {
                  await lib.removeFromHistory(p.videoId);
                  ref.read(libraryVersionProvider.notifier).bump();
                }),
              ]),
            ),
          ),
        );
      },
    );
  }
}
