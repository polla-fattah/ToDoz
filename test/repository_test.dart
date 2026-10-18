import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/core/backup.dart';
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

  Future<List<Task>> open(String projectId) => repo.watchProjectTasks(projectId).first;

  group('Inbox and tasks', () {
    test('a fresh database has the permanent Inbox', () async {
      final p = await repo.getProject(inboxId);
      expect(p, isNotNull);
      expect(p!.name, 'Inbox');
    });

    test('adds a task and lists it', () async {
      final id = await repo.addTask(title: '  Buy milk  ', priority: 2, dueDate: '2026-10-15');
      final t = (await open(inboxId)).single;
      expect(t.id, id);
      expect(t.title, 'Buy milk');
      expect(t.priority, 2);
      expect(t.dueDate, '2026-10-15');
      expect(t.createdAt, fixedNow);
    });

    test('rejects an empty or over-long title', () async {
      expect(() => repo.addTask(title: '   '), throwsA(isA<RuleException>()));
      expect(() => repo.addTask(title: 'x' * 501), throwsA(isA<RuleException>()));
    });

    test('new tasks go to the end of their list', () async {
      final a = await repo.addTask(title: 'a');
      final b = await repo.addTask(title: 'b');
      final c = await repo.addTask(title: 'c');
      expect((await open(inboxId)).map((t) => t.id), [a, b, c]);
    });

    test('completing removes it from the open list and archives it', () async {
      final id = await repo.addTask(title: 'x');
      clock = fixedNow.add(const Duration(hours: 1));
      final changed = await repo.setCompleted(id, true);
      expect(changed, [id]);
      expect(await open(inboxId), isEmpty);
      final done = await repo.watchCompleted().first;
      expect(done.single.completedAt, clock);
    });

    test('reopening puts it back, and an undo of completion is exact', () async {
      final id = await repo.addTask(title: 'x');
      final changed = await repo.setCompleted(id, true);
      await repo.reopenAll(changed);
      expect(await open(inboxId), hasLength(1));
    });

    test('completing an already completed task changes nothing', () async {
      final id = await repo.addTask(title: 'x');
      await repo.setCompleted(id, true);
      expect(await repo.setCompleted(id, true), isEmpty);
    });

    test('edits fields and labels', () async {
      final label = await repo.createLabel('reading');
      final id = await repo.addTask(title: 'x');
      await repo.updateTask(id, title: 'y', description: 'notes', priority: 1,
          dueDate: const Value('2026-11-01'), labelIds: [label]);
      final t = (await repo.getTask(id))!;
      expect((t.title, t.description, t.priority, t.dueDate), ('y', 'notes', 1, '2026-11-01'));
      expect((await repo.watchLabelLinks().first).single.labelId, label);
      await repo.updateTask(id, dueDate: const Value(null));
      expect((await repo.getTask(id))!.dueDate, isNull);
    });
  });

  group('views', () {
    test('Today holds overdue and due-today tasks, oldest first', () async {
      await repo.addTask(title: 'future', dueDate: '2026-10-20');
      await repo.addTask(title: 'today', dueDate: '2026-10-14');
      await repo.addTask(title: 'overdue', dueDate: '2026-10-10');
      await repo.addTask(title: 'no date');
      final titles = (await repo.watchToday('2026-10-14').first).map((t) => t.title);
      expect(titles, ['overdue', 'today']);
    });

    test('Upcoming lists every dated open task in date order', () async {
      await repo.addTask(title: 'b', dueDate: '2026-10-20');
      await repo.addTask(title: 'a', dueDate: '2026-10-15');
      await repo.addTask(title: 'none');
      expect((await repo.watchScheduled().first).map((t) => t.title), ['a', 'b']);
    });

    test('a label view lists only its open tasks', () async {
      final l = await repo.createLabel('work');
      final a = await repo.addTask(title: 'a', labelIds: [l]);
      await repo.addTask(title: 'b');
      final c = await repo.addTask(title: 'c', labelIds: [l]);
      await repo.setCompleted(c, true);
      expect((await repo.watchLabelTasks(l).first).map((t) => t.id), [a]);
    });

    test('completed archive can be limited to one project', () async {
      final p = await repo.createProject(name: 'P');
      final a = await repo.addTask(title: 'a', projectId: p);
      final b = await repo.addTask(title: 'b');
      await repo.setCompleted(a, true);
      await repo.setCompleted(b, true);
      expect(await repo.watchCompleted().first, hasLength(2));
      expect((await repo.watchCompleted(projectId: p).first).single.id, a);
    });

    test('rescheduleOverdue moves only overdue open tasks', () async {
      final late = await repo.addTask(title: 'late', dueDate: '2026-10-01');
      final today = await repo.addTask(title: 'today', dueDate: '2026-10-14');
      expect(await repo.rescheduleOverdue('2026-10-14', '2026-10-14'), 1);
      expect((await repo.getTask(late))!.dueDate, '2026-10-14');
      expect((await repo.getTask(today))!.dueDate, '2026-10-14');
    });

    test('counts completions on a given day', () async {
      final a = await repo.addTask(title: 'a');
      final b = await repo.addTask(title: 'b');
      await repo.completeTask(a);
      clock = fixedNow.add(const Duration(days: 1));
      await repo.completeTask(b);
      expect(await repo.completedOn(DateTime(2026, 10, 14)), 1);
      expect(await repo.completedOn(DateTime(2026, 10, 15)), 1);
    });
  });

  group('sub-tasks', () {
    test('a sub-task inherits its parent project and section', () async {
      final p = await repo.createProject(name: 'P');
      final s = await repo.createSection(p, 'Backlog');
      final parent = await repo.addTask(title: 'parent', projectId: p, sectionId: s);
      final child = await repo.addTask(title: 'child', parentId: parent);
      final t = (await repo.getTask(child))!;
      expect((t.projectId, t.sectionId, t.parentId), (p, s, parent));
    });

    test('nesting stops at four levels', () async {
      var id = await repo.addTask(title: 'L1');
      for (final n in [2, 3, 4]) {
        id = await repo.addTask(title: 'L$n', parentId: id);
      }
      expect(() => repo.addTask(title: 'L5', parentId: id), throwsA(isA<RuleException>()));
    });

    test('completing a parent can also complete its sub-tasks', () async {
      final parent = await repo.addTask(title: 'parent');
      final c1 = await repo.addTask(title: 'c1', parentId: parent);
      final c2 = await repo.addTask(title: 'c2', parentId: c1);
      expect((await repo.openDescendants(parent)).map((t) => t.id).toSet(), {c1, c2});
      final changed = await repo.setCompleted(parent, true, withSubtasks: true);
      expect(changed.toSet(), {parent, c1, c2});
      expect(await open(inboxId), isEmpty);
    });

    test('completing only the parent leaves sub-tasks open', () async {
      final parent = await repo.addTask(title: 'parent');
      final child = await repo.addTask(title: 'child', parentId: parent);
      await repo.setCompleted(parent, true);
      expect((await open(inboxId)).map((t) => t.id), [child]);
    });
  });

  group('moving tasks', () {
    test('moves a task with its sub-tasks to another project', () async {
      final p = await repo.createProject(name: 'P');
      final parent = await repo.addTask(title: 'parent');
      final child = await repo.addTask(title: 'child', parentId: parent);
      await repo.moveTask(parent, projectId: p);
      expect((await repo.getTask(parent))!.projectId, p);
      expect((await repo.getTask(child))!.projectId, p);
      expect((await repo.getTask(child))!.parentId, parent);
    });

    test('promotes a sub-task to top level', () async {
      final parent = await repo.addTask(title: 'parent');
      final child = await repo.addTask(title: 'child', parentId: parent);
      await repo.promoteToTopLevel(child);
      expect((await repo.getTask(child))!.parentId, isNull);
    });

    test('a task cannot go inside itself or its own sub-task', () async {
      final a = await repo.addTask(title: 'a');
      final b = await repo.addTask(title: 'b', parentId: a);
      expect(() => repo.moveTask(a, projectId: inboxId, parentId: a), throwsA(isA<RuleException>()));
      expect(() => repo.moveTask(a, projectId: inboxId, parentId: b), throwsA(isA<RuleException>()));
    });

    test('refuses a move that would nest deeper than four levels', () async {
      var chain = await repo.addTask(title: 'L1');
      for (final n in [2, 3]) {
        chain = await repo.addTask(title: 'L$n', parentId: chain);
      }
      final top = await repo.addTask(title: 'top');
      await repo.addTask(title: 'under top', parentId: top);
      expect(() => repo.moveTask(top, projectId: inboxId, parentId: chain), throwsA(isA<RuleException>()));
    });
  });

  group('trash and undo', () {
    test('deleting trashes the task and its sub-tasks; restoring brings them back', () async {
      final parent = await repo.addTask(title: 'parent');
      final child = await repo.addTask(title: 'child', parentId: parent);
      final ids = await repo.deleteTask(parent);
      expect(ids.toSet(), {parent, child});
      expect(await open(inboxId), isEmpty);
      expect(await repo.watchTrashedTasks().first, hasLength(2));
      await repo.restoreTasks(ids);
      expect(await open(inboxId), hasLength(2));
    });

    test('items older than 30 days are purged, newer ones kept', () async {
      final old = await repo.addTask(title: 'old');
      final recent = await repo.addTask(title: 'recent');
      await repo.deleteTask(old);
      clock = fixedNow.add(const Duration(days: 20));
      await repo.deleteTask(recent);
      clock = fixedNow.add(const Duration(days: 31));
      await repo.purgeOldTrash();
      expect(await repo.getTask(old), isNull);
      expect(await repo.getTask(recent), isNotNull);
    });

    test('a task restored into a deleted project goes to Inbox', () async {
      final p = await repo.createProject(name: 'P');
      final t = await repo.addTask(title: 't', projectId: p);
      final trashed = await repo.deleteProject(p, deleteTasks: true);
      expect(trashed, [t]);
      await repo.restoreTasks(trashed);
      expect((await repo.getTask(t))!.projectId, inboxId);
    });
  });

  group('projects', () {
    test('nest up to three levels', () async {
      final a = await repo.createProject(name: 'A');
      final b = await repo.createProject(name: 'B', parentId: a);
      final c = await repo.createProject(name: 'C', parentId: b);
      expect(() => repo.createProject(name: 'D', parentId: c), throwsA(isA<RuleException>()));
    });

    test('moving refuses loops and over-deep subtrees', () async {
      final a = await repo.createProject(name: 'A');
      final b = await repo.createProject(name: 'B', parentId: a);
      final x = await repo.createProject(name: 'X');
      final y = await repo.createProject(name: 'Y', parentId: x);
      expect(() => repo.moveProject(a, b), throwsA(isA<RuleException>()));
      expect(() => repo.moveProject(a, a), throwsA(isA<RuleException>()));
      final z = await repo.createProject(name: 'Z', parentId: y); // x > y > z
      expect(() => repo.moveProject(a, z), throwsA(isA<RuleException>())); // would be 5 deep
      await repo.moveProject(b, x); // x > b fine
      expect((await repo.getProject(b))!.parentId, x);
    });

    test('deleting moves tasks to Inbox and lifts sub-projects', () async {
      final a = await repo.createProject(name: 'A');
      final b = await repo.createProject(name: 'B', parentId: a);
      final t = await repo.addTask(title: 't', projectId: a);
      await repo.deleteProject(a, deleteTasks: false);
      expect((await repo.getTask(t))!.projectId, inboxId);
      expect((await repo.getProject(b))!.parentId, isNull);
      expect((await repo.watchProjects().first).map((p) => p.id), isNot(contains(a)));
      expect(await repo.watchTrashedProjects().first, hasLength(1));
    });

    test('the Inbox cannot be deleted or moved', () async {
      expect(() => repo.deleteProject(inboxId, deleteTasks: false), throwsA(isA<RuleException>()));
      expect(() => repo.moveProject(inboxId, null), throwsA(isA<RuleException>()));
    });

    test('archive hides a project from the active list', () async {
      final a = await repo.createProject(name: 'A');
      await repo.updateProject(a, isArchived: true);
      expect((await repo.watchProjects().first).map((p) => p.id), isNot(contains(a)));
      expect((await repo.watchProjects(includeArchived: true).first).map((p) => p.id), contains(a));
    });

    test('favorites and rename', () async {
      final a = await repo.createProject(name: 'A');
      await repo.updateProject(a, name: 'Alpha', isFavorite: true);
      final p = (await repo.getProject(a))!;
      expect((p.name, p.isFavorite), ('Alpha', true));
      expect(() => repo.updateProject(a, name: ' '), throwsA(isA<RuleException>()));
    });

    test('duplicating copies sections, tasks, sub-tasks and labels', () async {
      final p = await repo.createProject(name: 'P');
      final s = await repo.createSection(p, 'Backlog');
      final l = await repo.createLabel('x');
      final parent = await repo.addTask(title: 'parent', projectId: p, sectionId: s, labelIds: [l]);
      await repo.addTask(title: 'child', parentId: parent);
      final copy = await repo.duplicateProject(p);
      final tasks = await open(copy);
      expect(tasks.map((t) => t.title).toSet(), {'parent', 'child'});
      final newParent = tasks.firstWhere((t) => t.title == 'parent');
      final newChild = tasks.firstWhere((t) => t.title == 'child');
      expect(newChild.parentId, newParent.id);
      final sections = await repo.watchSections(copy).first;
      expect(sections.single.name, 'Backlog');
      expect(newParent.sectionId, sections.single.id);
      expect(sections.single.id, isNot(s));
    });
  });

  group('sections', () {
    test('create in order, reorder, rename, collapse', () async {
      final p = await repo.createProject(name: 'P');
      final a = await repo.createSection(p, 'A');
      final b = await repo.createSection(p, 'B');
      final c = await repo.createSection(p, 'C');
      expect((await repo.watchSections(p).first).map((s) => s.name), ['A', 'B', 'C']);
      await repo.reorderSections([c, a, b]);
      expect((await repo.watchSections(p).first).map((s) => s.name), ['C', 'A', 'B']);
      await repo.updateSection(a, name: 'Alpha', isCollapsed: true);
      final alpha = (await repo.watchSections(p).first).firstWhere((s) => s.id == a);
      expect((alpha.name, alpha.isCollapsed), ('Alpha', true));
    });

    test('deleting a section keeps its tasks', () async {
      final p = await repo.createProject(name: 'P');
      final s = await repo.createSection(p, 'S');
      final t = await repo.addTask(title: 't', projectId: p, sectionId: s);
      await repo.deleteSection(s);
      expect((await repo.getTask(t))!.sectionId, isNull);
      expect(await repo.watchSections(p).first, isEmpty);
    });
  });

  group('labels', () {
    test('names are unique ignoring case and a leading % or @', () async {
      final a = await repo.createLabel('Reading');
      expect(await repo.createLabel('reading'), a);
      expect(await repo.createLabel('@READING'), a);
    });

    test('renaming updates every task at once and refuses a clash', () async {
      final a = await repo.createLabel('a');
      final b = await repo.createLabel('b');
      final t = await repo.addTask(title: 't', labelIds: [a]);
      await repo.updateLabel(a, name: 'alpha');
      expect((await repo.watchLabels().first).map((l) => l.name), contains('alpha'));
      expect((await repo.watchLabelLinks().first).single.taskId, t);
      expect(() => repo.updateLabel(b, name: 'ALPHA'), throwsA(isA<RuleException>()));
    });

    test('deleting removes it from tasks', () async {
      final a = await repo.createLabel('a');
      await repo.addTask(title: 't', labelIds: [a]);
      await repo.deleteLabel(a);
      expect(await repo.watchLabelLinks().first, isEmpty);
    });

    test('merging moves tasks and avoids duplicates', () async {
      final a = await repo.createLabel('a');
      final b = await repo.createLabel('b');
      final t1 = await repo.addTask(title: 't1', labelIds: [a]);
      final t2 = await repo.addTask(title: 't2', labelIds: [a, b]);
      await repo.mergeLabels(a, b);
      final links = await repo.watchLabelLinks().first;
      expect(links.map((l) => (l.taskId, l.labelId)).toSet(), {(t1, b), (t2, b)});
      expect((await repo.watchLabels().first).map((l) => l.id), [b]);
    });
  });

  group('comments', () {
    test('add, edit, delete', () async {
      final t = await repo.addTask(title: 't');
      final c = await repo.addComment(t, ' hello ');
      expect((await repo.watchComments(t).first).single.body, 'hello');
      await repo.editComment(c, 'hi');
      expect((await repo.watchComments(t).first).single.body, 'hi');
      await repo.deleteComment(c);
      expect(await repo.watchComments(t).first, isEmpty);
      expect(() => repo.addComment(t, '  '), throwsA(isA<RuleException>()));
    });
  });

  group('Quick Add', () {
    test('resolves project, section and labels that exist', () async {
      final p = await repo.createProject(name: 'Work & Research');
      final s = await repo.createSection(p, 'In Progress');
      final l = await repo.createLabel('reading');
      final plan = await repo.planQuickAdd('Review paper tomorrow p1 %reading #"Work & Research" /"In Progress"');
      expect(plan.hasUnknown, isFalse);
      final id = await repo.addFromPlan(plan);
      final t = (await repo.getTask(id))!;
      expect(t.title, 'Review paper');
      expect(t.priority, 1);
      expect(t.dueDate, '2026-10-15');
      expect((t.projectId, t.sectionId), (p, s));
      expect((await repo.watchLabelLinks().first).single.labelId, l);
    });

    test('matches a project by its hyphenated name', () async {
      final p = await repo.createProject(name: 'Work Research');
      final plan = await repo.planQuickAdd('x #work-research');
      expect(plan.projectId, p);
    });

    test('reports unknown names instead of dropping them (FR-Q5)', () async {
      final plan = await repo.planQuickAdd('Plan #holiday /flights @travel');
      expect(plan.unknownProject, 'holiday');
      expect(plan.unknownLabels, ['travel']);
      expect(plan.hasUnknown, isTrue);
    });

    test('createMissing creates the project, section and labels', () async {
      final plan = await repo.planQuickAdd('Plan #holiday /flights @travel');
      final id = await repo.addFromPlan(plan, createMissing: true);
      final t = (await repo.getTask(id))!;
      final project = (await repo.getProject(t.projectId))!;
      expect(project.name, 'holiday');
      expect((await repo.watchSections(project.id).first).single.name, 'flights');
      expect(t.sectionId, isNotNull);
      expect((await repo.watchLabels().first).single.name, 'travel');
    });

    test('without createMissing the unknowns are dropped from the task', () async {
      final plan = await repo.planQuickAdd('Plan #holiday @travel');
      final id = await repo.addFromPlan(plan);
      expect((await repo.getTask(id))!.projectId, inboxId);
      expect(await repo.watchLabelLinks().first, isEmpty);
    });

    test('a manually chosen date overrides the parsed one (FR-Q4)', () async {
      final plan = await repo.planQuickAdd('Call tomorrow');
      final id = await repo.addFromPlan(plan, fields: const TaskFields(dueDate: '2026-12-01'));
      expect((await repo.getTask(id))!.dueDate, '2026-12-01');
    });

    test('the default project is used when none is typed', () async {
      final p = await repo.createProject(name: 'P');
      final plan = await repo.planQuickAdd('Do thing', defaultProjectId: p);
      expect(plan.projectId, p);
    });
  });

  group('backup and restore', () {
    Future<void> seed() async {
      final p = await repo.createProject(name: 'P', parentId: null);
      final s = await repo.createSection(p, 'S');
      final l = await repo.createLabel('l');
      final t = await repo.addTask(title: 'parent', projectId: p, sectionId: s, labelIds: [l], dueDate: '2026-10-20', priority: 2);
      await repo.addTask(title: 'child', parentId: t);
      await repo.addComment(t, 'note');
      await repo.setSetting('dailyGoal', '9');
    }

    test('export then restore on an empty database reproduces everything', () async {
      await seed();
      final bundle = await repo.exportBundle();
      final json = bundle.toJsonString();

      final db2 = AppDatabase(NativeDatabase.memory());
      addTearDown(db2.close);
      final repo2 = Repo(db2, clock: () => fixedNow);
      await repo2.replaceAll(Bundle.parse(json));

      final again = await repo2.exportBundle();
      expect(again.projects.map((p) => p.id).toSet(), bundle.projects.map((p) => p.id).toSet());
      expect(again.tasks.map((t) => t.title).toSet(), {'parent', 'child'});
      expect(again.tasks.firstWhere((t) => t.title == 'parent').labelIds, hasLength(1));
      expect(again.tasks.firstWhere((t) => t.title == 'child').parentId,
          again.tasks.firstWhere((t) => t.title == 'parent').id);
      expect(again.comments.single.body, 'note');
      expect(again.settings['dailyGoal'], '9');
    });

    test('trashed items are not exported', () async {
      final t = await repo.addTask(title: 'gone');
      await repo.deleteTask(t);
      expect((await repo.exportBundle()).tasks, isEmpty);
    });

    test('a failing restore leaves the existing data untouched', () async {
      await repo.addTask(title: 'keep me');
      final bad = Bundle(
        projects: [ProjectRec(id: inboxId, name: 'Inbox', color: 0xFF000000)],
        sections: const [],
        labels: const [],
        tasks: [
          TaskRec(id: 'dup', title: 'a', projectId: inboxId),
          TaskRec(id: 'dup', title: 'b', projectId: inboxId), // primary key clash
        ],
        comments: const [],
      );
      await expectLater(repo.replaceAll(bad), throwsA(anything));
      expect((await open(inboxId)).map((t) => t.title), ['keep me']);
    });

    test('importing a 1.0 backup builds a working database', () async {
      const v1 = '''
{"version":1,"dark":false,"goal":5,
 "projects":[{"id":"inbox","name":"Inbox","color":"#678ac7","sections":["General"]},
             {"id":"work","name":"Work","color":"#57927c","sections":["Backlog","Review"]}],
 "tasks":[{"id":"a1","title":"Review paper","description":"","projectId":"work","section":"Review",
           "priority":1,"completed":false,"due":"2026-10-20","labels":["reading"],
           "subtasks":[{"title":"Read","done":false}],"comments":[{"text":"hi","at":"2026-10-10T08:30:00.000Z"}]}]}
''';
      await repo.replaceAll(Bundle.parse(v1));
      final projects = await repo.watchProjects().first;
      final work = projects.firstWhere((p) => p.name == 'Work');
      final tasks = await open(work.id);
      expect(tasks.map((t) => t.title).toSet(), {'Review paper', 'Read'});
      final parent = tasks.firstWhere((t) => t.title == 'Review paper');
      expect(tasks.firstWhere((t) => t.title == 'Read').parentId, parent.id);
      final sections = await repo.watchSections(work.id).first;
      expect(sections.firstWhere((s) => s.id == parent.sectionId).name, 'Review');
      expect((await repo.watchLabels().first).single.name, 'reading');
      expect((await repo.watchComments(parent.id).first).single.body, 'hi');
    });
  });
}
