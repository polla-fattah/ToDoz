import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/backup.dart';
import '../core/date_parser.dart';
import '../core/quick_add.dart';
import '../core/recurrence.dart';
import '../core/reminder.dart';
import 'database.dart';

const maxProjectDepth = 3; // FR-P2
const maxTaskDepth = 4; // FR-T2
const trashDays = 30; // FR-T8

/// Thrown for operations the rules forbid (too deep, cycle, duplicate name).
class RuleException implements Exception {
  RuleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What Quick Add found, resolved against the existing projects, sections and
/// labels. Unknown names are reported so the UI can offer to create them
/// (FR-Q5) instead of silently dropping them.
class QuickAddPlan {
  QuickAddPlan({
    required this.parsed,
    required this.projectId,
    required this.sectionId,
    required this.labelIds,
    this.unknownProject,
    this.unknownSection,
    this.unknownLabels = const [],
  });
  final QuickAddResult parsed;
  final String projectId;
  final String? sectionId;
  final List<String> labelIds;
  final String? unknownProject;
  final String? unknownSection;
  final List<String> unknownLabels;
  bool get hasUnknown =>
      unknownProject != null || unknownSection != null || unknownLabels.isNotEmpty;

  /// The task fields as the typed line describes them.
  TaskFields get fields => TaskFields(
        dueDate: parsed.due == null ? null : formatDate(parsed.due!),
        dueTime: parsed.dueTime == null ? null : formatTime(parsed.dueTime!),
        recurrence: parsed.recurrence?.text,
        deadline: parsed.deadline == null ? null : formatDate(parsed.deadline!),
        reminders: parsed.reminders,
        priority: parsed.priority ?? 4,
      );
}

/// The date, repeat, reminder and priority fields of a new task. The Quick
/// Add sheet starts from what the text says and applies the owner's own
/// choices on top before creating the task.
class TaskFields {
  const TaskFields({
    this.dueDate,
    this.dueTime,
    this.recurrence,
    this.deadline,
    this.reminders = const [],
    this.priority = 4,
  });
  final String? dueDate;
  final String? dueTime;
  final String? recurrence;
  final String? deadline;
  final List<ReminderSpec> reminders;
  final int priority;
}

/// What completing a task did, so the UI can offer an exact Undo.
class CompletionOutcome {
  const CompletionOutcome({
    required this.changedIds,
    this.rescheduledId,
    this.previousDueDate,
    this.previousDueTime,
    this.completionId,
    this.reopenedSubtaskIds = const [],
    this.nextDueDate,
  });

  /// Tasks marked completed (empty when a repeating task just moved on).
  final List<String> changedIds;

  /// Set when a repeating task moved to its next date instead of completing.
  final String? rescheduledId;
  final String? previousDueDate;
  final String? previousDueTime;
  final String? completionId;
  final List<String> reopenedSubtaskIds;
  final String? nextDueDate;

