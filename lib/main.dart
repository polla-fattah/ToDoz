import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database.dart';
import 'data/repository.dart';
import 'platform/notification_service.dart';
import 'ui/catalog.dart';
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
  final catalog = Catalog(repo)..notifications = notifications;
  if (notifications.supported) NotificationSync(notifications, db);

  runApp(TaskFlowApp(catalog: catalog, navigatorKey: navigatorKey));

  // The app may have been started by tapping a reminder.
  final launchTask = await notifications.launchTaskId();
  if (launchTask != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => openTask(launchTask));
  }
}
