import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quick_actions/quick_actions.dart';

import '../data/prefs_ext.dart';
import '../features/calendar/calendar_screen.dart';
import 'notifier.dart';
import 'providers.dart';
import 'router.dart';

final notifierProvider = Provider<EpisodeNotifier>((ref) => EpisodeNotifier());

/// Where an `aether://` link or a notification payload leads (`null` for an address that is not ours to handle).
String? locationForLink(Uri u) {
  if (u.scheme != 'aether') return null;
  switch (u.host) {
    case 'title':
      final seg = u.pathSegments;
      return seg.length >= 2
          ? '/title/${Uri.encodeComponent(seg[0])}/${Uri.encodeComponent(seg[1])}'
          : '/home';
    case 'calendar':
      return '/calendar';
    case 'stats':
      return '/stats';
    case 'search':
      return '/search';
    case 'library':
      return '/library';
    case 'downloads':
      return '/downloads';
  }
  return null;
}

/// Quick actions on the icon, new-episode notifications: started once with the app.
final appHooksProvider = Provider<void>((ref) {
  // Phones only: the desktop (and the widget tests) have neither quick actions nor local notifications.
  if (!Platform.isIOS && !Platform.isAndroid) return;
  final router = ref.read(routerProvider);
  final notifier = ref.read(notifierProvider);
  notifier.onTap = (payload) {
    final loc = locationForLink(Uri.parse(payload));
    if (loc != null) router.push(loc);
  };

  Future<void> reschedule() async {
    final s = ref.read(settingsProvider);
    if (!s.notifyNewEpisodes) {
      await notifier.cancelAll();
      return;
    }
    try {
      final entries = await ref.read(calendarProvider.future);
      await notifier.schedule(entries, leadMin: s.notifyLeadMin);
    } on Object {
      // Offline or the catalogue is down: the notifications already scheduled stay.
    }
  }

  const quick = QuickActions();
  unawaited(
    quick
        .initialize((type) {
          switch (type) {
            case 'resume':
              final cw = ref.read(servicesProvider).library.continueWatching;
              router.push(
                cw.isEmpty
                    ? '/library'
                    : '/title/${Uri.encodeComponent(cw.first.type)}/${Uri.encodeComponent(cw.first.metaId)}',
              );
            case 'search':
              router.push('/search');
            case 'calendar':
              router.push('/calendar');
          }
        })
        .then(
          (_) => quick.setShortcutItems(const [
            ShortcutItem(
              type: 'resume',
              localizedTitle: 'Riprendi',
              icon: 'play',
            ),
            ShortcutItem(
              type: 'search',
              localizedTitle: 'Cerca',
              icon: 'search',
            ),
            ShortcutItem(
              type: 'calendar',
              localizedTitle: 'Calendario',
              icon: 'date',
            ),
          ]),
        ),
  );

  // Re-plan when the switch or the lead time changes, and a few seconds after start (the library is loaded by then).
  ref.listen(
    settingsProvider.select(
      (s) => (
        s.notifyNewEpisodes,
        s.notifyLeadMin,
        s.notifyWatchlist,
        s.calendarDays,
      ),
    ),
    (prev, next) {
      if (prev != next) unawaited(reschedule());
    },
  );
  Timer(const Duration(seconds: 6), () => unawaited(reschedule()));
});
