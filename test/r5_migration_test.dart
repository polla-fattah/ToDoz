import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'rewind_util.dart';
import 'package:taskflow/data/activity_triggers.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/sync_triggers.dart';

/// An app that was installed at schema 3 or 4 must open at 6 with its data intact.
/// (The first R5 build crashed on a real phone because the triggers were made before the tables.)
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('taskflow_migrate_r5');
    file = File('${dir.path}/app.sqlite');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// Writes data with the current schema, then rewinds the file to how an older version left it.
  Future<String> makeOldFile({required int version}) async {
    final db = AppDatabase(NativeDatabase(file));
    final repo = Repo(db);
    await db.ensureInbox();
    final id = await repo.addTask(title: 'written by the old version', priority: 2, dueDate: '2026-10-20');
    final c = await repo.addComment(id, 'a comment');
    expect(c, isNotEmpty);
    for (final name in [...syncTriggerNames(), ...activityTriggerNames()]) {
      await db.customStatement('DROP TRIGGER IF EXISTS $name');
    }
    if (version < 6) await db.customStatement('DROP TABLE attachments');
    await dropVersion7(db);
    if (version < 5) await db.customStatement('DROP TABLE activity'); // version 5 already had the log
    if (version < 4) {
      await db.customStatement('DROP TABLE outbox');
      await db.customStatement('DROP TABLE field_clock');
      await db.customStatement('DROP TABLE sync_meta');
    }
    await db.customStatement('PRAGMA user_version = $version');
    await db.close();
    return id;
  }

  for (final from in [3, 4, 5, 6]) {
    test('schema $from opens at 7, keeps its tasks, and the new tables and triggers work', () async {
      final id = await makeOldFile(version: from);
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final repo = Repo(db);
      final task = (await repo.getTask(id))!;
      expect((task.title, task.priority, task.dueDate), ('written by the old version', 2, '2026-10-20'));
      expect((await repo.watchComments(id).first).single.body, 'a comment');

      final tables = {for (final r in await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'table'").get()) r.read<String>('name')};
      expect(tables, containsAll(['activity', 'attachments', 'outbox', 'field_clock', 'sync_meta']));
      final triggers = {for (final r in await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger'").get()) r.read<String>('name')};
      expect(triggers.containsAll({...syncTriggerNames(), ...activityTriggerNames()}), isTrue);

      // The activity log records new actions...
      await repo.updateTask(id, title: 'edited after the upgrade');
      expect((await db.select(db.activity).get()).map((e) => e.event), contains('edit'));
      // ...and a file can be attached, with its metadata queued for sync once sync is on.
      await db.metaSet('capture', '1');
      await repo.addAttachmentComment(id, fileName: 'a.txt', mimeType: 'text/plain', sizeBytes: 3, hash: 'a' * 64);
      final queued = {for (final r in await db.customSelect("SELECT DISTINCT tbl FROM outbox").get()) r.read<String>('tbl')};
      expect(queued, containsAll(['attachments', 'comments']));
    });
  }

  test('a brand new install has everything at once', () async {
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final repo = Repo(db);
    await db.ensureInbox();
    final id = await repo.addTask(title: 'fresh');
    expect((await db.select(db.activity).get()).single.event, 'add');
    expect(id, isNotEmpty);
  });
}
