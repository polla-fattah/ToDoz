import 'package:drift/drift.dart';

import '../core/backup.dart' show inboxId;

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
  DateTimeColumn get completedAt => dateTime().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isCollapsed => boolean().withDefault(const Constant(false))();

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

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Projects, Sections, Labels, Tasks, TaskLabels, Comments, Reminders, Completions, ProjectComments, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
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
        },
        beforeOpen: (details) async {
          await ensureInbox();
        },
      );

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
