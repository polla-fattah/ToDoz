import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:taskflow_core/backup.dart' show inboxId;
import 'package:taskflow_core/sharing.dart' show ShareInfo;

import '../sync/sync_triggers.dart';
import 'activity_triggers.dart';

part 'database.g.dart';

/// Every table carries created/updated/deleted timestamps so R4 sync and the
/// 30-day trash (FR-T8, FR-P3) need no schema change.
mixin Stamped on Table {
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
}

class Projects extends Table with Stamped {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get color => integer()();
  TextColumn get parentId => text().nullable()();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Layout, grouping and sorting for this project (JSON, see ViewOptions); null = defaults.
  TextColumn get viewOptions => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Sections extends Table with Stamped {
  TextColumn get id => text()();
  TextColumn get projectId => text()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isCollapsed => boolean().withDefault(const Constant(false))();
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Labels extends Table with Stamped {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get color => integer()();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'tasks_project', columns: {#projectId})
@TableIndex(name: 'tasks_parent', columns: {#parentId})
@TableIndex(name: 'tasks_due', columns: {#dueDate})
class Tasks extends Table with Stamped {
  TextColumn get id => text()();
  TextColumn get title => text().withLength(min: 1, max: 500)();
  TextColumn get description => text().withDefault(const Constant(''))();
  TextColumn get projectId => text()();
  TextColumn get sectionId => text().nullable()();
  TextColumn get parentId => text().nullable()();

  /// 1 (urgent) to 4 (none), as Todoist.
  IntColumn get priority => integer().withDefault(const Constant(4))();

  /// `YYYY-MM-DD`.
  TextColumn get dueDate => text().nullable()();

  /// `HH:MM` local time, or null for "any time that day" (FR-D1).
  TextColumn get dueTime => text().nullable()();

  /// The repeat phrase as typed, e.g. `every other fri at 8pm` (FR-R1..R10).
  TextColumn get recurrence => text().nullable()();

  /// A separate hard date, `YYYY-MM-DD` (FR-D2).
  TextColumn get deadline => text().nullable()();

  /// Set by "snooze": the reminder fires again at this moment (FR-N3).
  DateTimeColumn get snoozedUntil => dateTime().nullable()();

  /// How long the task takes, in minutes (FR-D3). Days are stored as 1440 each.
  IntColumn get durationMinutes => integer().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isCollapsed => boolean().withDefault(const Constant(false))();

  /// In a shared project: who the task is assigned to and who assigned it (user ids). Null = nobody.
  TextColumn get assigneeId => text().nullable()();
  TextColumn get assignedBy => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TaskLabels extends Table {
  TextColumn get taskId => text()();
  TextColumn get labelId => text()();

  @override
  Set<Column> get primaryKey => {taskId, labelId};
}

@TableIndex(name: 'comments_task', columns: {#taskId})
class Comments extends Table with Stamped {
  TextColumn get id => text()();
  TextColumn get taskId => text()();
  TextColumn get body => text()();

  /// Who wrote it (a user id), set when the person is signed in to a server; shown in shared projects.
  TextColumn get authorId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A saved query shown as its own view (FR-F1).
class Filters extends Table with Stamped {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get query => text()();
  IntColumn get color => integer()();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get viewOptions => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// An extra reminder on a task (FR-N2): `14:00` or `30m` (minutes before).
@TableIndex(name: 'reminders_task', columns: {#taskId})
class Reminders extends Table with Stamped {
  TextColumn get id => text()();
  TextColumn get taskId => text()();
  TextColumn get spec => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One row per completion, so a recurring task keeps its history (FR-R7)
/// and Karma and charts can be built later from exact times.
@TableIndex(name: 'completions_at', columns: {#completedAt})
class Completions extends Table {
  TextColumn get id => text()();
  TextColumn get taskId => text()();
  DateTimeColumn get completedAt => dateTime()();
  TextColumn get dueDate => text().nullable()();
  TextColumn get dueTime => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Notes about a whole project, separate from task comments (FR-P10).
@TableIndex(name: 'project_comments_project', columns: {#projectId})
class ProjectComments extends Table with Stamped {
  TextColumn get id => text()();
  TextColumn get projectId => text()();
  TextColumn get body => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Sync bookkeeping that never leaves the device: this device's id, whether
/// change capture is on, the clock floor and the server cursor.
class SyncMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Edits waiting to be sent, one row per changed field. Written by SQL
/// triggers (see sync_triggers.dart); read and cleared by the sync engine.
class Outbox extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get tbl => text()();
  TextColumn get rowId => text()();
  TextColumn get col => text()();

  /// The new value as JSON.
  TextColumn get value => text()();
  TextColumn get hlc => text().withDefault(const Constant(''))();
}

/// The clock of the latest change known for each field, from this device or
/// the server. A change from the server is applied only if its clock is larger.
class FieldClock extends Table {
  TextColumn get tbl => text()();
  TextColumn get rowId => text()();
  TextColumn get col => text()();
  TextColumn get hlc => text()();

  @override
  Set<Column> get primaryKey => {tbl, rowId, col};
}

/// An emoji reaction to a comment in a shared project (FR-W3). The row id is
/// `commentId:userId:emoji`, so reacting twice with the same emoji is one row
/// and taking it back deletes it.
@TableIndex(name: 'reactions_comment', columns: {#commentId})
class Reactions extends Table {
  TextColumn get id => text()();
  TextColumn get commentId => text()();
  TextColumn get userId => text()();
  TextColumn get emoji => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The projects this person shares with others and their role in each. It is
/// told to the app by the server at every sync and never synced as data.
@DataClassName('SharedProjectRow')
class SharedProjects extends Table {
  TextColumn get projectId => text()();
  TextColumn get ownerId => text()();

  /// owner, admin, member or viewer.
  TextColumn get myRole => text()();

  /// The members as JSON (id, name, role).
  TextColumn get membersJson => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {projectId};
}

/// A file attached to a comment (FR-C2). The bytes live in a content-addressed
/// file named by [hash]; this row is the metadata, and it syncs.
@DataClassName('Attachment')
@TableIndex(name: 'attachments_comment', columns: {#commentId})
class Attachments extends Table with Stamped {
  TextColumn get id => text()();
  TextColumn get commentId => text()();
  TextColumn get fileName => text()();
  TextColumn get mimeType => text().withDefault(const Constant('application/octet-stream'))();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();

  /// SHA-256 of the bytes, lower-case hex.
  TextColumn get hash => text()();

  /// This device has sent the bytes to the server. Not synced: each device knows for itself.
  BoolColumn get uploaded => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// What was done to tasks and projects, newest last (FR-K6). Written by SQL
/// triggers (see activity_triggers.dart) and synced like any other table.
@DataClassName('ActivityEntry')
@TableIndex(name: 'activity_at', columns: {#atMs})
class Activity extends Table {
  @override
  String get tableName => 'activity';

  TextColumn get id => text()();

  /// add, edit, move, complete, uncomplete, delete or restore.
  TextColumn get event => text()();

  /// task or project.
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get projectId => text().nullable()();

  /// The task or project name at the time.
  TextColumn get title => text().withDefault(const Constant(''))();

  /// For edit and move: which field, and its value before and after.
  TextColumn get field => text().nullable()();
  TextColumn get oldValue => text().nullable()();
  TextColumn get newValue => text().nullable()();
  IntColumn get atMs => integer()();
  TextColumn get device => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Projects, Sections, Labels, Tasks, TaskLabels, Comments, Reminders, Completions, ProjectComments, Filters, Activity, Attachments, Reactions, SharedProjects, Settings, SyncMeta, Outbox, FieldClock])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await createSyncTriggers();
          await createActivityTriggers();
          await ensureSyncMeta();
          await ensureInbox();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // R2: times, repeats, deadlines, snooze, reminders, completion history, project notes.
            await m.addColumn(tasks, tasks.dueTime);
            await m.addColumn(tasks, tasks.recurrence);
            await m.addColumn(tasks, tasks.deadline);
            await m.addColumn(tasks, tasks.snoozedUntil);
            await m.createTable(reminders);
            await m.createTable(completions);
            await m.createTable(projectComments);
          }
          if (from < 3) {
            // R3: durations, saved filters, per-project view options.
            await m.addColumn(tasks, tasks.durationMinutes);
            await m.addColumn(projects, projects.viewOptions);
            await m.createTable(filters);
          }
          if (from < 4) {
            // R4: sync bookkeeping and the triggers that record edits.
            await m.createTable(syncMeta);
            await m.createTable(outbox);
            await m.createTable(fieldClock);
          }
          if (from < 5) {
            // R5: the activity log.
            await m.createTable(activity);
          }
          if (from < 6) {
            // R5: attachments on comments.
            await m.createTable(attachments);
          }
          if (from < 7) {
            // R6: assignees, comment authors, reactions, and the list of shared projects.
            await m.addColumn(tasks, tasks.assigneeId);
            await m.addColumn(tasks, tasks.assignedBy);
            await m.addColumn(comments, comments.authorId);
            await m.createTable(reactions);
            await m.createTable(sharedProjects);
          }
          if (from < 7) {
            // The triggers refer to every table above, so they are made last, once all exist.
            await createActivityTriggers();
            await createSyncTriggers();
          }
        },
        beforeOpen: (details) async {
          await ensureSyncMeta();
          await ensureInbox();
        },
      );

  // --- sync bookkeeping ---------------------------------------------------------------

  Future<void> createSyncTriggers() async {
    for (final name in syncTriggerNames()) {
      await customStatement('DROP TRIGGER IF EXISTS $name');
    }
    for (final sql in syncTriggerStatements()) {
      await customStatement(sql);
    }
  }

  Future<void> createActivityTriggers() async {
    for (final name in activityTriggerNames()) {
      await customStatement('DROP TRIGGER IF EXISTS $name');
    }
    for (final sql in activityTriggerStatements()) {
      await customStatement(sql);
    }
  }

  /// Replaces the stored list of shared projects with what the server just said.
  Future<void> saveShares(List<ShareInfo> infos) => transaction(() async {
        final keep = {for (final i in infos) i.projectId};
        await (delete(sharedProjects)..where((x) => x.projectId.isIn(keep).not())).go();
        for (final i in infos) {
          await into(sharedProjects).insertOnConflictUpdate(SharedProjectsCompanion.insert(
            projectId: i.projectId,
            ownerId: i.ownerId,
            myRole: i.myRole.name,
            membersJson: Value(jsonEncode([for (final m in i.members) m.toJson()])),
          ));
        }
      });

  /// Makes sure this device has an id and the sync switches exist.
  Future<void> ensureSyncMeta() async {
    final rnd = Random.secure();
    final id = List.generate(16, (_) => rnd.nextInt(16).toRadixString(16)).join();
    for (final e in {'device': id, 'capture': '0', 'hlc_floor': '0', 'cursor': '0', 'log': '1'}.entries) {
      await customStatement('INSERT OR IGNORE INTO sync_meta(key, value) VALUES (?, ?)', [e.key, e.value]);
    }
  }

  Future<String> metaGet(String key) async {
    final r = await customSelect('SELECT value FROM sync_meta WHERE key = ?', variables: [Variable<String>(key)]).get();
    return r.isEmpty ? '' : r.first.read<String>('value');
  }

  Future<void> metaSet(String key, String value) =>
      customStatement('INSERT OR REPLACE INTO sync_meta(key, value) VALUES (?, ?)', [key, value]);

  /// Runs [action] with the activity log off (restoring a backup, applying
  /// another device's edits): those changes are not new actions by this person.
  Future<T> withoutLog<T>(Future<T> Function() action) async {
    final was = await metaGet('log');
    if (was == '0') return action();
    await metaSet('log', '0');
    try {
      return await action();
    } finally {
      await metaSet('log', '1');
    }
  }

  /// Runs [action] with change capture off, so what it writes is not queued
  /// for sending (applying data from the server, local housekeeping).
  Future<T> withoutCapture<T>(Future<T> Function() action) async {
    final was = await metaGet('capture');
    if (was != '1') return action();
    await metaSet('capture', '0');
    try {
      return await action();
    } finally {
      await metaSet('capture', '1');
    }
  }

  /// The Inbox is permanent (FR-P4): recreate it if it is ever missing.
  Future<void> ensureInbox() async {
    final existing = await (select(projects)..where((p) => p.id.equals(inboxId))).getSingleOrNull();
    final now = DateTime.now();
    if (existing == null) {
      await into(projects).insert(ProjectsCompanion.insert(
        id: inboxId,
        name: 'Inbox',
        color: 0xFF678AC7,
        createdAt: now,
        updatedAt: now,
      ));
    } else if (existing.deletedAt != null) {
      await (update(projects)..where((p) => p.id.equals(inboxId)))
          .write(const ProjectsCompanion(deletedAt: Value(null)));
    }
  }
}
