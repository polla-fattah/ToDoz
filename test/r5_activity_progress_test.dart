import 'package:drift/drift.dart' show CustomExpression, OrderingTerm, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow_core/backup.dart' show inboxId;
import 'package:taskflow_core/progress.dart';

final fixedNow = DateTime(2026, 10, 14, 9); // a Wednesday

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
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

  Future<List<ActivityEntry>> log() => (db.select(db.activity)..orderBy([(a) => OrderingTerm.asc(CustomExpression<int>('rowid'))])).get();
  Future<List<String>> events() async => [for (final e in await log()) '${e.event}${e.field == null ? '' : ':${e.field}'}'];

  group('the activity log records what was done', () {
    test('adding a task, then editing, moving and completing it', () async {
      final id = await repo.addTask(title: 'Write report');
      await repo.updateTask(id, title: 'Write the report', priority: 2);
      final p = await repo.createProject(name: 'Work');
      await repo.moveTask(id, projectId: p);
      await repo.completeTask(id);

      final seen = await events();
      expect(seen.take(3).toList()..sort(), ['add', 'edit:priority', 'edit:title'], reason: 'one update of two fields logs both');
      expect(seen.skip(3), ['add', 'move:project_id', 'complete']);
      final all = await log();
      final title = all.firstWhere((e) => e.field == 'title');
      expect((title.oldValue, title.newValue, title.title), ('Write report', 'Write the report', 'Write the report'));
      final move = all.firstWhere((e) => e.event == 'move');
      expect((move.oldValue, move.newValue), (inboxId, p));
      expect(all.last.projectId, p, reason: 'filterable by project');
      expect(all.where((e) => e.entityType == 'project').single.title, 'Work');
    });

    test('a completion is logged once, whether or not the task repeats, with no due-date noise', () async {
      final once = await repo.addTask(title: 'once', dueDate: '2026-10-14');
      final rep = await repo.addTask(title: 'weekly', dueDate: '2026-10-14', recurrence: 'every week');
      await db.customStatement('DELETE FROM activity');
      await repo.completeTask(once);
      await repo.completeTask(rep);
      expect(await events(), ['complete', 'complete']);
      expect((await repo.getTask(rep))!.dueDate, '2026-10-21');
    });

    test('delete and restore, and reopening', () async {
      final id = await repo.addTask(title: 'x');
      await repo.completeTask(id);
      await repo.reopenTask(id);
      await repo.deleteTask(id);
      await repo.restoreTasks([id]);
      expect(await events(), ['add', 'complete', 'uncomplete', 'delete', 'restore']);
    });

    test('changing something to the same value logs nothing', () async {
      final id = await repo.addTask(title: 'same', priority: 3);
      await db.customStatement('DELETE FROM activity');
      await repo.updateTask(id, title: 'same', priority: 3);
      expect(await events(), isEmpty);
    });

    test('restoring a backup does not fill the log with "added"', () async {
      await repo.addTask(title: 'kept');
      final bundle = await repo.exportBundle();
      await db.customStatement('DELETE FROM activity');
      await repo.replaceAll(bundle);
      expect(await events(), isEmpty);
      expect(await db.metaGet('log'), '1', reason: 'logging is back on afterwards');
    });

    test('filters by project and by kind', () async {
      final p = await repo.createProject(name: 'P');
      await repo.addTask(title: 'in inbox');
      final t = await repo.addTask(title: 'in p', projectId: p);
      await repo.completeTask(t);
      expect((await repo.watchActivity(projectId: p).first).map((e) => e.event), unorderedEquals(['add', 'complete', 'add']));
      expect((await repo.watchActivity(events: {'complete'}).first).map((e) => e.title), ['in p']);
    });
  });

  group('undo from the log', () {
    Future<ActivityEntry> latest(String event, {String? field}) async =>
        (await log()).lastWhere((e) => e.event == event && (field == null || e.field == field));

    test('a delete', () async {
      final id = await repo.addTask(title: 'oops');
      await repo.deleteTask(id);
      final e = await latest('delete');
      expect(await repo.canUndo(e), isTrue);
      await repo.undoActivity(e);
      expect((await repo.getTask(id))!.deletedAt, isNull);
      expect(await repo.canUndo(e), isFalse, reason: 'already undone');
    });

    test('a completion, and a reopen', () async {
      final id = await repo.addTask(title: 'done by mistake');
      await repo.completeTask(id);
      await repo.undoActivity(await latest('complete'));
      expect((await repo.getTask(id))!.completedAt, isNull);
      expect(await db.select(db.completions).get(), isEmpty);
      await repo.completeTask(id);
      await repo.reopenTask(id);
      await repo.undoActivity(await latest('uncomplete'));
      expect((await repo.getTask(id))!.completedAt, isNotNull);
    });

    test('completing a repeating task puts the old date back', () async {
      final id = await repo.addTask(title: 'gym', dueDate: '2026-10-14', dueTime: '07:00', recurrence: 'every day at 7am');
      await repo.completeTask(id);
      expect((await repo.getTask(id))!.dueDate, '2026-10-15');
      await repo.undoActivity(await latest('complete'));
      final t = (await repo.getTask(id))!;
      expect((t.dueDate, t.dueTime), ('2026-10-14', '07:00'));
      expect(await db.select(db.completions).get(), isEmpty);
    });

    test('an edit puts the old value back, but only while it is still the new value', () async {
      final id = await repo.addTask(title: 'first', priority: 3, dueDate: '2026-10-15');
      await repo.updateTask(id, title: 'second');
      await repo.updateTask(id, priority: 1);
      await repo.updateTask(id, dueDate: const Value(null));
      await repo.undoActivity(await latest('edit', field: 'title'));
      await repo.undoActivity(await latest('edit', field: 'priority'));
      await repo.undoActivity(await latest('edit', field: 'due_date'));
      final t = (await repo.getTask(id))!;
      expect((t.title, t.priority, t.dueDate), ('first', 3, '2026-10-15'));

      await repo.updateTask(id, title: 'third');
      final third = await latest('edit', field: 'title');
      await repo.updateTask(id, title: 'fourth');
      expect(await repo.canUndo(third), isFalse, reason: 'changed again since');
      expect(() => repo.undoActivity(third), throwsA(isA<RuleException>()));
    });

    test('a move, and an add', () async {
      final p = await repo.createProject(name: 'Elsewhere');
      final id = await repo.addTask(title: 'mover');
      await repo.moveTask(id, projectId: p);
      await repo.undoActivity(await latest('move'));
      expect((await repo.getTask(id))!.projectId, inboxId);
      await repo.undoActivity((await log()).firstWhere((e) => e.event == 'add' && e.entityType == 'task'));
      expect((await repo.getTask(id))!.deletedAt, isNotNull);
    });

    test('a project delete and a rename', () async {
      final p = await repo.createProject(name: 'Old name');
      await repo.updateProject(p, name: 'New name');
      await repo.undoActivity(await latest('edit', field: 'name'));
      expect((await repo.getProject(p))!.name, 'Old name');
      await repo.deleteProject(p, deleteTasks: false);
      await repo.undoActivity(await latest('delete'));
      expect((await repo.getProject(p))!.deletedAt, isNull);
    });
  });

  group('productivity from the database', () {
    test('completions, priorities and overdue tasks feed the numbers', () async {
      await repo.setSetting('x', 'y');
      final a = await repo.addTask(title: 'a', priority: 1, dueDate: '2026-10-14');
      final b = await repo.addTask(title: 'b', dueDate: '2026-10-10'); // overdue 4 days on the 14th
      await repo.completeTask(a);
      final p = await repo.watchProgress(const Goals(daily: 1, weekly: 0)).first;
      expect(p.doneOn(DateTime(2026, 10, 14)), 1);
      // a: 10 + 5 on time + 9 priority 1 = 24, +20 goal day, b is 4 days overdue: -1.
      expect(p.karmaPoints, 24 + 20 - 1);
      expect(p.dailyGoalReachedToday, isTrue);
      expect(b, isNotEmpty);
    });

    test('the stream updates when another task is completed', () async {
      final a = await repo.addTask(title: 'a');
      final b = await repo.addTask(title: 'b');
      final seen = <int>[];
      final sub = repo.watchProgress(const Goals(daily: 2, weekly: 0)).listen((p) => seen.add(p.doneOn(fixedNow)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await repo.completeTask(a);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await repo.completeTask(b);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(seen.last, 2);
      expect(seen, contains(1));
    });
  });
}
