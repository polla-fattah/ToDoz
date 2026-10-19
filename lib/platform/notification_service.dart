import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/reminder.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../sync/share_notifier.dart';
import '../ui/notification_controls.dart';

const _remindersChannel = 'reminders';
const _digestChannel = 'digest';
const _sharedChannel = 'shared';
const _digestId = 1; // below every task reminder id (those are >= 2)
const _maxScheduled = 48; // Android keeps a limited number of alarms; schedule a rolling window

/// Schedules local notifications for task reminders and the daily digest
/// (FR-N1 to FR-N8). Android only for now; on other platforms every call does
/// nothing.
///
/// Everything it needs comes from the database, so the same code runs in the
/// app and in the background isolate that handles the Complete and Snooze
/// buttons. [upcomingFires] (pure, unit-tested) decides *what* fires and
/// when; this class only hands it to the operating system.
class NotificationService implements NotificationControls, ShareAlerts {
  NotificationService(this.repo, {this.onOpenTask});

  final Repo repo;

  /// Called in the app when a notification is tapped.
  final void Function(String taskId)? onOpenTask;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  @override
  bool get supported => !kIsWeb && Platform.isAndroid;

  Future<void> init() async {
    if (!supported || _ready) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Keep UTC if the zone cannot be read; reminders then fire in UTC.
    }
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _remindersChannel,
      'Reminders',
      description: 'Task reminders',
      importance: Importance.high,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _digestChannel,
      'Daily digest',
      description: 'A morning summary of today\'s tasks',
      importance: Importance.defaultImportance,
    ));
    _ready = true;
  }

  /// If the app was started by tapping a notification, the task it was for.
  Future<String?> launchTaskId() async {
    if (!supported) return null;
    final d = await _plugin.getNotificationAppLaunchDetails();
    return (d?.didNotificationLaunchApp ?? false) ? d?.notificationResponse?.payload : null;
  }

  /// Asks for the notification permission (Android 13+) and, if needed, the
  /// exact-alarm permission (Android 12+, opens a system settings page).
  /// Returns whether reminders can fire on time.
  @override
  Future<bool> requestPermissions() async {
    if (!supported) return false;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    final notifications = await android.requestNotificationsPermission() ?? true;
    var exact = await android.canScheduleExactNotifications() ?? true;
    if (!exact) {
      await android.requestExactAlarmsPermission();
      exact = await android.canScheduleExactNotifications() ?? false;
    }
    return notifications && exact;
  }

  @override
  Future<({bool notifications, bool exact})> permissionStatus() async {
    if (!supported) return (notifications: false, exact: false);
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return (
      notifications: await android?.areNotificationsEnabled() ?? false,
      exact: await android?.canScheduleExactNotifications() ?? false,
    );
  }

  /// Rebuilds every scheduled notification from the database. Cheap enough to
  /// call after any change: it cancels what is pending and schedules the next
  /// [_maxScheduled] reminders plus the daily digest.
  Future<void> sync() async {
    if (!supported || !_ready) return;
    final now = repo.now;
    final autoRaw = await repo.getSetting('autoReminder');
    final lead = autoRaw == 'off' ? null : (int.tryParse(autoRaw ?? '') ?? 30);
    final fires = upcomingFires(await repo.reminderTasks(), now, autoLeadMinutes: lead, limit: _maxScheduled);

    await _plugin.cancelAllPendingNotifications();
    final exactOk = (await _plugin
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.canScheduleExactNotifications()) ??
        true;
    for (final f in fires) {
      await _plugin.zonedSchedule(
        id: f.notificationId + 2,
        title: f.title,
        body: f.spec.isRelative && f.spec.offsetMinutes == 0 && !f.automatic ? 'Snoozed reminder' : f.spec.describe(),
        scheduledDate: tz.TZDateTime.from(f.at, tz.local),
        notificationDetails: _reminderDetails(),
        androidScheduleMode: exactOk ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: f.taskId,
      );
    }
    await _scheduleDigest(now);
  }

  Future<void> _scheduleDigest(DateTime now) async {
    final raw = await repo.getSetting('digestTime');
    final minutes = (raw == null || raw == 'off') ? null : parseClock(raw);
    if (minutes == null) return;
    final today = formatDate(dateOnly(now));
    final due = await repo.watchToday(today).first;
    final body = due.isEmpty ? 'Nothing is due today.' : '${due.length} task${due.length == 1 ? '' : 's'} due today or overdue.';
    var at = tz.TZDateTime(tz.local, now.year, now.month, now.day, minutes ~/ 60, minutes % 60);
    if (!at.isAfter(tz.TZDateTime.from(now, tz.local))) at = at.add(const Duration(days: 1));
    await _plugin.zonedSchedule(
      id: _digestId,
      title: 'Your day in NoteDo',
      body: body,
      scheduledDate: at,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(_digestChannel, 'Daily digest', importance: Importance.defaultImportance),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  /// An immediate notification about something other people did in a shared project (FR-W3).
  @override
  Future<void> show({required int id, required String title, required String body, String? taskId}) async {
    if (!_ready && !supported) return;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _sharedChannel,
          'Shared projects',
          channelDescription: 'Comments and assignments from people you share projects with',
          importance: Importance.defaultImportance,
        ),
      ),
      payload: taskId,
    );
  }

  NotificationDetails _reminderDetails() => const NotificationDetails(
        android: AndroidNotificationDetails(
          _remindersChannel,
          'Reminders',
          channelDescription: 'Task reminders',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          actions: [
            AndroidNotificationAction('complete', 'Complete', cancelNotification: true),
            AndroidNotificationAction('snooze10', 'Snooze 10 min', cancelNotification: true),
          ],
        ),
      );

  void _onResponse(NotificationResponse r) {
    final id = r.payload;
    if (id != null && (r.actionId == null || r.actionId!.isEmpty)) onOpenTask?.call(id);
  }
}

