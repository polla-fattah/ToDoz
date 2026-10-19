import 'package:test/test.dart';
import 'package:taskflow_core/view_options.dart';

// Wednesday 14 October 2026, 09:00.
final now = DateTime(2026, 10, 14, 9);

TaskFacts t(
  String id, {
  String project = 'work',
  String? section,
  int priority = 4,
  String? due,
  String? time,
  List<String> labels = const [],
  int order = 0,
  DateTime? created,
}) =>
    TaskFacts(
      id: id, title: 'Task $id', projectId: project, sectionId: section, priority: priority,
      dueDate: due, dueTime: time, labelIds: labels, sortOrder: order, createdAt: created ?? now,
    );

const lookups = GroupLookups(
  projects: [(id: 'inbox', name: 'Inbox'), (id: 'work', name: 'Work'), (id: 'home', name: 'Home')],
  sections: [
    (id: 's1', projectId: 'work', name: 'Backlog'),
    (id: 's2', projectId: 'work', name: 'In Progress'),
    (id: 's3', projectId: 'home', name: 'Todo'),
  ],
  labels: [(id: 'l1', name: 'reading'), (id: 'l2', name: 'errands')],
);

List<TaskGroup<TaskFacts>> grp(List<TaskFacts> xs, Grouping g, {SortBy sort = SortBy.manual, bool empty = false, GroupLookups l = lookups}) =>
    groupAndSort<TaskFacts>(xs, facts: (x) => x, group: g, sort: sort, now: now, lookups: l, showEmptyColumns: empty);

Map<String, List<String>> ids(List<TaskGroup<TaskFacts>> gs) => {for (final g in gs) g.title: g.items.map((i) => i.id).toList()};

