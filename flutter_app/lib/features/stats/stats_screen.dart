import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/library_repository.dart';
import '../../design/glass.dart';
import '../../design/widgets.dart';

/// What the viewer has watched, computed from the local history (nothing leaves the device).
class WatchStats {
  WatchStats(List<WatchProgress> history, {DateTime? now}) {
    final today = DateTime.now();
    final base = DateTime(
      (now ?? today).year,
      (now ?? today).month,
      (now ?? today).day,
    );
    final titles = <String, int>{};
    for (final p in history) {
      final ms = p.completed && p.durationMs > 0 ? p.durationMs : p.positionMs;
      totalMs += ms;
      if (p.type == 'series') {
        episodes++;
      } else {
        films++;
      }
      titles.update(p.name, (v) => v + ms, ifAbsent: () => ms);
      final day = DateTime(
        p.updatedAt.year,
        p.updatedAt.month,
        p.updatedAt.day,
      );
      final ago = base.difference(day).inDays;
      if (ago >= 0 && ago < 7) last7[6 - ago] += ms;
    }
    top = (titles.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(5)
        .toList();
  }

  int totalMs = 0;
  int episodes = 0;
  int films = 0;

  /// Milliseconds watched on each of the last seven days, today last.
  final List<int> last7 = List.filled(7, 0);
  late final List<MapEntry<String, int>> top;

  static String duration(int ms) {
    final m = ms ~/ 60000;
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    return h < 48 ? '$h h ${m % 60} min' : '${h ~/ 24} g ${h % 24} h';
  }
}

class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(libraryVersionProvider);
    final history = ref.read(servicesProvider).library.history;
    final s = WatchStats(history);
    final peak = s.last7.fold<int>(1, (a, b) => b > a ? b : a);
    const labels = ['lun', 'mar', 'mer', 'gio', 'ven', 'sab', 'dom'];
    final today = DateTime.now().weekday - 1;
    final theme = Theme.of(context);
    Widget tile(String label, String value, IconData icon) => Expanded(
      child: GlassSurface(
        radius: 16,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text(value, style: theme.textTheme.titleLarge),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
    return Scaffold(
      body: AetherBackdrop(
        child: SafeArea(
          bottom: false,
          child: history.isEmpty
              ? const EmptyState(
                  icon: Icons.insights_rounded,
                  title: 'Ancora nessuna statistica',
                  message:
                      'Guarda qualcosa e qui compariranno tempi e abitudini.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
                  children: [
                    Row(
                      children: [
                        GlassButton(
                          icon: Icons.arrow_back_ios_new_rounded,
                          tooltip: 'Indietro',
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Statistiche',
                          style: theme.textTheme.headlineMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        tile(
                          'Tempo guardato',
                          WatchStats.duration(s.totalMs),
                          Icons.schedule_rounded,
                        ),
                        const SizedBox(width: 10),
                        tile('Episodi', '${s.episodes}', Icons.tv_rounded),
                        const SizedBox(width: 10),
                        tile('Film', '${s.films}', Icons.movie_rounded),
                      ],
                    ),
                    const SizedBox(height: 16),
                    GlassSurface(
                      radius: 16,
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ultimi 7 giorni',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 110,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (var i = 0; i < 7; i++)
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Container(
                                          height: 6 + 74 * s.last7[i] / peak,
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.primary
                                                .withValues(
                                                  alpha: i == 6 ? 1 : .55,
                                                ),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          labels[(today - 6 + i) % 7],
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    GlassSurface(
                      radius: 16,
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'I più guardati',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          for (final t in s.top)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      t.key,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    WatchStats.duration(t.value),
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
