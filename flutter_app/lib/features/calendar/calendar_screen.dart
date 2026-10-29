import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/model/meta.dart';
import '../../data/prefs_ext.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';

/// One episode that has come out (or will) of a series the viewer follows.
class CalendarEntry {
  const CalendarEntry(this.meta, this.video, this.when);
  final MetaItem meta;
  final Video video;
  final DateTime when;

  /// An episode dated at midnight (UTC) has no real time: it counts from the morning of that day.
  static DateTime moment(DateTime released) {
    final local = released.toLocal();
    final dateOnly =
        released.isUtc &&
        released.hour == 0 &&
        released.minute == 0 &&
        released.second == 0;
    return dateOnly
        ? DateTime(released.year, released.month, released.day, 9)
        : local;
  }
}

/// The series followed: those being watched, and (when the setting asks) the watchlist and the favourites.
List<MetaItem> followedSeries(Ref ref) {
  final lib = ref.read(servicesProvider).library;
  final s = ref.read(settingsProvider);
  final byId = <String, MetaItem>{};
  for (final p in lib.continueWatching) {
    if (p.type == 'series') {
      byId[p.metaId] = MetaItem(
        id: p.metaId,
        type: 'series',
        name: p.name,
        poster: p.poster,
      );
    }
  }
  if (s.notifyWatchlist) {
    for (final m in [...lib.watchlist, ...lib.favorites]) {
      if (m.type == 'series') byId.putIfAbsent(m.id, () => m);
    }
  }
  return byId.values.take(40).toList();
}

/// The episodes of the followed series from a week ago to [AppSettings.calendarDays] ahead, by date.
final calendarProvider = FutureProvider.autoDispose<List<CalendarEntry>>((
  ref,
) async {
  ref.watch(libraryVersionProvider);
  final days = ref.read(settingsProvider).calendarDays;
  final from = DateTime.now().subtract(const Duration(days: 7));
  final to = DateTime.now().add(Duration(days: days));
  final metas = await Future.wait([
    for (final m in followedSeries(ref))
      ref
          .read(metaProvider(MetaKey(m.type, m.id)).future)
          .timeout(const Duration(seconds: 10))
          .then<MetaItem?>((v) => v, onError: (_) => null),
  ]);
  final out = <CalendarEntry>[];
  for (final meta in metas.whereType<MetaItem>()) {
    for (final v in meta.videos) {
      final r = v.released;
      if (r == null || !v.isEpisode || v.season == 0) continue;
      final when = CalendarEntry.moment(r);
      if (when.isAfter(from) && when.isBefore(to)) {
        out.add(CalendarEntry(meta, v, when));
      }
    }
  }
  out.sort((a, b) => a.when.compareTo(b.when));
  return out;
});

class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  static const _days = ['lun', 'mar', 'mer', 'gio', 'ven', 'sab', 'dom'];
  static const _months = [
    'gen',
    'feb',
    'mar',
    'apr',
    'mag',
    'giu',
    'lug',
    'ago',
    'set',
    'ott',
    'nov',
    'dic',
  ];

  String _day(DateTime d) {
    final today = DateTime.now();
    final diff = DateTime(
      d.year,
      d.month,
      d.day,
    ).difference(DateTime(today.year, today.month, today.day)).inDays;
    if (diff == 0) return 'Oggi';
    if (diff == 1) return 'Domani';
    if (diff == -1) return 'Ieri';
    return '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(calendarProvider);
    final now = DateTime.now();
    return Scaffold(
      body: AetherBackdrop(
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                        'Calendario',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                    GlassButton(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Aggiorna',
                      onPressed: () => ref.invalidate(calendarProvider),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => const EmptyState(
                    icon: Icons.error_outline_rounded,
                    title: 'Non riesco a leggere il calendario',
                  ),
                  data: (list) {
                    if (list.isEmpty) {
                      return const EmptyState(
                        icon: Icons.event_busy_rounded,
                        title: 'Nessuna uscita in vista',
                        message: 'Compaiono gli episodi delle serie che guardi (e della watchlist, se attivo in Impostazioni ▸ Contenuti).',
                      );
                    }
                    final groups = <String, List<CalendarEntry>>{};
                    for (final e in list) {
                      groups.putIfAbsent(_day(e.when), () => []).add(e);
                    }
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
                      children: [
                        for (final g in groups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                            child: Text(
                              g.key,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          for (final e in g.value)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: GestureDetector(
                                onTap: () => openTitle(context, e.meta),
                                child: GlassSurface(
                                  radius: 16,
                                  padding: const EdgeInsets.all(10),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 46,
                                        height: 68,
                                        child: PosterImage(
                                          url: e.meta.poster,
                                          title: e.meta.name,
                                          radius: 8,
                                          cacheWidth: 200,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              e.meta.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            Text(
                                              '${e.video.label}${e.video.title == e.video.label ? '' : ' · ${e.video.title}'}',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
                                      Pill(
                                        e.when.isAfter(now)
                                            ? 'In arrivo'
                                            : 'Uscito',
                                        color: e.when.isAfter(now)
                                            ? AetherTokens.warning
                                            : AetherTokens.success,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
