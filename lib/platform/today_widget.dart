import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';
import 'package:taskflow_core/date_parser.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../sync/background_sync.dart';
import '../sync/secure_token_store.dart';
import 'notification_service.dart';

const _widgetProvider = 'com.taskflow.taskflow.TodayWidgetProvider';
const _dataKey = 'today_json';

/// How many tasks fit in the widget.
const widgetRows = 6;

/// What the Android home-screen widget shows, as a small JSON-able map: the date, how many tasks are due,
/// and the first few. Pure, so it can be tested without a phone.
Map<String, Object?> buildWidgetPayload(List<Task> tasks, {required DateTime now, required bool use24h, int rows = widgetRows}) {
  final today = formatDate(dateOnly(now));
  const weekdays = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String? label(Task t) {
    final due = t.dueDate;
    if (due != null && due.compareTo(today) < 0) return 'Overdue';
    final m = t.dueTime == null ? null : parseClock(t.dueTime!);
    return m == null ? null : formatTime(m, use24h: use24h);
  }

  return {
    'date': '${weekdays[now.weekday]} ${now.day} ${months[now.month]}',
    'total': tasks.length,
    'items': [
      for (final t in tasks.take(rows)) {'id': t.id, 'title': t.title, 'time': label(t), 'p': t.priority, 'late': (t.dueDate ?? today).compareTo(today) < 0},
    ],
    'more': tasks.length > rows ? tasks.length - rows : 0,
  };
}

/// Keeps the Android home-screen widget showing today's tasks. The native widget only draws what is
/// written here; tapping a task opens it, and tapping its circle completes it (see [widgetBackgroundCallback]).
class TodayWidget with WidgetsBindingObserver {
  TodayWidget(this.repo);

  final Repo repo;
  StreamSubscription<List<Task>>? _sub;
  String? _subscribedFor;
  Timer? _later;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Starts following the data (in the app).
  void start() {
    if (!supported) return;
    WidgetsBinding.instance.addObserver(this);
    _follow();
  }

  /// Re-subscribes when the day has changed, so the widget never lags a day behind.
  void _follow() {
    final today = formatDate(dateOnly(repo.now));
    if (_subscribedFor == today) return;
    _subscribedFor = today;
    _sub?.cancel();
    _sub = repo.watchToday(today).listen((_) {
      _later?.cancel();
      _later = Timer(const Duration(milliseconds: 700), () => unawaited(push()));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || state == AppLifecycleState.paused) {
      _follow();
      unawaited(push());
    }
  }

  /// Writes today's tasks for the widget and asks Android to redraw it. Safe to call from a background isolate.
  Future<void> push() async {
    if (!supported) return;
    try {
      final tasks = await repo.watchToday(formatDate(dateOnly(repo.now))).first;
      final use24h = (await repo.getSetting('use24h')) != 'false';
      await HomeWidget.saveWidgetData<String>(_dataKey, jsonEncode(buildWidgetPayload(tasks, now: repo.now, use24h: use24h)));
      await HomeWidget.updateWidget(qualifiedAndroidName: _widgetProvider);
    } catch (_) {
      // No widget on the home screen, or the plugin is not there: nothing to update.
    }
  }

  void dispose() {
    _later?.cancel();
    _sub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

/// Runs in a background isolate when a task's circle is tapped in the widget (taskflow://complete?id=...).
/// Opens its own database connection, completes the task with the same rules as the app, syncs, then redraws
/// the widget and rebuilds the reminders (a completed task must not remind).
@pragma('vm:entry-point')
Future<void> widgetBackgroundCallback(Uri? uri) async {
  if (uri == null || uri.host != 'complete') return;
  final id = uri.queryParameters['id'];
  if (id == null || id.isEmpty) return;
  final db = AppDatabase(driftDatabase(name: 'taskflow'));
  try {
    final repo = Repo(db);
    try {
      await repo.completeTask(id);
    } on RuleException {
      // For example a read-only member's task: leave it, the widget redraws below.
    }
    try {
      // Send the completion now (and bring in what others changed) instead of waiting for the next turn of the job.
      await runBackgroundSync(repo: repo, tokens: SecureTokenStore());
    } catch (_) {
      // Offline: it goes with the next sync.
    }
    await TodayWidget(repo).push();
    final notifications = NotificationService(repo);
    await notifications.init();
    await notifications.sync();
  } finally {
    await db.close();
  }
}