void main() {
  group('ViewOptions storage', () {
    test('round trips every field', () {
      const o = ViewOptions(
        layout: ViewLayout.board, group: Grouping.priority, sort: SortBy.date,
        showCompleted: true, showSubtasks: false, showDetails: false,
      );
      expect(ViewOptions.decode(o.encode()), o);
    });
    test('an unset group stays unset', () {
      expect(ViewOptions.decode(const ViewOptions().encode()).group, isNull);
      expect(const ViewOptions().copyWith(group: Grouping.label).copyWith(clearGroup: true).group, isNull);
    });
    test('missing or broken data falls back to defaults', () {
      expect(ViewOptions.decode(null), const ViewOptions());
      expect(ViewOptions.decode(''), const ViewOptions());
      expect(ViewOptions.decode('not json'), const ViewOptions());
      expect(ViewOptions.decode('[1,2]'), const ViewOptions());
      expect(ViewOptions.decode('{"layout":"hologram","sort":7}'), const ViewOptions());
    });
  });

  group('grouping', () {
    test('none keeps everything in one group', () {
      final g = grp([t('a'), t('b')], Grouping.none);
      expect(g, hasLength(1));
      expect(g.single.items, hasLength(2));
    });

    test('section: no section first, then sections in order, empty ones left out', () {
      final g = grp([t('a', section: 's2'), t('b'), t('c', section: 's1'), t('d', section: 's2')], Grouping.section);
      expect(ids(g), {'No section': ['b'], 'Backlog': ['c'], 'In Progress': ['a', 'd']});
      expect(g.map((x) => x.title), ['No section', 'Backlog', 'In Progress']);
    });

    test('section: a board keeps empty columns, and ignores a deleted section id', () {
      final g = grp([t('a', section: 'gone')], Grouping.section, empty: true);
      expect(g.map((x) => x.title), ['No section', 'Backlog', 'In Progress', 'Todo'].where((x) => x != 'Todo').toList()..add('Todo'));
      expect(g.first.items.map((i) => i.id), ['a']);
    });

    test('section across projects names each section with its project', () {
      final g = grp([t('a', section: 's1'), t('b', project: 'home', section: 's3')], Grouping.section);
      expect(g.map((x) => x.title), ['Work · Backlog', 'Home · Todo']);
    });

    test('date: overdue, today, tomorrow, later dates in order, then no date', () {
      final g = grp([
        t('late', due: '2026-10-10', order: 0),
        t('earlyToday', due: '2026-10-14', time: '08:00', order: 1), // time has passed: overdue
        t('today', due: '2026-10-14', time: '18:00'),
        t('tmr', due: '2026-10-15'),
        t('later', due: '2026-10-30'),
        t('none'),
      ], Grouping.date);
      expect(g.map((x) => x.title), ['Overdue', 'Today', 'Tomorrow', '2026-10-30', 'No date']);
      expect(ids(g)['Overdue'], ['late', 'earlyToday']);
      expect(ids(g)['Today'], ['today']);
    });

    test('priority: always four columns, p4 called No priority', () {
      final g = grp([t('a', priority: 1), t('b', priority: 4)], Grouping.priority);
      expect(g.map((x) => x.title), ['Priority 1', 'Priority 2', 'Priority 3', 'No priority']);
      expect(ids(g)['Priority 1'], ['a']);
    });

    test('label: a task with two labels appears under both; unlabelled ones last', () {
      final g = grp([t('a', labels: ['l1', 'l2']), t('b', labels: ['l2']), t('c')], Grouping.label);
      expect(ids(g), {'reading': ['a'], 'errands': ['a', 'b'], 'No label': ['c']});
      expect(g.map((x) => x.title), ['reading', 'errands', 'No label']);
    });

    test('project: in project order', () {
      final g = grp([t('a', project: 'home'), t('b', project: 'inbox'), t('c', project: 'work')], Grouping.project);
      expect(g.map((x) => x.title), ['Inbox', 'Work', 'Home']);
    });

    test('group keys carry what a drop should set', () {
      final g = grp([t('a', section: 's1', due: '2026-10-20'), t('b', priority: 2)], Grouping.section);
      expect(g.firstWhere((x) => x.title == 'Backlog').key, const GroupKey(Grouping.section, 's1'));
      final d = grp([t('a', due: '2026-10-10'), t('b', due: '2026-10-20')], Grouping.date);
      expect(d.first.key.acceptsDrops, isFalse); // Overdue
      expect(d.last.key.acceptsDrops, isTrue);
      expect(d.last.key.value, '2026-10-20');
    });
  });

  group('sorting inside groups', () {
    final xs = [
      t('c', priority: 3, due: '2026-10-20', order: 1, created: DateTime(2026, 10, 3)),
      t('a', priority: 1, due: '2026-10-25', order: 3, created: DateTime(2026, 10, 2)),
      t('b', priority: 1, due: '2026-10-18', order: 2, created: DateTime(2026, 10, 1)),
      t('n', priority: 4, order: 0, created: DateTime(2026, 10, 4)),
    ];
    List<String> run(SortBy s) => grp(xs, Grouping.none, sort: s).single.items.map((i) => i.id).toList();

    test('manual follows the stored order', () => expect(run(SortBy.manual), ['n', 'c', 'b', 'a']));
    test('name', () => expect(run(SortBy.name), ['a', 'b', 'c', 'n']));
    test('date puts undated tasks last', () => expect(run(SortBy.date), ['b', 'c', 'a', 'n']));
    test('priority, then date', () => expect(run(SortBy.priority), ['b', 'a', 'c', 'n']));
    test('added', () => expect(run(SortBy.added), ['b', 'a', 'c', 'n']));

    test('timed tasks sort before untimed ones on the same day', () {
      final g = grp([t('x', due: '2026-10-20'), t('y', due: '2026-10-20', time: '09:00'), t('z', due: '2026-10-20', time: '08:00')], Grouping.none, sort: SortBy.date);
      expect(g.single.items.map((i) => i.id), ['z', 'y', 'x']);
    });

    test('ties are broken by creation time, then id, so the order is stable', () {
      final g = grp([t('b'), t('a')], Grouping.none, sort: SortBy.priority);
      expect(g.single.items.map((i) => i.id), ['a', 'b']);
    });
  });
}
