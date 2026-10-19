import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../platform/attachment_store.dart';
import '../platform/notification_service.dart';
import '../platform/today_widget.dart';
import 'blob_sync.dart';
import 'secure_token_store.dart';
import 'share_notifier.dart';
import 'sync_service.dart';

/// How a run of the sync that happens while the app is closed ended.
enum BackgroundSyncOutcome { skippedAppOpen, notPaired, signedOut, switchedOff, synced, failed }

/// One sync pass without the app's screens, for the job Android runs every so often (FR-S2, FR-W3):
/// pull what other devices and people changed, send what is waiting, tell the person about comments and
/// assignments, and set the reminders from the new data. Everything it needs is passed in so it can be tested.
///
/// It does nothing while the app itself is open: the app is syncing already, and two connections writing to the
/// same database file at once is what to avoid.
Future<BackgroundSyncOutcome> runBackgroundSync({
  required Repo repo,
  required TokenStore tokens,
  ShareAlerts? alerts,
  BlobSync? blobs,
  NotificationService? reminders,
  http.Client? client,
  Duration appOpenWithin = const Duration(minutes: 2),
}) async {
  if (await ForegroundMark.isActive(repo, within: appOpenWithin)) return BackgroundSyncOutcome.skippedAppOpen;
  final service = SyncService(repo, tokens, blobs: blobs, notifier: alerts == null ? null : ShareNotifier(repo, alerts), client: client);
  try {
    await service.init(background: false);
    if (!service.paired) return BackgroundSyncOutcome.notPaired;
    if (service.state == SyncState.signedOut) return BackgroundSyncOutcome.signedOut;
    if (!service.backgroundSync) return BackgroundSyncOutcome.switchedOff;
    await service.syncNow();
    if (service.state != SyncState.idle) return BackgroundSyncOutcome.failed;
    try {
      await reminders?.sync(); // other devices may have added or changed reminders
    } catch (_) {
      // Reminders are rebuilt the next time the app opens.
    }
    await repo.setSetting(lastRunKey, '${repo.now.millisecondsSinceEpoch}');
    return BackgroundSyncOutcome.synced;
  } finally {
    service.dispose();
  }
}

/// When the sync that runs while the app is closed last finished (milliseconds since 1970).
const lastRunKey = 'sync.background.last';

/// Tells the job that runs while the app is closed whether the app is open: it writes the time into the
/// database every so often while the app is on screen, and zero when it goes away.
class ForegroundMark with WidgetsBindingObserver {
  ForegroundMark(this.repo, {this.every = const Duration(seconds: 45)});

  final Repo repo;
  final Duration every;
  Timer? _timer;

  static const key = 'app.foreground.at';

  void start() {
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) _beat();
  }

  void _beat() {
    _timer?.cancel();
    unawaited(repo.setSetting(key, '${repo.now.millisecondsSinceEpoch}'));
    _timer = Timer.periodic(every, (_) => unawaited(repo.setSetting(key, '${repo.now.millisecondsSinceEpoch}')));
  }

  void _gone() {
    _timer?.cancel();
    _timer = null;
    unawaited(repo.setSetting(key, '0'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _beat();
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        _gone();
      case AppLifecycleState.inactive:
        break; // the notification shade or a permission dialog: the app is still there
    }
  }

  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Whether the app was on screen within [within] of now.
  static Future<bool> isActive(Repo repo, {Duration within = const Duration(minutes: 2)}) async {
    final at = int.tryParse(await repo.getSetting(key) ?? '') ?? 0;
    if (at == 0) return false;
    return repo.now.difference(DateTime.fromMillisecondsSinceEpoch(at)) < within;
  }
}

const _uniqueName = 'taskflow.sync';
const _taskName = 'sync';

/// Android WorkManager: runs [backgroundSyncDispatcher] about every 15 minutes (the shortest Android allows)
/// when there is a network connection, also after a restart of the phone.
class WorkmanagerScheduler implements BackgroundScheduler {
  static bool get supported => !kIsWeb && Platform.isAndroid;

  static bool _initialised = false;

  static Future<void> _ensureInit() async {
    if (_initialised) return;
    await Workmanager().initialize(backgroundSyncDispatcher);
    _initialised = true;
  }

  @override
  Future<void> enable() async {
    if (!supported) return;
    await _ensureInit();
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      _taskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  @override
  Future<void> disable() async {
    if (!supported) return;
    await _ensureInit();
    await Workmanager().cancelByUniqueName(_uniqueName);
  }
}

/// The entry point Android starts, in a fresh isolate, when the job is due. It opens its own database
/// connection (like the notification buttons do), syncs once and closes it again.
@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, input) async {
    DartPluginRegistrant.ensureInitialized();
    final db = AppDatabase(driftDatabase(name: 'taskflow'));
    try {
      final repo = Repo(db);
      final notifications = NotificationService(repo);
      await notifications.init();
      final docs = await getApplicationDocumentsDirectory();
      final attachments = AttachmentStore(repo, Directory(p.join(docs.path, 'TaskFlow', 'attachments')));
      await runBackgroundSync(
        repo: repo,
        tokens: SecureTokenStore(),
        alerts: notifications,
        blobs: BlobSync(repo, attachments),
        reminders: notifications,
      );
      await TodayWidget(repo).push(); // other devices may have changed today's tasks
      return true; // a failed pass is tried again at the next turn, not at once
    } catch (_) {
      return true;
    } finally {
      await db.close();
    }
  });
}
