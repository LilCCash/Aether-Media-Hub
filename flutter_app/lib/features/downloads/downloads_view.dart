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

String _mb(int b) => b >= 1073741824
    ? '${(b / 1073741824).toStringAsFixed(2)} GB'
    : '${(b / 1048576).toStringAsFixed(0)} MB';

/// What is downloading and what is on the phone: films and, for series, a group per series with a group per season.
/// Everything is listed at once, whatever its state.
class DownloadsBody extends ConsumerStatefulWidget {
  const DownloadsBody({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 120),
  });
  final EdgeInsets padding;

  @override
  ConsumerState<DownloadsBody> createState() => _DownloadsBodyState();
}

class _DownloadsBodyState extends ConsumerState<DownloadsBody> {
  @override
  Widget build(BuildContext context) {
    final dl = ref.watch(servicesProvider).downloads;
    return ListenableBuilder(
      listenable: dl,
      builder: (context, _) {
        final all = dl.items;
        final shown = all;
        final running = all
            .where((d) => d.status == DownloadStatus.running)
            .length;
        final queued = all
            .where((d) => d.status == DownloadStatus.queued)
            .length;
        // Series first grouped by series, then by season; films alone.
        final series = <String, List<DownloadItem>>{};
        final films = <DownloadItem>[];
        for (final d in shown) {
          if (d.season != null) {
            series.putIfAbsent(d.metaId, () => []).add(d);
          } else {
            films.add(d);
          }
        }
        return ListView(
          padding: widget.padding,
          children: [
            if (running + queued > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$running in corso${queued > 0 ? ' · $queued in coda' : ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        for (final d in all.where(
                          (d) => d.status == DownloadStatus.running,
                        )) {
                          dl.pause(d.id);
                        }
                      },
                      icon: const Icon(Icons.pause_rounded, size: 18),
                      label: const Text('Pausa tutti'),
                    ),
                  ],
                ),
              ),
            if (all.any(
              (d) =>
                  d.status == DownloadStatus.paused ||
                  d.status == DownloadStatus.failed,
            ))
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () {
                    for (final d in all.where(
                      (d) =>
                          d.status == DownloadStatus.paused ||
                          d.status == DownloadStatus.failed,
                    )) {
                      dl.resume(d.id);
                    }
                  },
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Riprendi tutti'),
                ),
              ),
            if (shown.isEmpty)
              EmptyState(
                icon: Icons.download_for_offline_outlined,
                title: 'Nessun download',
                message: all.isEmpty
                    ? 'Dall’elenco delle sorgenti, dal menu ⋮ o dal pulsante «Scarica la stagione» nella scheda di una serie.'
                    : '',
              ),
            for (final entry in series.entries)
              _SeriesGroup(items: entry.value, dl: dl),
            if (films.isNotEmpty) ...[
              if (series.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 8, 4, 6),
                  child: Text(
                    'FILM E ALTRO',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AetherTokens.textTertiary,
                    ),
                  ),
                ),
              for (final d in films) _DownloadRow(d: d, dl: dl),
            ],
          ],
        );
      },
    );
  }
}

String _seriesName(DownloadItem d) => d.title.split(' · ').first;

class _SeriesGroup extends StatelessWidget {
  const _SeriesGroup({required this.items, required this.dl});
  final List<DownloadItem> items;
  final DownloadManager dl;

