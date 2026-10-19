import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow_core/backup.dart';
import 'package:taskflow_core/view_options.dart';
import 'rewind_util.dart';
import 'package:taskflow/data/activity_triggers.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/sync_triggers.dart';

// Wednesday 14 October 2026, 09:00.
final fixedNow = DateTime(2026, 10, 14, 9);

void main() {
  late AppDatabase db;
  late Repo repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repo(db, clock: () => fixedNow);
    await db.ensureInbox();
  });
  tearDown(() => db.close());

  group('duration (FR-D3)', () {
    test('stored on create and update, validated', () async {
      final id = await repo.addTask(title: 'Write', durationMinutes: 90);
      expect((await repo.getTask(id))!.durationMinutes, 90);
      await repo.updateTask(id, durationMinutes: const Value(14400));
      expect((await repo.getTask(id))!.durationMinutes, 14400);
      await repo.updateTask(id, durationMinutes: const Value(null));
      expect((await repo.getTask(id))!.durationMinutes, isNull);
      expect(() => repo.addTask(title: 'x', durationMinutes: 0), throwsA(isA<RuleException>()));
      expect(() => repo.updateTask(id, durationMinutes: const Value(20000)), throwsA(isA<RuleException>()));
    });
    test('duplicate copies it', () async {
      final id = await repo.addTask(title: 'Write', durationMinutes: 45);
      final copy = await repo.duplicateTask(id);
      expect((await repo.getTask(copy))!.durationMinutes, 45);
    });
  });

  group('saved filters (FR-F1)', () {
    test('create, list in order, rename, favorite, delete and restore', () async {
      final a = await repo.createFilter(name: ' Urgent ', query: 'p1 & overdue', color: 0xFFD1453B);
      final b = await repo.createFilter(name: 'Someday', query: 'no date');
      expect((await repo.watchFilters().first).map((f) => f.name), ['Urgent', 'Someday']);
      await repo.updateFilter(b, name: 'Maybe', isFavorite: true);
      final f = (await repo.getFilter(b))!;
      expect((f.name, f.isFavorite), ('Maybe', true));
      await repo.reorderFilters([b, a]);
      expect((await repo.watchFilters().first).map((f) => f.id), [b, a]);
      await repo.deleteFilter(a);
      expect((await repo.watchFilters().first).map((f) => f.id), [b]);
      await repo.restoreFilter(a);
      expect(await repo.watchFilters().first, hasLength(2));
    });

    test('a bad query or empty name is refused with the filter error', () async {
      expect(() => repo.createFilter(name: 'x', query: 'blah'), throwsA(isA<RuleException>()));
      expect(() => repo.createFilter(name: ' ', query: 'today'), throwsA(isA<RuleException>()));
      final id = await repo.createFilter(name: 'ok', query: 'today');
      expect(() => repo.updateFilter(id, query: '#NoSuchProject'), throwsA(isA<RuleException>()));
      expect((await repo.getFilter(id))!.query, 'today');
    });

    test('a query can refer to projects and sections that exist', () async {
      final p = await repo.createProject(name: 'Work');
      await repo.createSection(p, 'Backlog');
      final id = await repo.createFilter(name: 'W', query: '#Work & /Backlog');
      expect((await repo.getFilter(id))!.query, '#Work & /Backlog');
    });

    test('filterEnv exposes the names and the clock', () async {
      final p = await repo.createProject(name: 'Work');
      await repo.createSection(p, 'Backlog');
      final env = await repo.filterEnv();
      expect(env.now, fixedNow);
      expect(env.projects.map((p) => p.name), containsAll(['Inbox', 'Work']));
      expect(env.sections.single.name, 'Backlog');
    });
  });

  group('view options per project (FR-P11)', () {
    test('saved, read back, and a new project starts with defaults', () async {
      final p = await repo.createProject(name: 'P');
      expect(ViewOptions.decode((await repo.getProject(p))!.viewOptions), const ViewOptions());
      const o = ViewOptions(layout: ViewLayout.board, sort: SortBy.priority, showCompleted: true);
      await repo.setProjectViewOptions(p, o);
      expect(ViewOptions.decode((await repo.getProject(p))!.viewOptions), o);
    });
    test('filters keep their own options', () async {
      final id = await repo.createFilter(name: 'F', query: 'today');
      await repo.updateFilter(id, viewOptions: const ViewOptions(layout: ViewLayout.calendar));
      expect(ViewOptions.decode((await repo.getFilter(id))!.viewOptions).layout, ViewLayout.calendar);
    });
    test('a project view can include completed tasks', () async {
      final a = await repo.addTask(title: 'open');
      final b = await repo.addTask(title: 'done');
      await repo.completeTask(b);
      expect((await repo.watchProjectTasks(inboxId).first).map((t) => t.id), [a]);
      expect((await repo.watchProjectTasks(inboxId, includeCompleted: true).first), hasLength(2));
    });
  });

  group('drag and drop onto a group (FR-V4, FR-V5)', () {
    test('a section column sets the section, and "no section" clears it', () async {
      final p = await repo.createProject(name: 'P');
      final s1 = await repo.createSection(p, 'Todo');
      final s2 = await repo.createSection(p, 'Doing');
      final t = await repo.addTask(title: 't', projectId: p, sectionId: s1);
      await repo.moveToGroup(t, GroupKey(Grouping.section, s2));
      expect((await repo.getTask(t))!.sectionId, s2);
      await repo.moveToGroup(t, const GroupKey(Grouping.section));
      expect((await repo.getTask(t))!.sectionId, isNull);
    });
    test('a priority column sets the priority', () async {
      final t = await repo.addTask(title: 't');
      await repo.moveToGroup(t, const GroupKey(Grouping.priority, '1'));
      expect((await repo.getTask(t))!.priority, 1);
    });
    test('a date column sets the due date; "no date" clears date, time and repeat; overdue does nothing', () async {
      final t = await repo.addTask(title: 't', dueDate: '2026-10-20', dueTime: '09:00', recurrence: 'every day');
      await repo.moveToGroup(t, const GroupKey(Grouping.date, '2026-10-25'));
      var task = (await repo.getTask(t))!;
      expect((task.dueDate, task.dueTime, task.recurrence), ('2026-10-25', '09:00', 'every day')); // time and repeat kept
      await repo.moveToGroup(t, const GroupKey(Grouping.date, 'overdue'));
      expect((await repo.getTask(t))!.dueDate, '2026-10-25');
      await repo.moveToGroup(t, const GroupKey(Grouping.date));
      task = (await repo.getTask(t))!;
      expect((task.dueDate, task.dueTime, task.recurrence), (null, null, null));
    });
    test('a label column adds the label', () async {
      final l = await repo.createLabel('home');
      final t = await repo.addTask(title: 't');
      await repo.moveToGroup(t, GroupKey(Grouping.label, l));
      await repo.moveToGroup(t, GroupKey(Grouping.label, l)); // twice: no duplicate
      expect((await repo.watchLabelLinks().first).where((x) => x.taskId == t), hasLength(1));
    });
    test('a project column moves the task and its sub-tasks', () async {
      final p = await repo.createProject(name: 'P');
      final t = await repo.addTask(title: 't');
      final kid = await repo.addTask(title: 'kid', parentId: t);
      await repo.moveToGroup(t, GroupKey(Grouping.project, p));
      expect((await repo.getTask(t))!.projectId, p);
      expect((await repo.getTask(kid))!.projectId, p);
    });
    test('dropping at a position saves the order', () async {
      final a = await repo.addTask(title: 'a');
      final b = await repo.addTask(title: 'b');
      final c = await repo.addTask(title: 'c');
      await repo.moveToGroup(c, const GroupKey(Grouping.none), orderedIdsInGroup: [c, a, b]);
      expect((await repo.watchProjectTasks(inboxId).first).map((t) => t.id), [c, a, b]);
    });
  });

  group('bulk actions on a selection (FR-T7)', () {
    test('priority, project, label', () async {
      final p = await repo.createProject(name: 'P');
      final l = await repo.createLabel('x');
      final ids = [await repo.addTask(title: 'a'), await repo.addTask(title: 'b')];
      await repo.bulkSetPriority(ids, 2);
      await repo.bulkMoveToProject(ids, p);
      await repo.bulkAddLabel(ids, l);
      await repo.bulkAddLabel(ids, l);
      for (final id in ids) {
        final t = (await repo.getTask(id))!;
        expect((t.priority, t.projectId), (2, p));
      }
      expect(await repo.watchLabelLinks().first, hasLength(2));
    });
    test('reschedule keeps times', () async {
      final a = await repo.addTask(title: 'a', dueDate: '2026-10-10', dueTime: '08:00');
      final b = await repo.addTask(title: 'b');
      await repo.rescheduleTasks([a, b], '2026-10-30');
      expect((await repo.getTask(a))!.dueTime, '08:00');
      expect((await repo.getTask(b))!.dueDate, '2026-10-30');
      expect(() => repo.rescheduleTasks([a], 'soon'), throwsA(isA<RuleException>()));
    });
    test('complete handles repeating tasks and Undo reverses all of them', () async {
      final plain = await repo.addTask(title: 'plain');
      final rep = await repo.addTask(title: 'rep', dueDate: '2026-10-14', recurrence: 'every day');
      final outcomes = await repo.bulkComplete([plain, rep]);
      expect((await repo.getTask(plain))!.completedAt, isNotNull);
      expect((await repo.getTask(rep))!.dueDate, '2026-10-15');
      await repo.bulkUndoComplete(outcomes);
      expect((await repo.getTask(plain))!.completedAt, isNull);
      expect((await repo.getTask(rep))!.dueDate, '2026-10-14');
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 0);
    });
    test('delete returns every id, sub-tasks included, so Undo can restore them', () async {
      final a = await repo.addTask(title: 'a');
      final kid = await repo.addTask(title: 'kid', parentId: a);
      final b = await repo.addTask(title: 'b');
      final all = await repo.bulkDelete([a, b]);
      expect(all.toSet(), {a, kid, b});
      expect(await repo.watchProjectTasks(inboxId).first, isEmpty);
      await repo.restoreTasks(all);
      expect(await repo.watchProjectTasks(inboxId).first, hasLength(3));
    });
  });

  group('search in comments (FR-F8)', () {
    test('finds tasks by comment text, including % and _', () async {
      final a = await repo.addTask(title: 'a');
      final b = await repo.addTask(title: 'b');
      await repo.addComment(a, 'Ask Sam about the invoice');
      await repo.addComment(b, '100% done_ish');
      expect(await repo.taskIdsWithCommentText('invoice'), {a});
      expect(await repo.taskIdsWithCommentText('INVOICE'), {a}); // LIKE is case-insensitive for ASCII
      expect(await repo.taskIdsWithCommentText('100%'), {b});
      expect(await repo.taskIdsWithCommentText('done_'), {b});
      expect(await repo.taskIdsWithCommentText('%'), {b}); // a literal percent, not "everything"
      expect(await repo.taskIdsWithCommentText('nothing'), isEmpty);
    });
    test('deleted comments are not searched', () async {
      final a = await repo.addTask(title: 'a');
      final c = await repo.addComment(a, 'secret');
      await repo.deleteComment(c);
      expect(await repo.taskIdsWithCommentText('secret'), isEmpty);
    });
  });

  group('backup carries R3 data', () {
    test('duration, view options and saved filters survive a restore', () async {
      final p = await repo.createProject(name: 'P');
      await repo.setProjectViewOptions(p, const ViewOptions(layout: ViewLayout.board, group: Grouping.priority));
      final id = await repo.addTask(title: 't', projectId: p, durationMinutes: 30);
      await repo.createFilter(name: 'F', query: 'p1 | p2', color: 0xFF112233);

      final json = (await repo.exportBundle()).toJsonString();
      final db2 = AppDatabase(NativeDatabase.memory());
      addTearDown(db2.close);
      final repo2 = Repo(db2, clock: () => fixedNow);
      await repo2.replaceAll(Bundle.parse(json));

      expect((await repo2.getTask(id))!.durationMinutes, 30);
      final opts = ViewOptions.decode((await repo2.getProject(p))!.viewOptions);
      expect((opts.layout, opts.group), (ViewLayout.board, Grouping.priority));
      final f = (await repo2.watchFilters().first).single;
      expect((f.name, f.query, f.color), ('F', 'p1 | p2', 0xFF112233));
    });
    test('an invalid duration in a backup is rejected', () async {
      final t = await repo.addTask(title: 't', durationMinutes: 30);
      final json = (await repo.exportBundle()).toJsonString().replaceFirst('"durationMinutes": 30', '"durationMinutes": 99999');
      expect(() => Bundle.parse(json), throwsFormatException);
      expect(t, isNotEmpty);
    });
  });

  group('database upgrade to version 3', () {
    test('a version-2 database upgrades without losing data', () async {
      final dir = await Directory.systemTemp.createTemp('taskflow_migrate3');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/tasks.sqlite');

      final old = AppDatabase(NativeDatabase(file));
      final oldRepo = Repo(old, clock: () => fixedNow);
      await old.ensureInbox();
      final id = await oldRepo.addTask(title: 'kept', dueDate: '2026-10-20', dueTime: '09:00', recurrence: 'every week');
      // Older versions had no sync triggers or tables: remove them before reshaping.
      for (final name in [...syncTriggerNames(), ...activityTriggerNames()]) {
        await old.customStatement('DROP TRIGGER IF EXISTS $name');
      }
      for (final t in ['sync_meta', 'outbox', 'field_clock']) {
        await old.customStatement('DROP TABLE IF EXISTS $t');
      }
      await dropVersion7(old);
      await old.customStatement('ALTER TABLE tasks DROP COLUMN duration_minutes');
      await old.customStatement('ALTER TABLE projects DROP COLUMN view_options');
      await old.customStatement('DROP TABLE filters');
      await old.customStatement('PRAGMA user_version = 2');
      await old.close();

      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final repo2 = Repo(upgraded, clock: () => fixedNow);
      final t = (await repo2.getTask(id))!;
      expect((t.title, t.dueTime, t.recurrence, t.durationMinutes), ('kept', '09:00', 'every week', null));
      await repo2.updateTask(id, durationMinutes: const Value(60));
      await repo2.setProjectViewOptions(inboxId, const ViewOptions(layout: ViewLayout.calendar));
      await repo2.createFilter(name: 'F', query: 'today');
      expect((await repo2.getTask(id))!.durationMinutes, 60);
    });
  });
}
