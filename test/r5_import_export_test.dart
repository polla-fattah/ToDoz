import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow_core/backup.dart' show inboxId;
import 'package:taskflow_core/csv_io.dart';

final fixedNow = DateTime(2026, 10, 14, 9);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late Repo repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repo(db, clock: () => fixedNow);
    await db.ensureInbox();
  });
  tearDown(() => db.close());

  Future<String> buildSample() async {
    final p = await repo.createProject(name: 'Home');
    final garden = await repo.createSection(p, 'Garden');
    final label = await repo.createLabel('errands');
    final a = await repo.addTask(title: 'Pay rent', projectId: p, priority: 1, dueDate: '2026-11-01', labelIds: [label]);
    await repo.addComment(a, 'Transfer on the 1st');
    final b = await repo.addTask(title: 'Clean', projectId: p, description: 'rooms, "all" of them');
    await repo.addTask(title: 'Kitchen', parentId: b);
    final sub = await repo.addTask(title: 'Oven', parentId: (await repo.watchChildren(b).first).single.id);
    expect(sub, isNotEmpty);
    await repo.addTask(title: 'Gym', projectId: p, dueDate: '2026-10-15', dueTime: '07:00', recurrence: 'every mon, fri at 7am');
    await repo.addTask(title: 'Mow the lawn', projectId: p, sectionId: garden, dueDate: '2026-10-17', dueTime: '10:30');
    await repo.addProjectComment(p, 'Remember the landlord is away');
    final done = await repo.addTask(title: 'Already done', projectId: p);
    await repo.completeTask(done);
    return p;
  }

  group('export', () {
    test('writes open tasks only, with sections, indent, labels, comments, dates and project notes', () async {
      final p = await buildSample();
      final csv = await repo.exportProjectCsv(p);
      final r = parseTodoistCsv(csv);
      final lines = r.items.map((i) => '${i.kind}|${i.content}|${i.indent}|${i.priority}|${i.date}|${i.labels.join('/')}').toList();
      expect(lines, [
        'note|Remember the landlord is away|1|4|null|',
        'task|Pay rent|1|1|2026-11-01|errands',
        'note|Transfer on the 1st|1|4|null|',
        'task|Clean|1|4|null|',
        'task|Kitchen|2|4|null|',
        'task|Oven|3|4|null|',
        'task|Gym|1|4|every mon, fri at 7am|',
        'section|Garden|1|4|null|',
        'task|Mow the lawn|1|4|2026-10-17 10:30|',
      ]);
      expect(csv, isNot(contains('Already done')));
      expect(r.items.firstWhere((i) => i.content == 'Clean').description, 'rooms, "all" of them');
    });

    test('a template drops the dates', () async {
      final p = await buildSample();
      final csv = await repo.exportProjectCsv(p, template: true);
      expect(parseTodoistCsv(csv).items.where((i) => i.date != null), isEmpty);
    });
  });

  group('import', () {
    test('export, import as a new project, export again: unchanged', () async {
      final p = await buildSample();
      final first = await repo.exportProjectCsv(p);
      final (copyId, result) = await repo.importAsNewProject('Home copy', parseTodoistCsv(first));
      expect(result.tasks, 6);
      expect(result.sections, 1);
      expect(result.unreadableDates, 0);
      expect(await repo.exportProjectCsv(copyId), first);
    });

    test('the copy really has sub-tasks, a section, labels, comments, times and a repeat', () async {
      final p = await buildSample();
      final (copyId, _) = await repo.importAsNewProject('Copy', parseTodoistCsv(await repo.exportProjectCsv(p)));
      final tasks = await repo.watchProjectTasks(copyId).first;
      Task t(String title) => tasks.firstWhere((x) => x.title == title);
      expect(t('Kitchen').parentId, t('Clean').id);
      expect(t('Oven').parentId, t('Kitchen').id);
      expect((t('Gym').recurrence, t('Gym').dueTime), ('every mon, fri at 7am', '07:00'));
      expect((t('Mow the lawn').dueDate, t('Mow the lawn').dueTime), ('2026-10-17', '10:30'));
      final section = (await repo.watchSections(copyId).first).single;
      expect(t('Mow the lawn').sectionId, section.id);
      expect((await repo.watchComments(t('Pay rent').id).first).single.body, 'Transfer on the 1st');
      expect((await repo.watchProjectComments(copyId).first).single.body, 'Remember the landlord is away');
      expect((await repo.watchLabels().first).map((l) => l.name), ['errands'], reason: 'the label is reused, not duplicated');
      expect(t('Pay rent').priority, 1);
    });

    test('dates that cannot be read are counted, and the task is kept without a date', () async {
      final r = parseTodoistCsv('TYPE,CONTENT,DATE\ntask,Someday thing,someday maybe\ntask,Fine,2026-12-01\n');
      final res = await repo.importItems(r, projectId: inboxId);
      expect(res.tasks, 2);
      expect(res.unreadableDates, 1);
      expect(res.summary, contains('1 dates could not be read'));
      final tasks = await repo.watchProjectTasks(inboxId).first;
      expect(tasks.firstWhere((t) => t.title == 'Someday thing').dueDate, isNull);
    });

    test('importing into an existing project reuses a section with the same name', () async {
      final p = await repo.createProject(name: 'Existing');
      final sec = await repo.createSection(p, 'Later');
      final r = parseTodoistCsv('TYPE,CONTENT\nsection,later\ntask,Into the section\n');
      final res = await repo.importItems(r, projectId: p);
      expect(res.sections, 0);
      expect((await repo.watchSections(p).first).length, 1);
      expect((await repo.watchProjectTasks(p).first).single.sectionId, sec);
    });

    test('plain text and Markdown checklists', () async {
      final r = parseTextTasks('# Shopping\n- [ ] Milk\n- [x] Bread\n  - Brown\n');
      final p = await repo.createProject(name: 'List');
      final res = await repo.importItems(r, projectId: p);
      expect((res.tasks, res.sections), (3, 1));
      final all = await repo.watchAllTasks().first;
      expect(all.firstWhere((t) => t.title == 'Bread').completedAt, isNotNull);
      expect(all.firstWhere((t) => t.title == 'Brown').parentId, all.firstWhere((t) => t.title == 'Bread').id);
    });

    test('iCalendar tasks', () async {
      final r = parseIcsTasks('BEGIN:VTODO\nSUMMARY:Call mum\nDUE:20261020T180000\nPRIORITY:1\nEND:VTODO\n');
      await repo.importItems(r, projectId: inboxId);
      final t = (await repo.watchProjectTasks(inboxId).first).single;
      expect((t.title, t.dueDate, t.dueTime, t.priority), ('Call mum', '2026-10-20', '18:00', 1));
    });

    test('an import that fails half way changes nothing', () async {
      final p = await repo.createProject(name: 'Atomic');
      final bad = ImportReport(items: [ImportItem.task('created before the failure'), ImportItem.section('   ')]);
      await expectLater(repo.importItems(bad, projectId: p), throwsA(isA<RuleException>()));
      expect(await repo.watchProjectTasks(p).first, isEmpty);
    });
  });

  group('templates', () {
    test('save a project as a template, use it for a new project, delete it', () async {
      final p = await buildSample();
      await repo.saveTemplate('Monthly home', p);
      final t = (await repo.templates()).single;
      expect(t.csv, isNot(contains('2026-11-01')));
      final id = await repo.useTemplate(t.id, 'November');
      final tasks = await repo.watchProjectTasks(id).first;
      expect(tasks.map((x) => x.title), containsAll(['Pay rent', 'Gym', 'Kitchen']));
      expect(tasks.every((x) => x.dueDate == null), isTrue);
      await repo.deleteTemplate(t.id);
      expect(await repo.templates(), isEmpty);
      expect(() => repo.useTemplate(t.id, 'x'), throwsA(isA<RuleException>()));
    });

    test('saving under the same name replaces the old template', () async {
      final p = await repo.createProject(name: 'P');
      await repo.addTask(title: 'one', projectId: p);
      await repo.saveTemplate('T', p);
      await repo.addTask(title: 'two', projectId: p);
      await repo.saveTemplate('t', p);
      final all = await repo.templates();
      expect(all.length, 1);
      expect(all.single.csv, contains('two'));
    });
  });
}
