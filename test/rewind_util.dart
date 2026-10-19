import 'package:taskflow/data/database.dart';

/// Undoes what schema version 7 added, so a test can reshape a current database
/// to look like an older one. Triggers must be dropped first.
Future<void> dropVersion7(AppDatabase db) async {
  for (final c in ['assignee_id', 'assigned_by']) {
    await db.customStatement('ALTER TABLE tasks DROP COLUMN $c');
  }
  await db.customStatement('ALTER TABLE comments DROP COLUMN author_id');
  await db.customStatement('DROP TABLE reactions');
  await db.customStatement('DROP TABLE shared_projects');
}
