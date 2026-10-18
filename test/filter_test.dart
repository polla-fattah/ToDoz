import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/core/filter.dart';

// Wednesday 14 October 2026, 09:00.
final now = DateTime(2026, 10, 14, 9);

final env = FilterEnv(
  projects: const [
    FilterProject('inbox', 'Inbox'),
    FilterProject('work', 'Work'),
    FilterProject('home', 'Home'),
    FilterProject('shop', 'Shopping list'),
    FilterProject('garden', 'Garden', parentId: 'home'),
  ],
  sections: const [
    FilterSectionInfo('s1', 'work', 'Backlog'),
    FilterSectionInfo('s2', 'work', 'Review'),
    FilterSectionInfo('s3', 'home', 'Todo'),
  ],
  now: now,
);

final tasks = <FilterTask>[
  FilterTask(id: 't1', title: 'Pay bill', projectId: 'inbox', dueDate: '2026-10-14', priority: 1, labels: const ['email'], createdAt: now),
  FilterTask(id: 't2', title: 'Late report', projectId: 'work', sectionId: 's1', dueDate: '2026-10-10', priority: 2, labels: const ['work'], createdAt: now),
  FilterTask(id: 't3', title: 'Buy milk', projectId: 'shop', dueDate: '2026-10-14', dueTime: '08:00', labels: const ['home', 'errands'], createdAt: now),
  FilterTask(id: 't4', title: 'Mow lawn', projectId: 'garden', dueDate: '2026-10-17', priority: 3, recurrence: 'every week', labels: const ['home'], createdAt: now),
  FilterTask(id: 't5', title: 'Plan holiday', projectId: 'home', createdAt: DateTime(2026, 10, 1)),
  FilterTask(id: 't6', title: 'Sub step', projectId: 'work', sectionId: 's1', parentId: 't2', dueDate: '2026-10-15', createdAt: now),
  FilterTask(
    id: 't7', title: 'Email Sam about invoice', description: 'Q3 invoice', projectId: 'inbox', dueDate: '2026-10-20',
    dueTime: '10:00', priority: 2, deadline: '2026-11-01', createdAt: now,
  ),
];

Set<String> run(String query) => {
      for (final t in tasks)
        if (parseFilter(query, env).matches(t)) t.id,
    };

FilterException error(String query) {
  try {
    parseFilter(query, env);
  } on FilterException catch (e) {
    return e;
  }
  fail('"$query" should have been refused');
}

