import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'data/database.dart';
import 'data/repository.dart';
import 'platform/attachment_store.dart';
import 'platform/geofence_service.dart';
import 'platform/auto_backup.dart';
import 'platform/notification_service.dart';
import 'platform/today_widget.dart';
import 'security/app_lock.dart';
import 'security/secret_store.dart';
import 'sync/background_sync.dart';
import 'sync/blob_sync.dart';
import 'sync/share_notifier.dart';
import 'sync/secure_token_store.dart';
import 'sync/sync_service.dart';
import 'ui/catalog.dart';
import 'ui/intent_router.dart';
import 'ui/task_detail.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase(driftDatabase(name: 'taskflow'));
  final repo = Repo(db);
  await repo.purgeOldTrash(); // items deleted more than 30 days ago

  final navigatorKey = GlobalKey<NavigatorState>();
  void openTask(String id) =>
      navigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => TaskDetailPage(taskId: id)));

  final notifications = NotificationService(repo, onOpenTask: openTask);
  await notifications.init();
  final docs = await getApplicationDocumentsDirectory();
  final attachments = AttachmentStore(repo, Directory(p.join(docs.path, 'TaskFlow', 'attachments')));
  final sync = SyncService(
    repo,
    SecureTokenStore(),
    blobs: BlobSync(repo, attachments),
    notifier: notifications.supported ? ShareNotifier(repo, notifications) : null,
    scheduler: WorkmanagerScheduler.supported ? WorkmanagerScheduler() : null,
  );
  ForegroundMark(repo).start(); // tells the job that runs while the app is closed that the app is open
  await sync.init();
  final lock = AppLock(SecureSecretStore(), biometric: DeviceBiometric());
  await lock.init();
  final backup = AutoBackup(repo, defaultFolder: () async => Directory(p.join((await getApplicationDocumentsDirectory()).path, 'TaskFlow', 'backups')))..start();
  final catalog = Catalog(repo)
    ..notifications = notifications
    ..sync = sync
    ..lock = lock
    ..autoBackup = backup
    ..attachments = attachments;
  if (notifications.supported) NotificationSync(notifications, db);
  if (GeofenceService.supported) {
    catalog.geofence = GeofenceService(repo);
    GeofenceSync(catalog.geofence!);
  }
  if (TodayWidget.supported) {
    await HomeWidget.registerInteractivityCallback(widgetBackgroundCallback);
    TodayWidget(repo).start();
  }

  runApp(TaskFlowApp(catalog: catalog, navigatorKey: navigatorKey));
  IntentRouter(catalog, navigatorKey).start();

  // The app may have been started by tapping a reminder.
  final launchTask = await notifications.launchTaskId();
  if (launchTask != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => openTask(launchTask));
  }
}
