import 'package:taskflow/data/database.dart';

/// Undoes what schema version 8 added (places and location reminders), so a test can reshape a current database
/// to look like an older one. Triggers must be dropped first.
Future<void> dropVersion8(AppDatabase db) async {
  await db.customStatement('DROP TABLE location_reminders');
  await db.customStatement('DROP TABLE places');
}

/// Undoes what schema versions 7 and 8 added, so a test can reshape a current database
/// to look like an older one. Triggers must be dropped first.
Future<void> dropVersion7(AppDatabase db) async {
  await dropVersion8(db);
  for (final c in ['assignee_id', 'assigned_by']) {
    await db.customStatement('ALTER TABLE tasks DROP COLUMN $c');
  }
  await db.customStatement('ALTER TABLE comments DROP COLUMN author_id');
  await db.customStatement('DROP TABLE reactions');
  await db.customStatement('DROP TABLE shared_projects');
}