  @override
  Widget build(BuildContext context) {
    final seasons = <int, List<DownloadItem>>{};
    for (final d in items) {
      seasons.putIfAbsent(d.season!, () => []).add(d);
    }
    final order = seasons.keys.toList()..sort();
    final done = items.where((d) => d.status == DownloadStatus.done).length;
    final first = items.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassSurface(
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: order.length == 1,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            shape: const Border(),
            collapsedShape: const Border(),
            leading: SizedBox(
              width: 42,
              height: 62,
              child: PosterImage(
                url: first.poster,
                title: first.title,
                radius: 8,
              ),
            ),
            title: Text(
              _seriesName(first),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              '${order.length} ${order.length == 1 ? 'stagione' : 'stagioni'} · $done/${items.length} completati',
              style: const TextStyle(
                fontSize: 12,
                color: AetherTokens.textTertiary,
              ),
            ),
            children: [
              for (final s in order)
                _SeasonGroup(
                  season: s,
                  items: seasons[s]!
                    ..sort(
                      (a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0),
                    ),
                  dl: dl,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeasonGroup extends StatelessWidget {
  const _SeasonGroup({
    required this.season,
    required this.items,
    required this.dl,
  });
  final int season;
  final List<DownloadItem> items;
  final DownloadManager dl;

  @override
  Widget build(BuildContext context) {
    final done = items.where((d) => d.status == DownloadStatus.done).length;
    final total = items.fold<int>(0, (a, d) => a + d.total);
    final got = items.fold<int>(
      0,
      (a, d) => a + (d.status == DownloadStatus.done ? d.total : d.received),
    );
    final busy = items.any(
      (d) =>
          d.status == DownloadStatus.running ||
          d.status == DownloadStatus.queued,
    );
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(24, 0, 8, 0),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          season == 0 ? 'Speciali' : 'Stagione $season',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (done < items.length)
                LinearProgressIndicator(
                  value: total > 0 ? (got / total).clamp(0.0, 1.0) : null,
                  minHeight: 3,
                ),
              const SizedBox(height: 3),
              Text(
                '$done/${items.length} episodi${total > 0 ? ' · ${_mb(got)} / ${_mb(total)}' : ''}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AetherTokens.textTertiary,
                ),
              ),
            ],
          ),
        ),
        trailing: PopupMenuButton<String>(
          color: AetherTokens.inkRaised,
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (v) {
            for (final d in items) {
              switch (v) {
                case 'pause':
                  if (d.status == DownloadStatus.running ||
                      d.status == DownloadStatus.queued)
                    dl.pause(d.id);
                case 'resume':
                  if (d.status == DownloadStatus.paused ||
                      d.status == DownloadStatus.failed)
                    dl.resume(d.id);
                case 'delete':
                  dl.remove(d.id);
              }
            }
          },
          itemBuilder: (_) => [
            if (busy)
              const PopupMenuItem(
                value: 'pause',
                child: Text('Metti in pausa la stagione'),
              ),
            if (!busy && done < items.length)
              const PopupMenuItem(
                value: 'resume',
                child: Text('Riprendi la stagione'),
              ),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Elimina la stagione'),
            ),
          ],
        ),
        children: [
          for (final d in items) _DownloadRow(d: d, dl: dl, compact: true),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.d, required this.dl, this.compact = false});
  final DownloadItem d;
  final DownloadManager dl;
  final bool compact;

  String get _status => switch (d.status) {
    DownloadStatus.queued => d.error ?? 'In coda',
    DownloadStatus.running =>
      d.total > 0
          ? 'Scarico… ${_mb(d.received)} / ${_mb(d.total)}'
          : 'Scarico… ${_mb(d.received)}',
    DownloadStatus.paused => 'In pausa · ${_mb(d.received)}',
    DownloadStatus.failed => d.error ?? 'Non riuscito',
    DownloadStatus.done => 'Disponibile offline · ${_mb(d.total)}',
  };

  @override
  Widget build(BuildContext context) {
    final title = compact
        ? (d.episode != null ? 'Episodio ${d.episode}' : d.title)
        : d.title;
    final body = Row(
      children: [
        if (!compact) ...[
          SizedBox(
            width: 52,
            height: 78,
            child: PosterImage(url: d.poster, title: d.title, radius: 10),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              if (d.status == DownloadStatus.running ||
                  d.status == DownloadStatus.paused)
                LinearProgressIndicator(value: d.fraction, minHeight: 4),
              const SizedBox(height: 3),
              Text(
                _status,
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
                source: PlaybackSource(uri: dl.pathOf(d), isLocalFile: true),
              ),
            ),
          )
        else if (d.status == DownloadStatus.running ||
            d.status == DownloadStatus.queued)
          IconButton(
            tooltip: 'Metti in pausa',
            icon: const Icon(Icons.pause_circle_outline_rounded),
            onPressed: () => dl.pause(d.id),
          )
        else
          IconButton(
            tooltip: 'Riprendi',
            icon: const Icon(Icons.play_circle_outline_rounded),
            onPressed: () => dl.resume(d.id),
          ),
        IconButton(
          tooltip: 'Elimina',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () => dl.remove(d.id),
        ),
      ],
    );
    return compact
        ? Padding(padding: const EdgeInsets.fromLTRB(24, 4, 8, 4), child: body)
        : Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GlassSurface(padding: const EdgeInsets.all(12), child: body),
          );
  }
}