  bool get wasRescheduled => rescheduledId != null;
}

class Repo {
  Repo(this.db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final DateTime Function() _clock;
  static const _uuid = Uuid();

  String newId() => _uuid.v4();
  DateTime get now => _clock();

  // ===========================================================================
  // Streams for the UI
  // ===========================================================================

  SimpleSelectStatement<$TasksTable, Task> _openTasks() => db.select(db.tasks)
    ..where((t) => t.deletedAt.isNull() & t.completedAt.isNull());

  Stream<List<Task>> watchProjectTasks(String projectId) => (_openTasks()
        ..where((t) => t.projectId.equals(projectId))
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.createdAt)]))
      .watch();

  /// Overdue and due-today tasks (FR-V1).
  Stream<List<Task>> watchToday(String today) => (_openTasks()
        ..where((t) => t.dueDate.isNotNull() & t.dueDate.isSmallerOrEqualValue(today))
        ..orderBy([
          (t) => OrderingTerm.asc(t.dueDate),
          (t) => OrderingTerm(expression: t.dueTime, nulls: NullsOrder.last),
          (t) => OrderingTerm.asc(t.priority),
          (t) => OrderingTerm.asc(t.sortOrder),
        ]))
      .watch();

  /// Every open task that has a date, soonest first; the UI groups by day.
  Stream<List<Task>> watchScheduled() => (_openTasks()
        ..where((t) => t.dueDate.isNotNull())
        ..orderBy([
          (t) => OrderingTerm.asc(t.dueDate),
          (t) => OrderingTerm(expression: t.dueTime, nulls: NullsOrder.last),
          (t) => OrderingTerm.asc(t.priority),
          (t) => OrderingTerm.asc(t.sortOrder),
        ]))
      .watch();

  Stream<List<Task>> watchAllOpen() => (_openTasks()
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.createdAt)]))
      .watch();

  Stream<List<Task>> watchLabelTasks(String labelId) {
    final q = db.select(db.tasks).join([
      innerJoin(db.taskLabels, db.taskLabels.taskId.equalsExp(db.tasks.id)),
    ])
      ..where(db.taskLabels.labelId.equals(labelId) &
          db.tasks.deletedAt.isNull() &
          db.tasks.completedAt.isNull())
      ..orderBy([OrderingTerm.asc(db.tasks.sortOrder)]);
    return q.watch().map((rows) => rows.map((r) => r.readTable(db.tasks)).toList());
  }

  Stream<List<Task>> watchCompleted({String? projectId}) => (db.select(db.tasks)
        ..where((t) => t.deletedAt.isNull() & t.completedAt.isNotNull() &
            (projectId == null ? const Constant(true) : t.projectId.equals(projectId)))
        ..orderBy([(t) => OrderingTerm.desc(t.completedAt)]))
      .watch();

  Stream<List<Task>> watchTrashedTasks() => (db.select(db.tasks)
        ..where((t) => t.deletedAt.isNotNull())
        ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
      .watch();

  Stream<List<Project>> watchTrashedProjects() => (db.select(db.projects)
        ..where((p) => p.deletedAt.isNotNull())
        ..orderBy([(p) => OrderingTerm.desc(p.deletedAt)]))
      .watch();

  /// Direct sub-tasks, open and completed, in manual order.
  Stream<List<Task>> watchChildren(String parentId) => (db.select(db.tasks)
        ..where((t) => t.parentId.equals(parentId) & t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.createdAt)]))
      .watch();

  Stream<Task?> watchTask(String id) =>
      (db.select(db.tasks)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Stream<List<Project>> watchProjects({bool includeArchived = false}) => (db.select(db.projects)
        ..where((p) => p.deletedAt.isNull() & (includeArchived ? const Constant(true) : p.isArchived.equals(false)))
        ..orderBy([(p) => OrderingTerm.asc(p.sortOrder), (p) => OrderingTerm.asc(p.createdAt)]))
      .watch();

  Stream<List<Section>> watchSections(String projectId) => (db.select(db.sections)
        ..where((s) => s.projectId.equals(projectId) & s.deletedAt.isNull() & s.isArchived.equals(false))
        ..orderBy([(s) => OrderingTerm.asc(s.sortOrder)]))
      .watch();

  Stream<List<Section>> watchAllSections() => (db.select(db.sections)
        ..where((s) => s.deletedAt.isNull())
        ..orderBy([(s) => OrderingTerm.asc(s.sortOrder)]))
      .watch();

  Stream<List<Label>> watchLabels() => (db.select(db.labels)
        ..where((l) => l.deletedAt.isNull())
        ..orderBy([(l) => OrderingTerm.asc(l.sortOrder), (l) => OrderingTerm.asc(l.name)]))
      .watch();

  Stream<List<TaskLabel>> watchLabelLinks() => db.select(db.taskLabels).watch();

  /// (done, total) sub-task counts by parent id, for the "1/3" badge.
  Stream<Map<String, (int, int)>> watchSubtaskCounts() => db
      .customSelect(
        'SELECT parent_id, COUNT(*) AS total, '
        'SUM(CASE WHEN completed_at IS NOT NULL THEN 1 ELSE 0 END) AS done '
        'FROM tasks WHERE deleted_at IS NULL AND parent_id IS NOT NULL GROUP BY parent_id',
        readsFrom: {db.tasks},
      )
      .watch()
      .map((rows) => {
            for (final r in rows) r.read<String>('parent_id'): (r.read<int>('done'), r.read<int>('total')),
          });

  Stream<List<Comment>> watchComments(String taskId) => (db.select(db.comments)
        ..where((c) => c.taskId.equals(taskId) & c.deletedAt.isNull())
        ..orderBy([(c) => OrderingTerm.asc(c.createdAt)]))
      .watch();

  Stream<String?> watchSetting(String key) =>
      (db.select(db.settings)..where((s) => s.key.equals(key))).watchSingleOrNull().map((s) => s?.value);

  Future<String?> getSetting(String key) async =>
      (await (db.select(db.settings)..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setSetting(String key, String value) =>
      db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: key, value: value));

  // ===========================================================================
  // Tasks
  // ===========================================================================

  Future<Task?> getTask(String id) =>
      (db.select(db.tasks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<int> _nextTaskOrder(String projectId, String? parentId) async {
    final q = db.selectOnly(db.tasks)
      ..addColumns([db.tasks.sortOrder.max()])
      ..where(db.tasks.projectId.equals(projectId) &
          (parentId == null ? db.tasks.parentId.isNull() : db.tasks.parentId.equals(parentId)));
    final max = await q.map((r) => r.read(db.tasks.sortOrder.max())).getSingle();
    return (max ?? -1) + 1;
  }

  Future<int> _taskDepth(String? parentId) async {
    var depth = 0;
    var cursor = parentId;
    final seen = <String>{};
    while (cursor != null) {
      if (!seen.add(cursor)) throw RuleException('Task parents form a loop');
      depth++;
      cursor = (await getTask(cursor))?.parentId;
    }
    return depth; // number of ancestors
  }

  Future<String> addTask({
    required String title,
    String projectId = inboxId,
    String? sectionId,
    String? parentId,
    int priority = 4,
    String? dueDate,
    String? dueTime,
    String? recurrence,
    String? deadline,
    String description = '',
    List<String> labelIds = const [],
    List<ReminderSpec> reminders = const [],
  }) async {
    _checkWhen(dueDate: dueDate, dueTime: dueTime, recurrence: recurrence, deadline: deadline);
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw RuleException('A task needs a title');
    if (trimmed.length > 500) throw RuleException('Titles are limited to 500 characters');
    var project = projectId;
    var section = sectionId;
    if (parentId != null) {
      final parent = await getTask(parentId);
      if (parent == null) throw RuleException('Parent task not found');
      if (await _taskDepth(parentId) + 1 > maxTaskDepth) {
        throw RuleException('Sub-tasks go at most $maxTaskDepth levels deep');
      }
      project = parent.projectId;
      section = parent.sectionId;
    }
    final id = newId();
    final stamp = now;
    await db.transaction(() async {
      await db.into(db.tasks).insert(TasksCompanion.insert(
            id: id,
            title: trimmed,
            description: Value(description),
            projectId: project,
            sectionId: Value(section),
            parentId: Value(parentId),
            priority: Value(priority.clamp(1, 4)),
            dueDate: Value(dueDate),
            dueTime: Value(dueTime),
            recurrence: Value(recurrence),
            deadline: Value(deadline),
            sortOrder: Value(await _nextTaskOrder(project, parentId)),
            createdAt: stamp,
            updatedAt: stamp,
          ));
      for (final l in labelIds.toSet()) {
        await db.into(db.taskLabels).insert(TaskLabelsCompanion.insert(taskId: id, labelId: l));
      }
      for (final r in reminders) {
        await _insertReminder(id, r);
      }
    });
    return id;
  }

  /// Validates the date, time and repeat fields (throws [RuleException]).
  void _checkWhen({String? dueDate, String? dueTime, String? recurrence, String? deadline}) {
    if (dueDate != null && parseIsoDate(dueDate) == null) throw RuleException('Invalid due date');
    if (deadline != null && parseIsoDate(deadline) == null) throw RuleException('Invalid deadline');
    if (dueTime != null) {
      if (parseClock(dueTime) == null) throw RuleException('Invalid time');
      if (dueDate == null && recurrence == null) throw RuleException('A time needs a date');
    }
    if (recurrence != null) {
      try {
        parseRecurrence(recurrence, now);
      } on RecurrenceException catch (e) {
        throw RuleException(e.message);
      }
    }
  }

  /// Resolves a parsed Quick Add line against what exists (FR-Q2, FR-Q5).
  Future<QuickAddPlan> planQuickAdd(String input, {String defaultProjectId = inboxId, bool parseDates = true, int weekStart = 1}) async {
    final parsed = parseQuickAdd(input, now, parseDates: parseDates, weekStart: weekStart);
    var projectId = defaultProjectId;
    String? unknownProject;
    if (parsed.projectName != null) {
      final projects = await (db.select(db.projects)..where((p) => p.deletedAt.isNull())).get();
      final wanted = normaliseName(parsed.projectName!);
      final hit = projects.where((p) => normaliseName(p.name) == wanted || p.id.toLowerCase() == wanted);
      if (hit.isNotEmpty) {
        projectId = hit.first.id;
      } else {
        unknownProject = parsed.projectName;
      }
    }
    String? sectionId;
    String? unknownSection;
    if (parsed.sectionName != null && unknownProject == null) {
      final sections = await (db.select(db.sections)
            ..where((s) => s.projectId.equals(projectId) & s.deletedAt.isNull()))
          .get();
      final wanted = normaliseName(parsed.sectionName!);
      final hit = sections.where((s) => normaliseName(s.name) == wanted);
      if (hit.isNotEmpty) {
        sectionId = hit.first.id;
      } else {
        unknownSection = parsed.sectionName;
      }
    }
    final labels = await (db.select(db.labels)..where((l) => l.deletedAt.isNull())).get();
    final labelIds = <String>[];
    final unknownLabels = <String>[];
    for (final name in parsed.labels) {
      final hit = labels.where((l) => l.name.toLowerCase() == name);
      if (hit.isNotEmpty) {
        labelIds.add(hit.first.id);
      } else {
        unknownLabels.add(name);
      }
    }
    return QuickAddPlan(
      parsed: parsed, projectId: projectId, sectionId: sectionId, labelIds: labelIds,
      unknownProject: unknownProject, unknownSection: unknownSection, unknownLabels: unknownLabels,
    );
  }

  /// Creates the task from a plan. With [createMissing] the unknown project,
  /// section and labels are created first; without it they are dropped.
  /// [fields] replaces what the text said (the sheet applies the owner's own
  /// choices); [extraLabelIds] adds labels picked in the sheet.
  Future<String> addFromPlan(
    QuickAddPlan plan, {
    bool createMissing = false,
    TaskFields? fields,
    List<String> extraLabelIds = const [],
  }) async {
    var projectId = plan.projectId;
    var sectionId = plan.sectionId;
    final labelIds = [...plan.labelIds, ...extraLabelIds];
    if (createMissing) {
      if (plan.unknownProject != null) {
        projectId = await createProject(name: plan.unknownProject!);
      }
      if (plan.unknownSection != null || (plan.unknownProject != null && plan.parsed.sectionName != null)) {
        sectionId = await createSection(projectId, plan.parsed.sectionName!);
      }
      for (final name in plan.unknownLabels) {
        labelIds.add(await createLabel(name));
      }
    }
    final f = fields ?? plan.fields;
    return addTask(
      title: plan.parsed.title,
      projectId: projectId,
      sectionId: sectionId,
      priority: f.priority,
      dueDate: f.dueDate,
      dueTime: f.dueTime,
      recurrence: f.recurrence,
      deadline: f.deadline,
      labelIds: labelIds,
      reminders: f.reminders,
    );
  }

  Future<void> updateTask(
    String id, {
    String? title,
    String? description,
    int? priority,
    Value<String?> dueDate = const Value.absent(),
    Value<String?> dueTime = const Value.absent(),
    Value<String?> recurrence = const Value.absent(),
    Value<String?> deadline = const Value.absent(),
    List<String>? labelIds,
  }) async {
    if (title != null && title.trim().isEmpty) throw RuleException('A task needs a title');
    if (dueDate.present || dueTime.present || recurrence.present || deadline.present) {
      final current = await getTask(id);
      if (current != null) {
        _checkWhen(
          dueDate: dueDate.present ? dueDate.value : current.dueDate,
          dueTime: dueTime.present ? dueTime.value : current.dueTime,
          recurrence: recurrence.present ? recurrence.value : current.recurrence,
          deadline: deadline.present ? deadline.value : current.deadline,
        );
      }
    }
    await db.transaction(() async {
      await (db.update(db.tasks)..where((t) => t.id.equals(id))).write(TasksCompanion(
        title: title == null ? const Value.absent() : Value(title.trim()),
        description: description == null ? const Value.absent() : Value(description),
        priority: priority == null ? const Value.absent() : Value(priority.clamp(1, 4)),
        dueDate: dueDate,
        dueTime: dueTime,
        recurrence: recurrence,
        deadline: deadline,
        updatedAt: Value(now),
      ));
      if (labelIds != null) {
        await (db.delete(db.taskLabels)..where((l) => l.taskId.equals(id))).go();
        for (final l in labelIds.toSet()) {
          await db.into(db.taskLabels).insert(TaskLabelsCompanion.insert(taskId: id, labelId: l));
        }
      }
    });
  }

  Future<List<Task>> _descendants(String id) async {
    final out = <Task>[];
    final queue = [id];
    final seen = <String>{id};
    while (queue.isNotEmpty) {
      final parent = queue.removeLast();
      final kids = await (db.select(db.tasks)..where((t) => t.parentId.equals(parent))).get();
      for (final k in kids) {
        if (seen.add(k.id)) {
          out.add(k);
          queue.add(k.id);
        }
      }
    }
    return out;
  }

  /// Open sub-tasks anywhere below [id]; used to ask before completing a parent (FR-T3).
  Future<List<Task>> openDescendants(String id) async =>
      (await _descendants(id)).where((t) => t.completedAt == null && t.deletedAt == null).toList();

  /// Completes or reopens a task. Returns the ids changed, so the UI can undo.
  Future<List<String>> setCompleted(String id, bool done, {bool withSubtasks = false}) async {
    final changed = <String>[];
    await db.transaction(() async {
      final stamp = now;
      final task = await getTask(id);
      if (task == null) return;
      final targets = [task, if (withSubtasks) ...await _descendants(id)];
      for (final t in targets) {
        final already = (t.completedAt != null) == done;
        if (already) continue;
        await (db.update(db.tasks)..where((x) => x.id.equals(t.id))).write(TasksCompanion(
          completedAt: Value(done ? stamp : null),
          updatedAt: Value(stamp),
        ));
        changed.add(t.id);
      }
    });
    return changed;
  }

  Future<void> reopenAll(List<String> ids) async {
    for (final id in ids) {
      await (db.update(db.tasks)..where((t) => t.id.equals(id)))
          .write(TasksCompanion(completedAt: const Value(null), updatedAt: Value(now)));
    }
  }

  Future<void> completeAll(List<String> ids) async {
    final stamp = now;
    for (final id in ids) {
      await (db.update(db.tasks)..where((t) => t.id.equals(id)))
          .write(TasksCompanion(completedAt: Value(stamp), updatedAt: Value(stamp)));
    }
  }

  /// Moves a task, with all its sub-tasks, to another project, section or
  /// parent (FR-T5). Throws [RuleException] for loops and over-deep nesting.
  Future<void> moveTask(String id, {required String projectId, String? sectionId, String? parentId}) async {
    final task = await getTask(id);
    if (task == null) return;
    final subtree = await _descendants(id);
    if (parentId != null) {
      if (parentId == id || subtree.any((t) => t.id == parentId)) {
        throw RuleException('A task cannot go inside itself');
      }
      final parent = await getTask(parentId);
      if (parent == null) throw RuleException('Parent task not found');
      projectId = parent.projectId;
      sectionId = parent.sectionId;
    }
    // Depth of the deepest descendant relative to the moved task.
    var below = 0;
    for (final d in subtree) {
      var steps = 0;
      String? cursor = d.id;
      while (cursor != null && cursor != id) {
        steps++;
        cursor = subtree.firstWhere((x) => x.id == cursor, orElse: () => task).parentId;
      }
      if (steps > below) below = steps;
    }
    final level = parentId == null ? 1 : await _taskDepth(parentId) + 1; // the moved task's own level
    if (level + below > maxTaskDepth) {
      throw RuleException('That would nest sub-tasks deeper than $maxTaskDepth levels');
    }
    final order = await _nextTaskOrder(projectId, parentId);
    await db.transaction(() async {
      final stamp = now;
      await (db.update(db.tasks)..where((t) => t.id.equals(id))).write(TasksCompanion(
        projectId: Value(projectId),
        sectionId: Value(sectionId),
        parentId: Value(parentId),
        sortOrder: Value(order),
        updatedAt: Value(stamp),
      ));
      for (final d in subtree) {
        await (db.update(db.tasks)..where((t) => t.id.equals(d.id))).write(TasksCompanion(
          projectId: Value(projectId),
          sectionId: Value(sectionId),
          updatedAt: Value(stamp),
        ));
      }
    });
  }

  /// Turns a sub-task into a top-level task (FR-T5).
  Future<void> promoteToTopLevel(String id) async {
    final t = await getTask(id);
    if (t == null) return;
    await moveTask(id, projectId: t.projectId, sectionId: t.sectionId);
  }

  /// Moves a task to the trash with its sub-tasks. Returns the ids so the
  /// UI can offer Undo (FR-T8).
  Future<List<String>> deleteTask(String id) async {
    final ids = <String>[];
    await db.transaction(() async {
      final stamp = now;
      final all = [?await getTask(id), ...await _descendants(id)];
      for (final t in all) {
        if (t.deletedAt != null) continue;
        await (db.update(db.tasks)..where((x) => x.id.equals(t.id)))
            .write(TasksCompanion(deletedAt: Value(stamp), updatedAt: Value(stamp)));
        ids.add(t.id);
      }
    });
    return ids;
  }

  Future<void> restoreTasks(List<String> ids) async {
    final stamp = now;
    for (final id in ids) {
      await (db.update(db.tasks)..where((t) => t.id.equals(id)))
          .write(TasksCompanion(deletedAt: const Value(null), updatedAt: Value(stamp)));
    }
    // A restored task whose project is in the trash goes back to Inbox.
    for (final id in ids) {
      final t = await getTask(id);
      if (t == null) continue;
      final p = await (db.select(db.projects)..where((x) => x.id.equals(t.projectId))).getSingleOrNull();
      if (p == null || p.deletedAt != null) {
        await (db.update(db.tasks)..where((x) => x.id.equals(id)))
            .write(const TasksCompanion(projectId: Value(inboxId), sectionId: Value(null)));
      }
    }
  }

  Future<void> deleteTaskForever(String id) async {
    await db.transaction(() async {
      final ids = [id, ...(await _descendants(id)).map((t) => t.id)];
      for (final x in ids) {
        await (db.delete(db.taskLabels)..where((l) => l.taskId.equals(x))).go();
        await (db.delete(db.comments)..where((c) => c.taskId.equals(x))).go();
        await (db.delete(db.reminders)..where((r) => r.taskId.equals(x))).go();
        await (db.delete(db.completions)..where((c) => c.taskId.equals(x))).go();
        await (db.delete(db.tasks)..where((t) => t.id.equals(x))).go();
      }
    });
  }

  /// Permanently removes anything that has been in the trash for 30 days.
  Future<void> purgeOldTrash() async {
    final cutoff = now.subtract(const Duration(days: trashDays));
    final oldTasks = await (db.select(db.tasks)
          ..where((t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerThanValue(cutoff)))
        .get();
    for (final t in oldTasks) {
      await deleteTaskForever(t.id);
    }
    await (db.delete(db.projects)
          ..where((p) => p.deletedAt.isNotNull() & p.deletedAt.isSmallerThanValue(cutoff) & p.id.equals(inboxId).not()))
        .go();
  }

  /// "Reschedule" for the whole Overdue block (FR-D7).
  Future<int> rescheduleOverdue(String today, String toDate) async {
    final n = await (db.update(db.tasks)
          ..where((t) => t.deletedAt.isNull() & t.completedAt.isNull() & t.dueDate.isNotNull() & t.dueDate.isSmallerThanValue(today)))
        .write(TasksCompanion(dueDate: Value(toDate), updatedAt: Value(now)));
    return n;
  }

  /// Moves the listed tasks to [toDate], keeping their times (FR-D7).
  Future<void> rescheduleTasks(List<String> ids, String toDate) async {
    if (parseIsoDate(toDate) == null) throw RuleException('Invalid date');
    await db.transaction(() async {
      for (final id in ids) {
        await (db.update(db.tasks)..where((t) => t.id.equals(id)))
            .write(TasksCompanion(dueDate: Value(toDate), updatedAt: Value(now)));
      }
    });
  }

  /// Puts each task back to a recorded due date (used by Undo of a bulk reschedule).
  Future<void> setDueDates(Map<String, String?> dates) async {
    await db.transaction(() async {
      for (final e in dates.entries) {
        await (db.update(db.tasks)..where((t) => t.id.equals(e.key)))
            .write(TasksCompanion(dueDate: Value(e.value), updatedAt: Value(now)));
      }
    });
  }

  Future<void> reorderTasks(List<String> orderedIds) async {
    await db.transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (db.update(db.tasks)..where((t) => t.id.equals(orderedIds[i])))
            .write(TasksCompanion(sortOrder: Value(i), updatedAt: Value(now)));
      }
    });
  }

  Future<void> setTaskCollapsed(String id, bool collapsed) =>
      (db.update(db.tasks)..where((t) => t.id.equals(id))).write(TasksCompanion(isCollapsed: Value(collapsed)));

  // ===========================================================================
  // Completing, repeating, reminders (R2)
  // ===========================================================================

  Recurrence? _recurrenceOf(Task t) {
    if (t.recurrence == null || t.dueDate == null) return null;
    try {
      return parseRecurrence(t.recurrence!, now);
    } on RecurrenceException {
      return null; // an unreadable repeat just completes the task
    }
  }

  /// Completes a task. A repeating task does not complete: it moves to its
  /// next date, its finished sub-tasks reopen, and the completion is logged
  /// (FR-R7). Every completion is logged, which is what the daily goal counts.
  Future<CompletionOutcome> completeTask(String id, {bool withSubtasks = false}) async {
    var outcome = const CompletionOutcome(changedIds: []);
    await db.transaction(() async {
      final stamp = now;
      final task = await getTask(id);
      if (task == null || task.completedAt != null) return;
      final completionId = newId();
      await db.into(db.completions).insert(CompletionsCompanion.insert(
            id: completionId, taskId: id, completedAt: stamp,
            dueDate: Value(task.dueDate), dueTime: Value(task.dueTime),
          ));
      final rec = _recurrenceOf(task);
      if (rec != null) {
        final next = nextDueAfterCompletion(
          recurrence: rec, dueDate: task.dueDate!, dueTime: task.dueTime, completedAt: stamp,
        );
        if (next != null) {
          outcome = await _advance(task, next, completionId: completionId);
          return;
        }
      }
      final targets = [task, if (withSubtasks) ...await _descendants(id)];
      final changed = <String>[];
      for (final t in targets) {
        if (t.completedAt != null) continue;
        await (db.update(db.tasks)..where((x) => x.id.equals(t.id)))
            .write(TasksCompanion(completedAt: Value(stamp), updatedAt: Value(stamp)));
        changed.add(t.id);
      }
      outcome = CompletionOutcome(changedIds: changed, completionId: completionId);
    });
    return outcome;
  }

  Future<CompletionOutcome> _advance(Task task, NextDue next, {String? completionId}) async {
    final stamp = now;
    final reopened = <String>[];
    for (final d in await _descendants(task.id)) {
      if (d.completedAt != null && d.deletedAt == null) {
        await (db.update(db.tasks)..where((x) => x.id.equals(d.id)))
            .write(TasksCompanion(completedAt: const Value(null), updatedAt: Value(stamp)));
        reopened.add(d.id);
      }
    }
    await (db.update(db.tasks)..where((x) => x.id.equals(task.id))).write(TasksCompanion(
      dueDate: Value(next.date),
      dueTime: Value(next.time),
      snoozedUntil: const Value(null),
      updatedAt: Value(stamp),
    ));
    return CompletionOutcome(
      changedIds: const [],
      rescheduledId: task.id,
      previousDueDate: task.dueDate,
      previousDueTime: task.dueTime,
      completionId: completionId,
      reopenedSubtaskIds: reopened,
      nextDueDate: next.date,
    );
  }

  /// Skips this occurrence of a repeating task without completing it (FR-R8).
  Future<CompletionOutcome?> skipOccurrence(String id) async {
    CompletionOutcome? outcome;
    await db.transaction(() async {
      final task = await getTask(id);
      if (task == null) return;
      final rec = _recurrenceOf(task);
      if (rec == null) return;
      final next = nextDueAfterCompletion(recurrence: rec, dueDate: task.dueDate!, dueTime: task.dueTime, completedAt: now);
      if (next == null) return;
      outcome = await _advance(task, next);
    });
    return outcome;
  }

  /// Keeps the task and its current date but stops it repeating (FR-R8).
  Future<void> stopRecurrence(String id) => updateTask(id, recurrence: const Value(null));

  /// Reverses [completeTask] or [skipOccurrence] exactly.
  Future<void> undoCompletion(CompletionOutcome o) async {
    await db.transaction(() async {
      final stamp = now;
      if (o.rescheduledId != null) {
        await (db.update(db.tasks)..where((x) => x.id.equals(o.rescheduledId!))).write(TasksCompanion(
          dueDate: Value(o.previousDueDate),
          dueTime: Value(o.previousDueTime),
          updatedAt: Value(stamp),
        ));
        for (final id in o.reopenedSubtaskIds) {
          await (db.update(db.tasks)..where((x) => x.id.equals(id)))
              .write(TasksCompanion(completedAt: Value(stamp), updatedAt: Value(stamp)));
        }
      } else {
        for (final id in o.changedIds) {
          await (db.update(db.tasks)..where((x) => x.id.equals(id)))
              .write(TasksCompanion(completedAt: const Value(null), updatedAt: Value(stamp)));
        }
      }
      if (o.completionId != null) {
        await (db.delete(db.completions)..where((c) => c.id.equals(o.completionId!))).go();
      }
    });
  }

  /// Reopens a completed task and takes its last completion out of the history.
  Future<void> reopenTask(String id) async {
    await db.transaction(() async {
      await (db.update(db.tasks)..where((t) => t.id.equals(id)))
          .write(TasksCompanion(completedAt: const Value(null), updatedAt: Value(now)));
      final last = await (db.select(db.completions)
            ..where((c) => c.taskId.equals(id))
            ..orderBy([(c) => OrderingTerm.desc(c.completedAt)])
            ..limit(1))
          .getSingleOrNull();
      if (last != null) await (db.delete(db.completions)..where((c) => c.id.equals(last.id))).go();
    });
  }

  /// Puts a task back to completed after an Undo of a reopen.
  Future<CompletionOutcome> recomplete(String id) => completeTask(id);

  // --- Reminders ---------------------------------------------------------------

  Future<void> _insertReminder(String taskId, ReminderSpec spec) async {
    final stamp = now;
    await db.into(db.reminders).insert(RemindersCompanion.insert(
          id: newId(), taskId: taskId, spec: spec.encode(), createdAt: stamp, updatedAt: stamp));
  }

  Future<void> addReminder(String taskId, ReminderSpec spec) async {
    final existing = await (db.select(db.reminders)..where((r) => r.taskId.equals(taskId) & r.deletedAt.isNull())).get();
    if (existing.any((r) => r.spec == spec.encode())) return;
    await _insertReminder(taskId, spec);
  }

  Future<void> removeReminder(String id) => (db.delete(db.reminders)..where((r) => r.id.equals(id))).go();

  Stream<List<Reminder>> watchReminders(String taskId) => (db.select(db.reminders)
        ..where((r) => r.taskId.equals(taskId) & r.deletedAt.isNull())
        ..orderBy([(r) => OrderingTerm.asc(r.createdAt)]))
      .watch();

  /// Everything the notification scheduler needs, in one read.
  Future<List<ReminderTask>> reminderTasks() async {
    final tasks = await (_openTasks()
          ..where((t) => t.dueDate.isNotNull() | t.snoozedUntil.isNotNull()))
        .get();
    final reminders = await (db.select(db.reminders)..where((r) => r.deletedAt.isNull())).get();
    final byTask = <String, List<ReminderSpec>>{};
    for (final r in reminders) {
      final spec = ReminderSpec.decode(r.spec);
      if (spec != null) byTask.putIfAbsent(r.taskId, () => []).add(spec);
    }
    return [
      for (final t in tasks)
        ReminderTask(
          id: t.id, title: t.title, dueDate: t.dueDate, dueTime: t.dueTime,
          reminders: byTask[t.id] ?? const [], snoozedUntil: t.snoozedUntil,
        ),
    ];
  }

  /// A cheap signal that anything affecting reminders changed.
  Stream<int> watchReminderChanges() => db
      .customSelect(
        'SELECT (SELECT COUNT(*) FROM tasks) AS a, (SELECT IFNULL(MAX(updated_at), 0) FROM tasks) AS b, '
        '(SELECT COUNT(*) FROM reminders) AS c, (SELECT IFNULL(MAX(updated_at), 0) FROM reminders) AS d',
        readsFrom: {db.tasks, db.reminders},
      )
      .watch()
      .map((rows) => Object.hash(rows.first.read<int>('a'), rows.first.read<int>('b'), rows.first.read<int>('c'), rows.first.read<int>('d')));

  Future<void> snoozeTask(String id, DateTime until) => (db.update(db.tasks)..where((t) => t.id.equals(id)))
      .write(TasksCompanion(snoozedUntil: Value(until), updatedAt: Value(now)));

  Future<void> clearSnooze(String id) => (db.update(db.tasks)..where((t) => t.id.equals(id)))
      .write(TasksCompanion(snoozedUntil: const Value(null), updatedAt: Value(now)));

  // --- Duplicate (FR-T6) -----------------------------------------------------------

  /// Copies a task next to the original, with its labels and reminders, and
  /// optionally its sub-tasks and comments. The copy is always open.
  Future<String> duplicateTask(String id, {bool withSubtasks = true, bool withComments = false}) async {
    final t = await getTask(id);
    if (t == null) throw RuleException('Task not found');
    Future<String> copy(Task src, String? parentId) async {
      final labels = (await (db.select(db.taskLabels)..where((l) => l.taskId.equals(src.id))).get()).map((l) => l.labelId).toList();
      final reminders = (await (db.select(db.reminders)..where((r) => r.taskId.equals(src.id) & r.deletedAt.isNull())).get())
          .map((r) => ReminderSpec.decode(r.spec))
          .whereType<ReminderSpec>()
          .toList();
      final newTask = await addTask(
        title: src.title,
        description: src.description,
        projectId: src.projectId,
        sectionId: src.sectionId,
        parentId: parentId ?? src.parentId,
        priority: src.priority,
        dueDate: src.dueDate,
        dueTime: src.dueTime,
        recurrence: src.recurrence,
        deadline: src.deadline,
        labelIds: labels,
        reminders: reminders,
      );
      if (withComments) {
        for (final c in await (db.select(db.comments)..where((c) => c.taskId.equals(src.id) & c.deletedAt.isNull())).get()) {
          await addComment(newTask, c.body);
        }
      }
      if (withSubtasks) {
        final kids = await (db.select(db.tasks)
              ..where((k) => k.parentId.equals(src.id) & k.deletedAt.isNull())
              ..orderBy([(k) => OrderingTerm.asc(k.sortOrder)]))
            .get();
        for (final k in kids) {
          await copy(k, newTask);
        }
      }
      return newTask;
    }

    late String result;
    await db.transaction(() async {
      result = await copy(t, null);
    });
    return result;
  }

  // --- Project comments (FR-P10) ----------------------------------------------------

  Stream<List<ProjectComment>> watchProjectComments(String projectId) => (db.select(db.projectComments)
        ..where((c) => c.projectId.equals(projectId) & c.deletedAt.isNull())
        ..orderBy([(c) => OrderingTerm.asc(c.createdAt)]))
      .watch();

  Future<String> addProjectComment(String projectId, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) throw RuleException('A comment cannot be empty');
    final id = newId();
    final stamp = now;
    await db.into(db.projectComments).insert(
        ProjectCommentsCompanion.insert(id: id, projectId: projectId, body: trimmed, createdAt: stamp, updatedAt: stamp));
    return id;
  }

  Future<void> editProjectComment(String id, String body) => (db.update(db.projectComments)..where((c) => c.id.equals(id)))
      .write(ProjectCommentsCompanion(body: Value(body.trim()), updatedAt: Value(now)));

  Future<void> deleteProjectComment(String id) => (db.update(db.projectComments)..where((c) => c.id.equals(id)))
      .write(ProjectCommentsCompanion(deletedAt: Value(now), updatedAt: Value(now)));

  Future<int> completedOn(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await (db.select(db.completions)
          ..where((c) => c.completedAt.isBiggerOrEqualValue(start) & c.completedAt.isSmallerThanValue(end)))
        .get();
    return rows.length;
  }

  Stream<int> watchCompletedOn(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return (db.select(db.completions)
          ..where((c) => c.completedAt.isBiggerOrEqualValue(start) & c.completedAt.isSmallerThanValue(end)))
        .watch()
        .map((r) => r.length);
  }

  // ===========================================================================
  // Projects
  // ===========================================================================

  Future<Project?> getProject(String id) =>
      (db.select(db.projects)..where((p) => p.id.equals(id))).getSingleOrNull();

  Future<int> _projectDepth(String? parentId) async {
    var depth = 0;
    var cursor = parentId;
    final seen = <String>{};
    while (cursor != null) {
      if (!seen.add(cursor)) throw RuleException('Projects form a loop');
      depth++;
      cursor = (await getProject(cursor))?.parentId;
    }
    return depth;
  }

  Future<String> createProject({required String name, int color = 0xFF57927C, String? parentId}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw RuleException('A project needs a name');
    if (parentId != null && await _projectDepth(parentId) >= maxProjectDepth) {
      throw RuleException('Projects nest at most $maxProjectDepth levels');
    }
    final id = newId();
    final stamp = now;
    final maxOrder = await (db.selectOnly(db.projects)..addColumns([db.projects.sortOrder.max()]))
        .map((r) => r.read(db.projects.sortOrder.max()))
        .getSingle();
    await db.into(db.projects).insert(ProjectsCompanion.insert(
          id: id, name: trimmed, color: color,
          parentId: Value(parentId),
          sortOrder: Value((maxOrder ?? 0) + 1),
          createdAt: stamp, updatedAt: stamp,
        ));
    return id;
  }

  Future<void> updateProject(String id, {String? name, int? color, bool? isFavorite, bool? isArchived}) async {
    if (name != null && name.trim().isEmpty) throw RuleException('A project needs a name');
    await (db.update(db.projects)..where((p) => p.id.equals(id))).write(ProjectsCompanion(
      name: name == null ? const Value.absent() : Value(name.trim()),
      color: color == null ? const Value.absent() : Value(color),
      isFavorite: isFavorite == null ? const Value.absent() : Value(isFavorite),
      isArchived: isArchived == null ? const Value.absent() : Value(isArchived),
      updatedAt: Value(now),
    ));
  }

  /// Re-parents a project, refusing loops and depth over [maxProjectDepth].
  Future<void> moveProject(String id, String? newParentId) async {
    if (id == inboxId) throw RuleException('The Inbox cannot be moved');
    if (newParentId != null) {
      var cursor = newParentId;
      String? c = cursor;
      while (c != null) {
        if (c == id) throw RuleException('A project cannot go inside itself');
        c = (await getProject(c))?.parentId;
      }
      // Height of the subtree being moved.
      Future<int> height(String pid) async {
        final kids = await (db.select(db.projects)..where((p) => p.parentId.equals(pid) & p.deletedAt.isNull())).get();
        var h = 0;
        for (final k in kids) {
          final kh = await height(k.id);
          if (kh + 1 > h) h = kh + 1;
        }
        return h;
      }

      final ancestors = await _projectDepth(newParentId);
      if (ancestors + 1 + await height(id) > maxProjectDepth) {
        throw RuleException('Projects nest at most $maxProjectDepth levels');
      }
    }
    await (db.update(db.projects)..where((p) => p.id.equals(id)))
        .write(ProjectsCompanion(parentId: Value(newParentId), updatedAt: Value(now)));
  }

  Future<void> reorderProjects(List<String> orderedIds) async {
    await db.transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (db.update(db.projects)..where((p) => p.id.equals(orderedIds[i])))
            .write(ProjectsCompanion(sortOrder: Value(i), updatedAt: Value(now)));
      }
    });
  }

  /// Deletes a project (FR-P3). Its tasks are moved to Inbox, or trashed
  /// with it when [deleteTasks] is true; sub-projects are lifted one level.
  /// Returns the task ids that were trashed, for Undo.
  Future<List<String>> deleteProject(String id, {required bool deleteTasks}) async {
    if (id == inboxId) throw RuleException('The Inbox cannot be deleted');
    final trashed = <String>[];
    await db.transaction(() async {
      final stamp = now;
      final project = await getProject(id);
      if (project == null) return;
      await (db.update(db.projects)..where((p) => p.parentId.equals(id)))
          .write(ProjectsCompanion(parentId: Value(project.parentId), updatedAt: Value(stamp)));
      final tasks = await (db.select(db.tasks)..where((t) => t.projectId.equals(id) & t.deletedAt.isNull())).get();
      if (deleteTasks) {
        for (final t in tasks) {
          await (db.update(db.tasks)..where((x) => x.id.equals(t.id)))
              .write(TasksCompanion(deletedAt: Value(stamp), updatedAt: Value(stamp)));
          trashed.add(t.id);
        }
      } else {
        await (db.update(db.tasks)..where((t) => t.projectId.equals(id)))
            .write(TasksCompanion(projectId: const Value(inboxId), sectionId: const Value(null), updatedAt: Value(stamp)));
      }
      await (db.update(db.sections)..where((s) => s.projectId.equals(id)))
          .write(SectionsCompanion(deletedAt: Value(stamp), updatedAt: Value(stamp)));
      await (db.update(db.projects)..where((p) => p.id.equals(id)))
          .write(ProjectsCompanion(deletedAt: Value(stamp), updatedAt: Value(stamp)));
    });
    return trashed;
  }

  Future<void> restoreProject(String id) async {
    final stamp = now;
    await db.transaction(() async {
      await (db.update(db.projects)..where((p) => p.id.equals(id)))
          .write(ProjectsCompanion(deletedAt: const Value(null), updatedAt: Value(stamp)));
      await (db.update(db.sections)..where((s) => s.projectId.equals(id)))
          .write(SectionsCompanion(deletedAt: const Value(null), updatedAt: Value(stamp)));
    });
  }

  Future<String> duplicateProject(String id) async {
    final p = await getProject(id);
    if (p == null) throw RuleException('Project not found');
    final newProject = await createProject(name: '${p.name} (copy)', color: p.color, parentId: p.parentId);
    final sectionMap = <String, String>{};
    final sections = await (db.select(db.sections)..where((s) => s.projectId.equals(id) & s.deletedAt.isNull())).get();
    for (final s in sections) {
      sectionMap[s.id] = await createSection(newProject, s.name);
    }
    final tasks = await (db.select(db.tasks)
          ..where((t) => t.projectId.equals(id) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
    final idMap = <String, String>{};
    // Parents first: sort by depth so a child's parent already has a new id.
    int depthOf(Task t) {
      var d = 0;
      var c = t;
      while (c.parentId != null) {
        d++;
        final next = tasks.where((x) => x.id == c.parentId);
        if (next.isEmpty) break;
        c = next.first;
      }
      return d;
    }

    final ordered = [...tasks]..sort((a, b) => depthOf(a).compareTo(depthOf(b)));
    for (final t in ordered) {
      final labels = (await (db.select(db.taskLabels)..where((l) => l.taskId.equals(t.id))).get()).map((l) => l.labelId).toList();
      idMap[t.id] = await addTask(
        title: t.title,
        description: t.description,
        projectId: newProject,
        sectionId: t.sectionId == null ? null : sectionMap[t.sectionId],
        parentId: t.parentId == null ? null : idMap[t.parentId],
        priority: t.priority,
        dueDate: t.dueDate,
        labelIds: labels,
      );
    }
    return newProject;
  }

  // ===========================================================================
  // Sections
  // ===========================================================================

  Future<String> createSection(String projectId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw RuleException('A section needs a name');
    final id = newId();
    final stamp = now;
    final maxOrder = await (db.selectOnly(db.sections)
          ..addColumns([db.sections.sortOrder.max()])
          ..where(db.sections.projectId.equals(projectId)))
        .map((r) => r.read(db.sections.sortOrder.max()))
        .getSingle();
    await db.into(db.sections).insert(SectionsCompanion.insert(
          id: id, projectId: projectId, name: trimmed,
          sortOrder: Value((maxOrder ?? -1) + 1),
          createdAt: stamp, updatedAt: stamp,
        ));
    return id;
  }

  Future<void> updateSection(String id, {String? name, bool? isCollapsed, bool? isArchived}) =>
      (db.update(db.sections)..where((s) => s.id.equals(id))).write(SectionsCompanion(
        name: name == null ? const Value.absent() : Value(name.trim()),
        isCollapsed: isCollapsed == null ? const Value.absent() : Value(isCollapsed),
        isArchived: isArchived == null ? const Value.absent() : Value(isArchived),
        updatedAt: Value(now),
      ));

  Future<void> reorderSections(List<String> orderedIds) async {
    await db.transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (db.update(db.sections)..where((s) => s.id.equals(orderedIds[i])))
            .write(SectionsCompanion(sortOrder: Value(i), updatedAt: Value(now)));
      }
    });
  }

  /// Deleting a section keeps its tasks: they move out of the section.
  Future<void> deleteSection(String id) async {
    await db.transaction(() async {
      final stamp = now;
      await (db.update(db.tasks)..where((t) => t.sectionId.equals(id)))
          .write(TasksCompanion(sectionId: const Value(null), updatedAt: Value(stamp)));
      await (db.update(db.sections)..where((s) => s.id.equals(id)))
          .write(SectionsCompanion(deletedAt: Value(stamp), updatedAt: Value(stamp)));
    });
  }

  // ===========================================================================
  // Labels
  // ===========================================================================

  Future<Label?> _labelByName(String name) async {
    final all = await (db.select(db.labels)..where((l) => l.deletedAt.isNull())).get();
    final wanted = name.trim().toLowerCase();
    for (final l in all) {
      if (l.name.toLowerCase() == wanted) return l;
    }
    return null;
  }

  Future<String> createLabel(String name, {int color = 0xFF8D75B4}) async {
    final trimmed = name.trim().replaceFirst(RegExp(r'^[%@]'), '');
    if (trimmed.isEmpty) throw RuleException('A label needs a name');
    final existing = await _labelByName(trimmed);
    if (existing != null) return existing.id;
    final id = newId();
    final stamp = now;
    await db.into(db.labels).insert(LabelsCompanion.insert(
          id: id, name: trimmed, color: color, createdAt: stamp, updatedAt: stamp));
    return id;
  }

  Future<void> updateLabel(String id, {String? name, int? color, bool? isFavorite}) async {
    if (name != null) {
      final trimmed = name.trim();
      if (trimmed.isEmpty) throw RuleException('A label needs a name');
      final clash = await _labelByName(trimmed);
      if (clash != null && clash.id != id) throw RuleException('A label named "$trimmed" already exists');
    }
    await (db.update(db.labels)..where((l) => l.id.equals(id))).write(LabelsCompanion(
      name: name == null ? const Value.absent() : Value(name.trim()),
      color: color == null ? const Value.absent() : Value(color),
      isFavorite: isFavorite == null ? const Value.absent() : Value(isFavorite),
      updatedAt: Value(now),
    ));
  }

  Future<void> deleteLabel(String id) async {
    await db.transaction(() async {
      await (db.delete(db.taskLabels)..where((l) => l.labelId.equals(id))).go();
      await (db.delete(db.labels)..where((l) => l.id.equals(id))).go();
    });
  }

  /// Moves every task from [sourceId] to [targetId], then deletes the source.
  Future<void> mergeLabels(String sourceId, String targetId) async {
    if (sourceId == targetId) return;
    await db.transaction(() async {
      final links = await (db.select(db.taskLabels)..where((l) => l.labelId.equals(sourceId))).get();
      for (final l in links) {
        await db.into(db.taskLabels).insert(
              TaskLabelsCompanion.insert(taskId: l.taskId, labelId: targetId),
              mode: InsertMode.insertOrIgnore,
            );
      }
      await deleteLabel(sourceId);
    });
  }

  // ===========================================================================
  // Comments
  // ===========================================================================

  Future<String> addComment(String taskId, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) throw RuleException('A comment cannot be empty');
    final id = newId();
    final stamp = now;
    await db.into(db.comments).insert(
        CommentsCompanion.insert(id: id, taskId: taskId, body: trimmed, createdAt: stamp, updatedAt: stamp));
    return id;
  }

  Future<void> editComment(String id, String body) =>
      (db.update(db.comments)..where((c) => c.id.equals(id)))
          .write(CommentsCompanion(body: Value(body.trim()), updatedAt: Value(now)));

  Future<void> deleteComment(String id) =>
      (db.update(db.comments)..where((c) => c.id.equals(id)))
          .write(CommentsCompanion(deletedAt: Value(now), updatedAt: Value(now)));

  // ===========================================================================
  // Backup and restore (FR-X1, FR-X3)
  // ===========================================================================

  Future<Bundle> exportBundle() async {
    final projects = await (db.select(db.projects)..where((p) => p.deletedAt.isNull())).get();
    final sections = await (db.select(db.sections)..where((s) => s.deletedAt.isNull())).get();
    final labels = await (db.select(db.labels)..where((l) => l.deletedAt.isNull())).get();
    final tasks = await (db.select(db.tasks)..where((t) => t.deletedAt.isNull())).get();
    final links = await db.select(db.taskLabels).get();
    final comments = await (db.select(db.comments)..where((c) => c.deletedAt.isNull())).get();
    final reminderRows = await (db.select(db.reminders)..where((r) => r.deletedAt.isNull())).get();
    final completionRows = await db.select(db.completions).get();
    final noteRows = await (db.select(db.projectComments)..where((c) => c.deletedAt.isNull())).get();
    final settings = await db.select(db.settings).get();
    final liveTaskIds = tasks.map((t) => t.id).toSet();
    final byTask = <String, List<String>>{};
    for (final l in links) {
      if (liveTaskIds.contains(l.taskId)) byTask.putIfAbsent(l.taskId, () => []).add(l.labelId);
    }
    final liveProjects = projects.map((p) => p.id).toSet();
    final liveSections = sections.map((s) => s.id).toSet();
    final liveLabels = labels.map((l) => l.id).toSet();
    return Bundle(
      projects: [
        for (final p in projects)
          ProjectRec(
            id: p.id, name: p.name, color: p.color,
            parentId: liveProjects.contains(p.parentId) ? p.parentId : null,
            isFavorite: p.isFavorite, isArchived: p.isArchived, sortOrder: p.sortOrder,
          ),
      ],
      sections: [
        for (final s in sections.where((s) => liveProjects.contains(s.projectId)))
          SectionRec(
            id: s.id, projectId: s.projectId, name: s.name, sortOrder: s.sortOrder,
            isCollapsed: s.isCollapsed, isArchived: s.isArchived,
          ),
      ],
      labels: [
        for (final l in labels)
          LabelRec(id: l.id, name: l.name, color: l.color, isFavorite: l.isFavorite, sortOrder: l.sortOrder),
      ],
      tasks: [
        for (final t in tasks.where((t) => liveProjects.contains(t.projectId)))
          TaskRec(
            id: t.id, title: t.title, description: t.description, projectId: t.projectId,
            sectionId: liveSections.contains(t.sectionId) ? t.sectionId : null,
            parentId: liveTaskIds.contains(t.parentId) ? t.parentId : null,
            priority: t.priority, dueDate: t.dueDate, dueTime: t.dueTime,
            recurrence: t.recurrence, deadline: t.deadline, completedAt: t.completedAt,
            sortOrder: t.sortOrder, isCollapsed: t.isCollapsed,
            labelIds: (byTask[t.id] ?? const []).where(liveLabels.contains).toList(),
            createdAt: t.createdAt,
          ),
      ],
      comments: [
        for (final c in comments.where((c) => liveTaskIds.contains(c.taskId)))
          CommentRec(id: c.id, taskId: c.taskId, body: c.body, createdAt: c.createdAt),
      ],
      reminders: [
        for (final r in reminderRows.where((r) => liveTaskIds.contains(r.taskId)))
          ReminderRec(id: r.id, taskId: r.taskId, spec: r.spec),
      ],
      completions: [
        for (final c in completionRows.where((c) => liveTaskIds.contains(c.taskId)))
          CompletionRec(id: c.id, taskId: c.taskId, completedAt: c.completedAt, dueDate: c.dueDate, dueTime: c.dueTime),
      ],
      projectComments: [
        for (final c in noteRows.where((c) => liveProjects.contains(c.projectId)))
          ProjectCommentRec(id: c.id, projectId: c.projectId, body: c.body, createdAt: c.createdAt),
      ],
      settings: {for (final s in settings) s.key: s.value},
    );
  }

  /// Replaces all data with [b] in one transaction. If anything fails the
  /// existing data is untouched.
  Future<void> replaceAll(Bundle b) async {
    await db.transaction(() async {
      final stamp = now;
      await db.delete(db.taskLabels).go();
      await db.delete(db.comments).go();
      await db.delete(db.reminders).go();
      await db.delete(db.completions).go();
      await db.delete(db.projectComments).go();
      await db.delete(db.tasks).go();
      await db.delete(db.sections).go();
      await db.delete(db.labels).go();
      await db.delete(db.projects).go();
      await db.delete(db.settings).go();
      for (final p in b.projects) {
        await db.into(db.projects).insert(ProjectsCompanion.insert(
              id: p.id, name: p.name, color: p.color, parentId: Value(p.parentId),
              isFavorite: Value(p.isFavorite), isArchived: Value(p.isArchived),
              sortOrder: Value(p.sortOrder), createdAt: stamp, updatedAt: stamp));
      }
      for (final s in b.sections) {
        await db.into(db.sections).insert(SectionsCompanion.insert(
              id: s.id, projectId: s.projectId, name: s.name, sortOrder: Value(s.sortOrder),
              isCollapsed: Value(s.isCollapsed), isArchived: Value(s.isArchived),
              createdAt: stamp, updatedAt: stamp));
      }
      for (final l in b.labels) {
        await db.into(db.labels).insert(LabelsCompanion.insert(
              id: l.id, name: l.name, color: l.color, isFavorite: Value(l.isFavorite),
              sortOrder: Value(l.sortOrder), createdAt: stamp, updatedAt: stamp));
      }
      for (final t in b.tasks) {
        await db.into(db.tasks).insert(TasksCompanion.insert(
              id: t.id, title: t.title, description: Value(t.description), projectId: t.projectId,
              sectionId: Value(t.sectionId), parentId: Value(t.parentId), priority: Value(t.priority),
              dueDate: Value(t.dueDate), dueTime: Value(t.dueTime), recurrence: Value(t.recurrence),
              deadline: Value(t.deadline), completedAt: Value(t.completedAt),
              sortOrder: Value(t.sortOrder), isCollapsed: Value(t.isCollapsed),
              createdAt: t.createdAt, updatedAt: stamp));
        for (final l in t.labelIds) {
          await db.into(db.taskLabels).insert(TaskLabelsCompanion.insert(taskId: t.id, labelId: l));
        }
      }
      for (final c in b.comments) {
        await db.into(db.comments).insert(CommentsCompanion.insert(
              id: c.id, taskId: c.taskId, body: c.body, createdAt: c.createdAt, updatedAt: stamp));
      }
      for (final r in b.reminders) {
        await db.into(db.reminders).insert(RemindersCompanion.insert(
            id: r.id, taskId: r.taskId, spec: r.spec, createdAt: stamp, updatedAt: stamp));
      }
      for (final c in b.completions) {
        await db.into(db.completions).insert(CompletionsCompanion.insert(
            id: c.id, taskId: c.taskId, completedAt: c.completedAt,
            dueDate: Value(c.dueDate), dueTime: Value(c.dueTime)));
      }
      for (final c in b.projectComments) {
        await db.into(db.projectComments).insert(ProjectCommentsCompanion.insert(
            id: c.id, projectId: c.projectId, body: c.body, createdAt: c.createdAt, updatedAt: stamp));
      }
      for (final e in b.settings.entries) {
        await db.into(db.settings).insert(SettingsCompanion.insert(key: e.key, value: e.value));
      }
      await db.ensureInbox();
    });
  }
}