/// Runs in a background isolate when the Complete or Snooze button is
/// pressed with the app closed. It opens its own database connection, applies
/// the action through the same [Repo] rules as the app, and reschedules.
@pragma('vm:entry-point')
Future<void> notificationBackgroundHandler(NotificationResponse r) async {
  DartPluginRegistrant.ensureInitialized();
  final taskId = r.payload;
  if (taskId == null) return;
  final db = AppDatabase(driftDatabase(name: 'taskflow'));
  try {
    final repo = Repo(db);
    switch (r.actionId) {
      case 'complete':
        await repo.completeTask(taskId);
      case 'snooze10':
        await repo.snoozeTask(taskId, repo.now.add(const Duration(minutes: 10)));
      default:
        return;
    }
    final service = NotificationService(repo);
    await service.init();
    await service.sync();
  } finally {
    await db.close();
  }
}

/// Keeps the scheduled notifications in step with the data: re-syncs a moment
/// after any task, reminder or reminder-setting change, and when the app
/// returns to the foreground (the background buttons change the database
/// from another isolate).
class NotificationSync with WidgetsBindingObserver {
  NotificationSync(this.service, this.db) {
    final repo = service.repo;
    _subs = [
      repo.watchReminderChanges().listen((_) => _later()),
      repo.watchSetting('autoReminder').listen((_) => _later()),
      repo.watchSetting('digestTime').listen((_) => _later()),
    ];
    WidgetsBinding.instance.addObserver(this);
    _later();
  }

  final NotificationService service;
  final AppDatabase db;
  late final List<StreamSubscription<Object?>> _subs;
  Timer? _timer;

  void _later() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () => service.sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Another isolate may have written to the file; make open screens re-read it.
      db.markTablesUpdated([db.tasks, db.reminders, db.completions]);
      _later();
    }
  }

  void dispose() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
  }
}