void main() {
  group('dates', () {
    test('today, tomorrow, overdue', () {
      expect(run('today'), {'t1', 't3'});
      expect(run('tomorrow'), {'t6'});
      // t3 was due at 08:00 today, so it is overdue by 09:00.
      expect(run('overdue'), {'t2', 't3'});
      expect(run('today | overdue'), {'t1', 't2', 't3'});
    });
    test('no date, no time, recurring, no deadline', () {
      expect(run('no date'), {'t5'});
      expect(run('no time'), {'t1', 't2', 't4', 't5', 't6'});
      expect(run('recurring'), {'t4'});
      expect(run('no deadline'), {'t1', 't2', 't3', 't4', 't5', 't6'});
    });
    test('N days includes overdue, as Upcoming does', () {
      expect(run('7 days'), {'t1', 't2', 't3', 't4', 't6', 't7'});
      expect(run('next 3 days'), {'t1', 't2', 't3', 't6'});
      expect(run('1 day'), {'t1', 't2', 't3'});
    });
    test('due before and after, with real dates and phrases', () {
      expect(run('due before: 2026-10-15'), {'t1', 't2', 't3'});
      expect(run('date before: tomorrow'), {'t1', 't2', 't3'});
      expect(run('date after: 2026-10-15'), {'t4', 't7'});
      expect(run('due before: next monday'), {'t1', 't2', 't3', 't4', 't6'});
      expect(run('due after: oct 15'), {'t4', 't7'});
    });
    test('deadlines', () {
      expect(run('deadline before: 2026-12-01'), {'t7'});
      expect(run('deadline after: 2026-11-01'), isEmpty); // equal is not after
      expect(run('deadline after: 2026-10-01'), {'t7'});
    });
    test('created', () {
      expect(run('created: 2026-10-01'), {'t5'});
      expect(run('created before: 2026-10-10'), {'t5'});
      expect(run('created after: 2026-10-10'), {'t1', 't2', 't3', 't4', 't6', 't7'});
      expect(run('created: 13 days ago'), {'t5'});
      expect(run('created: today'), {'t1', 't2', 't3', 't4', 't6', 't7'});
    });
  });

  group('priority, structure and labels', () {
    test('p1-p4 and no priority', () {
      expect(run('p1'), {'t1'});
      expect(run('p2'), {'t2', 't7'});
      expect(run('p3'), {'t4'});
      expect(run('p4'), {'t3', 't5', 't6'});
      expect(run('no priority'), {'t3', 't5', 't6'});
    });
    test('subtask and no labels', () {
      expect(run('subtask'), {'t6'});
      expect(run('!subtask & #Work'), {'t2'});
      expect(run('no labels'), {'t5', 't6', 't7'});
    });
    test('% and @ both mean a label; * matches any characters', () {
      expect(run('%home'), {'t3', 't4'});
      expect(run('@home'), {'t3', 't4'});
      expect(run('%e*'), {'t1', 't3'});
      expect(run('%HOME'), {'t3', 't4'});
    });
  });

  group('projects and sections', () {
    test('#project is exact; ##project includes sub-projects', () {
      expect(run('#Work'), {'t2', 't6'});
      expect(run('#Home'), {'t5'});
      expect(run('##Home'), {'t4', 't5'});
      expect(run('#Garden'), {'t4'});
    });
    test('names with spaces: backslash, quotes, or the hyphenated form', () {
      expect(run(r'#Shopping\ list'), {'t3'});
      expect(run('#"Shopping list"'), {'t3'});
      expect(run('#shopping-list'), {'t3'});
      expect(run('#shop*'), {'t3'});
    });
    test('/section and /* (no section)', () {
      expect(run('/backlog'), {'t2', 't6'});
      expect(run('/*'), {'t1', 't3', 't4', 't5', 't7'});
      expect(run('/Backlog & !subtask'), {'t2'});
      expect(run('#Work & /Review'), isEmpty);
    });
  });

  group('search', () {
    test('matches title, description, labels, project and section', () {
      expect(run('search: invoice'), {'t7'});
      expect(run('search: milk'), {'t3'});
      expect(run('search: SAM'), {'t7'});
      expect(run('search: work'), {'t2', 't6'}); // the Work project and the "work" label
      expect(run('search: backlog'), {'t2', 't6'});
      expect(run('search: err*'), {'t3'});
    });
    test('the search text stops at the next operator', () {
      expect(run('search: bill & p1'), {'t1'});
      expect(run('search: bill | search: milk'), {'t1', 't3'});
    });
    test('view all matches everything', () {
      expect(run('view all'), {'t1', 't2', 't3', 't4', 't5', 't6', 't7'});
    });
  });

  group('operators', () {
    test('and, or, not, brackets', () {
      expect(run('today & p1'), {'t1'});
      expect(run('!p1 & today'), {'t3'});
      expect(run('today & !overdue'), {'t1'});
      expect(run('!(today | overdue)'), {'t4', 't5', 't6', 't7'});
      expect(run('(today | overdue) & #Work'), {'t2'});
    });
    test('and binds tighter than or', () {
      expect(run('p1 | p2 & overdue'), {'t1', 't2'});
      expect(run('(p1 | p2) & overdue'), {'t2'});
    });
    test('a comma gives separate lists, each with its own text', () {
      final f = parseFilter('p1 & overdue, p4 & today', env);
      expect(f.branches.map((b) => b.text), ['p1 & overdue', 'p4 & today']);
      expect(tasks.where(f.branches[0].matches), isEmpty);
      expect(tasks.where(f.branches[1].matches).map((t) => t.id), ['t3']);
      expect(tasks.where(f.matches).map((t) => t.id), ['t3']);
      expect(f.isSingle, isFalse);
    });
    test('spacing and case do not matter', () {
      expect(run('  TODAY&P1 '), {'t1'});
      expect(run('Today  |   Overdue'), {'t1', 't2', 't3'});
    });
  });

  group('errors say what is wrong and where', () {
    test('an unknown word', () {
      final e = error('blah');
      expect(e.message, contains('do not understand'));
      expect((e.start, e.end), (0, 4));
    });
    test('an unknown project points at it', () {
      final e = error('#Work & #Nope');
      expect(e.message, contains('No project matches'));
      expect((e.start, e.end), (8, 13));
    });
    test('an unknown section and a bad priority', () {
      expect(error('/nothing').message, contains('No section matches'));
      expect(error('p9').message, contains('p1, p2, p3 and p4'));
    });
    test('a missing condition', () {
      expect(error('today &').message, contains('too soon'));
      expect(error('!').message, contains('needs a condition'));
      expect(error('today & & p1').message, isNotEmpty);
    });
    test('brackets', () {
      final open = error('(today | p1');
      expect(open.message, contains('Missing ")"'));
      expect(open.start, 0);
      expect(error('today)').message, contains('without a matching'));
      expect(error('()').message, isNotEmpty);
    });
    test('commas', () {
      expect(error('today,').message, contains('after the comma'));
      expect(error('(today, p1)').message, contains('cannot go inside brackets'));
    });
    test('dates and quotes', () {
      expect(error('due before: nonsense').message, contains('could not read the date'));
      expect(error('due before').message, contains('before:'));
      expect(error('#"open').message, contains('quote'));
      expect(error('search:').message, contains('search for'));
    });
    test('an empty query', () {
      expect(error('').message, contains('Type a query'));
      expect(error('   ').message, contains('Type a query'));
    });
  });

  group('deciding between a filter and plain text', () {
    test('filters are recognised, ordinary words are not', () {
      expect(looksLikeFilter('p1', env), isTrue);
      expect(looksLikeFilter('today', env), isTrue);
      expect(looksLikeFilter('#Work', env), isTrue);
      expect(looksLikeFilter('groceries', env), isFalse);
      expect(looksLikeFilter('buy milk', env), isFalse);
    });
  });

  test('every shipped example is a valid query', () {
    for (final (query, _) in filterExamples) {
      expect(() => parseFilter(query, env), returnsNormally, reason: query);
    }
  });
}
