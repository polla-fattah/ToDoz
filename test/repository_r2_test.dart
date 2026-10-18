import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/core/backup.dart';
import 'package:taskflow/core/reminder.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';

// Wednesday 14 October 2026, 09:00.
final fixedNow = DateTime(2026, 10, 14, 9);

void main() {
  late AppDatabase db;
  late Repo repo;
  var clock = fixedNow;

  setUp(() async {
    clock = fixedNow;
    db = AppDatabase(NativeDatabase.memory());
    repo = Repo(db, clock: () => clock);
    await db.ensureInbox();
  });
  tearDown(() => db.close());

  Future<List<Task>> open() => repo.watchProjectTasks(inboxId).first;

  group('when fields', () {
    test('stores a time, a repeat, a deadline and reminders', () async {
      final id = await repo.addTask(
        title: 'Gym',
        dueDate: '2026-10-16',
        dueTime: '07:00',
        recurrence: 'every mon, fri at 7am',
        deadline: '2026-12-01',
        reminders: const [ReminderSpec.before(30), ReminderSpec.at(6 * 60)],
      );
      final t = (await repo.getTask(id))!;
      expect((t.dueDate, t.dueTime, t.recurrence, t.deadline), ('2026-10-16', '07:00', 'every mon, fri at 7am', '2026-12-01'));
      expect((await repo.watchReminders(id).first).map((r) => r.spec), ['30m', '06:00']);
    });

    test('rejects an invalid time, a time with no date, and an unreadable repeat', () async {
      expect(() => repo.addTask(title: 'x', dueDate: '2026-10-16', dueTime: '25:00'), throwsA(isA<RuleException>()));
      expect(() => repo.addTask(title: 'x', dueTime: '09:00'), throwsA(isA<RuleException>()));
      expect(() => repo.addTask(title: 'x', dueDate: '2026-10-16', recurrence: 'every blue moon'), throwsA(isA<RuleException>()));
      expect(() => repo.addTask(title: 'x', dueDate: '2026-02-31'), throwsA(isA<RuleException>()));
      expect(() => repo.addTask(title: 'x', deadline: 'soon'), throwsA(isA<RuleException>()));
    });

    test('a repeating task may be created with a time and no date (the repeat supplies it)', () async {
      final id = await repo.addTask(title: 'x', dueTime: '09:00', recurrence: 'every day');
      expect((await repo.getTask(id))!.recurrence, 'every day');
    });

    test('updateTask validates against the existing values', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-16');
      await repo.updateTask(id, dueTime: const Value('08:30'));
      expect((await repo.getTask(id))!.dueTime, '08:30');
      expect(() => repo.updateTask(id, dueDate: const Value(null)), throwsA(isA<RuleException>())); // time would be orphaned
      expect(() => repo.updateTask(id, recurrence: const Value('nonsense')), throwsA(isA<RuleException>()));
      await repo.updateTask(id, dueDate: const Value(null), dueTime: const Value(null));
      expect((await repo.getTask(id))!.dueDate, isNull);
    });

    test('Today and Upcoming order by time within a day, untimed last', () async {
      await repo.addTask(title: 'untimed', dueDate: '2026-10-14');
      await repo.addTask(title: 'late', dueDate: '2026-10-14', dueTime: '18:00');
      await repo.addTask(title: 'early', dueDate: '2026-10-14', dueTime: '08:00');
      expect((await repo.watchToday('2026-10-14').first).map((t) => t.title), ['early', 'late', 'untimed']);
      expect((await repo.watchScheduled().first).map((t) => t.title), ['early', 'late', 'untimed']);
    });
  });

  group('completing a repeating task (FR-R7)', () {
    test('moves to the next date instead of completing, and logs the completion', () async {
      final id = await repo.addTask(title: 'Water plants', dueDate: '2026-10-14', dueTime: '08:00', recurrence: 'every day');
      final o = await repo.completeTask(id);
      expect(o.wasRescheduled, isTrue);
      expect(o.changedIds, isEmpty);
      expect(o.nextDueDate, '2026-10-15');
      final t = (await repo.getTask(id))!;
      expect((t.dueDate, t.dueTime, t.completedAt), ('2026-10-15', '08:00', null));
      expect(await open(), hasLength(1));
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 1);
    });

    test('an overdue repeat lands on a future date', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-10', recurrence: 'every day');
      await repo.completeTask(id);
      expect((await repo.getTask(id))!.dueDate, '2026-10-15');
    });

    test('every! counts from the day it is finished', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-01', recurrence: 'every! 2 months');
      await repo.completeTask(id);
      expect((await repo.getTask(id))!.dueDate, '2026-12-14');
    });

    test('a time written in the repeat sets the new time', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-16', dueTime: '09:00', recurrence: 'every fri at 20:00');
      await repo.completeTask(id);
      final t = (await repo.getTask(id))!;
      expect((t.dueDate, t.dueTime), ('2026-10-23', '20:00'));
    });

    test('finished sub-tasks reopen, and Undo restores everything', () async {
      final parent = await repo.addTask(title: 'parent', dueDate: '2026-10-14', recurrence: 'every week');
      final child = await repo.addTask(title: 'child', parentId: parent);
      await repo.completeTask(child);
      final o = await repo.completeTask(parent);
      expect(o.reopenedSubtaskIds, [child]);
      expect((await repo.getTask(child))!.completedAt, isNull);
      expect((await repo.getTask(parent))!.dueDate, '2026-10-21');

      await repo.undoCompletion(o);
      expect((await repo.getTask(parent))!.dueDate, '2026-10-14');
      expect((await repo.getTask(child))!.completedAt, isNotNull);
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 1); // only the child's own completion remains
    });

    test('a repeat that has ended completes the task for good', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-14', recurrence: 'every day until oct 14');
      final o = await repo.completeTask(id);
      expect(o.wasRescheduled, isFalse);
      expect(o.changedIds, [id]);
      expect((await repo.getTask(id))!.completedAt, isNotNull);
    });

    test('completing clears a snooze', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-14', recurrence: 'every day');
      await repo.snoozeTask(id, DateTime(2026, 10, 14, 10));
      await repo.completeTask(id);
      expect((await repo.getTask(id))!.snoozedUntil, isNull);
    });
  });

  group('skipping and stopping', () {
    test('skip moves on without logging a completion, and Undo restores', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-14', dueTime: '08:00', recurrence: 'every day');
      final o = (await repo.skipOccurrence(id))!;
      expect((await repo.getTask(id))!.dueDate, '2026-10-15');
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 0);
      await repo.undoCompletion(o);
      final t = (await repo.getTask(id))!;
      expect((t.dueDate, t.dueTime), ('2026-10-14', '08:00'));
    });

    test('skip on a task that does not repeat does nothing', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-14');
      expect(await repo.skipOccurrence(id), isNull);
    });

    test('stopRecurrence keeps the date but ends the repeat', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-14', recurrence: 'every day');
      await repo.stopRecurrence(id);
      final t = (await repo.getTask(id))!;
      expect((t.recurrence, t.dueDate), (null, '2026-10-14'));
      final o = await repo.completeTask(id);
      expect(o.wasRescheduled, isFalse);
    });
  });

  group('completion history', () {
    test('every completion is logged and Undo removes its row', () async {
      final id = await repo.addTask(title: 'x');
      final o = await repo.completeTask(id);
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 1);
      await repo.undoCompletion(o);
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 0);
      expect(await open(), hasLength(1));
    });

    test('reopening a completed task removes its last completion', () async {
      final id = await repo.addTask(title: 'x');
      await repo.completeTask(id);
      await repo.reopenTask(id);
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 0);
      expect((await repo.getTask(id))!.completedAt, isNull);
    });

    test('completing with sub-tasks logs one completion for the parent', () async {
      final p = await repo.addTask(title: 'p');
      await repo.addTask(title: 'c', parentId: p);
      final o = await repo.completeTask(p, withSubtasks: true);
      expect(o.changedIds, hasLength(2));
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 1);
    });

    test('completing an already completed task does nothing', () async {
      final id = await repo.addTask(title: 'x');
      await repo.completeTask(id);
      final again = await repo.completeTask(id);
      expect(again.changedIds, isEmpty);
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 1);
    });
  });

  group('reminders and snooze', () {
    test('add, dedupe, remove', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-15', dueTime: '10:00');
      await repo.addReminder(id, const ReminderSpec.before(30));
      await repo.addReminder(id, const ReminderSpec.before(30)); // duplicate ignored
      await repo.addReminder(id, const ReminderSpec.at(8 * 60));
      final list = await repo.watchReminders(id).first;
      expect(list.map((r) => r.spec), ['30m', '08:00']);
      await repo.removeReminder(list.first.id);
      expect((await repo.watchReminders(id).first).map((r) => r.spec), ['08:00']);
    });

    test('reminderTasks returns dated and snoozed open tasks with their reminders', () async {
      final dated = await repo.addTask(title: 'dated', dueDate: '2026-10-15', dueTime: '10:00', reminders: const [ReminderSpec.before(60)]);
      final plain = await repo.addTask(title: 'plain');
      final snoozed = await repo.addTask(title: 'snoozed');
      await repo.snoozeTask(snoozed, DateTime(2026, 10, 14, 9, 30));
      final done = await repo.addTask(title: 'done', dueDate: '2026-10-15');
      await repo.completeTask(done);

      final list = await repo.reminderTasks();
      expect(list.map((t) => t.id).toSet(), {dated, snoozed});
      expect(list.firstWhere((t) => t.id == dated).reminders, [const ReminderSpec.before(60)]);
      expect(list.firstWhere((t) => t.id == snoozed).snoozedUntil, DateTime(2026, 10, 14, 9, 30));
      expect(list.any((t) => t.id == plain), isFalse);
    });

    test('reminderTasks feeds upcomingFires end to end', () async {
      await repo.addTask(title: 'Call', dueDate: '2026-10-15', dueTime: '10:00');
      final fires = upcomingFires(await repo.reminderTasks(), fixedNow);
      expect(fires.single.at, DateTime(2026, 10, 15, 9, 30));
    });

    test('a change signal fires when a task changes', () async {
      final seen = <int>[];
      final sub = repo.watchReminderChanges().listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final before = seen.length;
      await repo.addTask(title: 'x', dueDate: '2026-10-15');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await sub.cancel();
      expect(seen.length, greaterThan(before));
      expect(seen.toSet().length, greaterThan(1));
    });
  });

  group('duplicate a task (FR-T6)', () {
    test('copies fields, labels, reminders and sub-tasks, but is open and separate', () async {
      final label = await repo.createLabel('work');
      final id = await repo.addTask(
        title: 'Report', description: 'notes', priority: 2, dueDate: '2026-10-20', dueTime: '09:00',
        recurrence: 'every week', deadline: '2026-11-01', labelIds: [label], reminders: const [ReminderSpec.before(15)],
      );
      await repo.addTask(title: 'step 1', parentId: id);
      await repo.addComment(id, 'a comment');

      final copy = await repo.duplicateTask(id, withComments: true);
      expect(copy, isNot(id));
      final t = (await repo.getTask(copy))!;
      expect((t.title, t.description, t.priority, t.dueDate, t.dueTime, t.recurrence, t.deadline, t.completedAt),
          ('Report', 'notes', 2, '2026-10-20', '09:00', 'every week', '2026-11-01', null));
      expect((await repo.watchLabelLinks().first).where((l) => l.taskId == copy).single.labelId, label);
      expect((await repo.watchReminders(copy).first).single.spec, '15m');
      expect((await repo.watchChildren(copy).first).single.title, 'step 1');
      expect((await repo.watchComments(copy).first).single.body, 'a comment');
      expect((await repo.watchChildren(id).first), hasLength(1)); // original untouched
    });

    test('without sub-tasks and comments they are left out', () async {
      final id = await repo.addTask(title: 'x');
      await repo.addTask(title: 'kid', parentId: id);
      await repo.addComment(id, 'c');
      final copy = await repo.duplicateTask(id, withSubtasks: false);
      expect(await repo.watchChildren(copy).first, isEmpty);
      expect(await repo.watchComments(copy).first, isEmpty);
    });
  });

  group('project comments (FR-P10)', () {
    test('add, edit, delete, separate from task comments', () async {
      final p = await repo.createProject(name: 'P');
      final c = await repo.addProjectComment(p, ' plan: ship in Q4 ');
      expect((await repo.watchProjectComments(p).first).single.body, 'plan: ship in Q4');
      await repo.editProjectComment(c, 'plan: ship in Q1');
      expect((await repo.watchProjectComments(p).first).single.body, 'plan: ship in Q1');
      await repo.deleteProjectComment(c);
      expect(await repo.watchProjectComments(p).first, isEmpty);
      expect(() => repo.addProjectComment(p, ' '), throwsA(isA<RuleException>()));
    });
  });

  group('Quick Add end to end', () {
    test('a line with a time, repeat, deadline, reminder and priority', () async {
      final plan = await repo.planQuickAdd('Gym every mon, fri at 7am p2 {dec 1} !30m');
      final id = await repo.addFromPlan(plan);
      final t = (await repo.getTask(id))!;
      expect((t.title, t.priority, t.dueDate, t.dueTime, t.recurrence, t.deadline),
          ('Gym', 2, '2026-10-16', '07:00', 'every mon, fri at 7am', '2026-12-01'));
      expect((await repo.watchReminders(id).first).single.spec, '30m');
    });

    test('the sheet can replace the typed fields', () async {
      final plan = await repo.planQuickAdd('Call tomorrow at 4pm');
      final id = await repo.addFromPlan(plan, fields: const TaskFields(dueDate: '2026-12-01', priority: 1));
      final t = (await repo.getTask(id))!;
      expect((t.dueDate, t.dueTime, t.priority), ('2026-12-01', null, 1));
    });

    test('extra labels picked in the sheet are added', () async {
      final l = await repo.createLabel('home');
      final id = await repo.addFromPlan(await repo.planQuickAdd('Fix tap'), extraLabelIds: [l]);
      expect((await repo.watchLabelLinks().first).single.taskId, id);
    });
  });

  group('backup carries R2 data', () {
    test('export then restore keeps times, repeats, deadlines, reminders, completions and notes', () async {
      final p = await repo.createProject(name: 'P');
      await repo.addProjectComment(p, 'note');
      final id = await repo.addTask(
        title: 'Gym', projectId: p, dueDate: '2026-10-16', dueTime: '07:00', recurrence: 'every fri',
        deadline: '2026-12-01', reminders: const [ReminderSpec.before(10)],
      );
      await repo.completeTask(id);

      final json = (await repo.exportBundle()).toJsonString();
      final db2 = AppDatabase(NativeDatabase.memory());
      addTearDown(db2.close);
      final repo2 = Repo(db2, clock: () => fixedNow);
      await repo2.replaceAll(Bundle.parse(json));

      final t = (await repo2.getTask(id))!;
      expect((t.dueDate, t.dueTime, t.recurrence, t.deadline), ('2026-10-23', '07:00', 'every fri', '2026-12-01'));
      expect((await repo2.watchReminders(id).first).single.spec, '10m');
      expect(await repo2.completedOn(DateTime(2026, 10, 14)), 1);
      expect((await repo2.watchProjectComments(p).first).single.body, 'note');
    });

    test('an old backup without the new keys still restores', () async {
      final json = (await repo.exportBundle()).toJsonString();
      final stripped = json
          .replaceAll(RegExp(r'"reminders": \[\s*\],?'), '')
          .replaceAll(RegExp(r'"completions": \[\s*\],?'), '')
          .replaceAll(RegExp(r'"projectComments": \[\s*\]'), '"x": 1');
      expect(() => Bundle.parse(stripped), returnsNormally);
    });

    test('a reminder pointing at a missing task is rejected', () async {
      final id = await repo.addTask(title: 'x');
      await repo.addReminder(id, const ReminderSpec.before(5));
      final bundle = await repo.exportBundle();
      final broken = bundle.toJsonString().replaceFirst('"taskId": "$id"', '"taskId": "ghost"');
      expect(() => Bundle.parse(broken), throwsFormatException);
    });
  });

  group('permanent delete cleans R2 data', () {
    test('reminders and completions go with the task', () async {
      final id = await repo.addTask(title: 'x', dueDate: '2026-10-15', reminders: const [ReminderSpec.at(480)]);
      await repo.completeTask(id);
      await repo.deleteTaskForever(id);
      expect((await db.select(db.reminders).get()), isEmpty);
      expect((await db.select(db.completions).get()), isEmpty);
    });
  });

  group('database upgrade', () {
    test('a version-1 database upgrades without losing data', () async {
      final dir = await Directory.systemTemp.createTemp('taskflow_migrate');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/tasks.sqlite');

      // Build a current database, then reshape it to look like version 1.
      final old = AppDatabase(NativeDatabase(file));
      final oldRepo = Repo(old, clock: () => fixedNow);
      await old.ensureInbox();
      final id = await oldRepo.addTask(title: 'written before the upgrade', priority: 2, dueDate: '2026-10-20');
      for (final col in ['due_time', 'recurrence', 'deadline', 'snoozed_until', 'duration_minutes']) {
        await old.customStatement('ALTER TABLE tasks DROP COLUMN $col');
      }
      await old.customStatement('ALTER TABLE projects DROP COLUMN view_options');
      for (final t in ['reminders', 'completions', 'project_comments', 'filters']) {
        await old.customStatement('DROP TABLE $t');
      }
      await old.customStatement('PRAGMA user_version = 1');
      await old.close();

      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final repo2 = Repo(upgraded, clock: () => fixedNow);
      final t = (await repo2.getTask(id))!;
      expect((t.title, t.priority, t.dueDate, t.dueTime, t.recurrence), ('written before the upgrade', 2, '2026-10-20', null, null));

      // The new features work on the upgraded file.
      await repo2.updateTask(id, dueTime: const Value('09:00'), recurrence: const Value('every day'));
      await repo2.addReminder(id, const ReminderSpec.before(30));
      await repo2.completeTask(id);
      expect((await repo2.getTask(id))!.dueDate, '2026-10-21');
      expect(await repo2.completedOn(DateTime(2026, 10, 14)), 1);
    });
  });
}
