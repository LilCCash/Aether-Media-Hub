import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../player/playback_engine.dart';
import '../player/player_session.dart';
import 'download_manager.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.watch(servicesProvider).downloads;
    return Scaffold(
      body: AetherBackdrop(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: dl,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                Row(
                  children: [
                    GlassButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      tooltip: 'Indietro',
                      onPressed: () => context.pop(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Download',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Qui ci sono i file scaricati da link diretti: si guardano anche senza rete. I torrent TorBox non si scaricano sul telefono.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (dl.items.isEmpty)
                  const EmptyState(
                    icon: Icons.download_for_offline_outlined,
                    title: 'Nessun download',
                    message: 'Nell’elenco delle sorgenti, le sorgenti con link diretto hanno il pulsante di download.',
                  ),
                for (final d in dl.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GlassSurface(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 52,
                            height: 78,
                            child: PosterImage(
                              url: d.poster,
                              title: d.title,
                              radius: 10,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                if (d.status == DownloadStatus.running ||
                                    d.status == DownloadStatus.paused)
                                  LinearProgressIndicator(
                                    value: d.fraction,
                                    minHeight: 4,
                                  ),
                                const SizedBox(height: 4),
                                Text(
                                  _status(d),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: d.status == DownloadStatus.failed
                                        ? AetherTokens.warning
                                        : AetherTokens.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (d.status == DownloadStatus.done)
                            IconButton(
                              tooltip: 'Guarda',
                              icon: const Icon(Icons.play_circle_fill_rounded),
                              onPressed: () => context.push(
                                '/player',
                                extra: PlayerArgs(
                                  title: d.title,
                                  metaId: d.metaId,
                                  videoId: d.videoId,
                                  type: d.type,
                                  poster: d.poster,
                                  season: d.season,
                                  episode: d.episode,
                                  source: PlaybackSource(
                                    uri: dl.pathOf(d),
                                    isLocalFile: true,
                                  ),
                                ),
                              ),
                            )
                          else if (d.status == DownloadStatus.running)
                            IconButton(
                              tooltip: 'Metti in pausa',
                              icon: const Icon(
                                Icons.pause_circle_outline_rounded,
                              ),
                              onPressed: () => dl.pause(d.id),
                            )
                          else
                            IconButton(
                              tooltip: 'Riprendi',
                              icon: const Icon(
                                Icons.play_circle_outline_rounded,
                              ),
                              onPressed: () => dl.resume(d.id),
                            ),
                          IconButton(
                            tooltip: 'Elimina',
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () => dl.remove(d.id),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _mb(int b) => b >= 1073741824
      ? '${(b / 1073741824).toStringAsFixed(2)} GB'
      : '${(b / 1048576).toStringAsFixed(0)} MB';

  String _status(DownloadItem d) => switch (d.status) {
    DownloadStatus.queued => 'In coda',
    DownloadStatus.running =>
      d.total > 0
          ? 'Scarico… ${_mb(d.received)} / ${_mb(d.total)}'
          : 'Scarico… ${_mb(d.received)}',
    DownloadStatus.paused => 'In pausa · ${_mb(d.received)}',
    DownloadStatus.failed => d.error ?? 'Non riuscito',
    DownloadStatus.done => 'Disponibile offline · ${_mb(d.total)}',
  };
}
