import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/widgets.dart';

import 'app.dart';
import 'data/database.dart';
import 'data/repository.dart';
import 'ui/catalog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase(driftDatabase(name: 'taskflow'));
  final repo = Repo(db);
  await repo.purgeOldTrash(); // items deleted more than 30 days ago
  runApp(TaskFlowApp(catalog: Catalog(repo)));
}
