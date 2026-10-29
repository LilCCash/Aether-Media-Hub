import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../features/calendar/calendar_screen.dart';

/// Local notifications for new episodes: each upcoming episode of the series the viewer follows is scheduled for the moment it
/// comes out, with the device's own scheduler (nothing runs in the background, nothing is sent to any server).
class EpisodeNotifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Called with the payload (`aether://title/<type>/<id>`) when the viewer taps a notification.
  void Function(String payload)? onTap;

  Future<void> _init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      settings: const InitializationSettings(
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (r) {
        final p = r.payload;
        if (p != null) onTap?.call(p);
      },
    );
    _ready = true;
  }

  Future<bool> requestPermission() async {
    await _init();
    try {
      if (Platform.isIOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin
                >()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
      }
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >()
                ?.requestNotificationsPermission() ??
            false;
      }
    } on Object {
      return false;
    }
    return false;
  }

  Future<void> cancelAll() async {
    await _init();
    await _plugin.cancelAllPendingNotifications();
  }

  /// Replaces every scheduled notification with those of [entries] still to come (the system keeps at most 64 for an app).
  Future<int> schedule(List<CalendarEntry> entries, {int leadMin = 0}) async {
    await _init();
    await _plugin.cancelAllPendingNotifications();
    final now = DateTime.now();
    final upcoming = [
      for (final e in entries)
        if (e.when.subtract(Duration(minutes: leadMin)).isAfter(now)) e,
    ]..sort((a, b) => a.when.compareTo(b.when));
    var count = 0;
    for (final e in upcoming.take(50)) {
      final at = e.when.subtract(Duration(minutes: leadMin));
      await _plugin.zonedSchedule(
        id: e.video.id.hashCode & 0x7fffffff,
        title: e.meta.name,
        body: leadMin > 0
            ? '${e.video.label} esce tra poco'
            : '${e.video.label} è disponibile${e.video.title.isEmpty || e.video.title == e.video.label ? '' : ': ${e.video.title}'}',
        scheduledDate: tz.TZDateTime.fromMillisecondsSinceEpoch(
          tz.UTC,
          at.millisecondsSinceEpoch,
        ),
        notificationDetails: const NotificationDetails(
          iOS: DarwinNotificationDetails(),
          android: AndroidNotificationDetails(
            'episodes',
            'Nuovi episodi',
            channelDescription: 'Avvisa quando esce un nuovo episodio',
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload:
            'aether://title/${e.meta.type}/${Uri.encodeComponent(e.meta.id)}',
      );
      count++;
    }
    return count;
  }
}
