import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/core/backup.dart';

final now = DateTime(2026, 10, 14, 9);

/// A realistic 1.0 export: the three default projects, a task with every
/// field, a completed task, and a checklist.
Map<String, Object?> v1Sample() => {
      'version': 1,
      'dark': true,
      'goal': 7,
      'projects': [
        {'id': 'inbox', 'name': 'Inbox', 'color': '#678ac7', 'sections': ['General']},
        {'id': 'work', 'name': 'Work & Research', 'color': '#57927c', 'sections': ['Backlog', 'In Progress', 'Review']},
        {'id': 'personal', 'name': 'Personal', 'color': '#d99a45', 'sections': ['General']},
      ],
      'tasks': [
        {
          'id': 'abc1', 'title': 'Review paper', 'description': 'Chapter 3 notes',
          'projectId': 'work', 'section': 'In Progress', 'priority': 1,
          'completed': false, 'due': '2026-10-20', 'labels': ['reading', 'deepwork'],
          'subtasks': [
            {'title': 'Read abstract', 'done': true},
            {'title': 'Check references', 'done': false},
          ],
          'comments': [
            {'text': 'Ask Sam about figure 2', 'at': '2026-10-10T08:30:00.000Z'},
          ],
        },
        {
          'id': 'abc2', 'title': 'Buy milk', 'description': '',
          'projectId': 'inbox', 'section': 'General', 'priority': 4,
          'completed': true, 'completedAt': '2026-10-12', 'due': '',
          'labels': ['Reading'], 'subtasks': [], 'comments': [],
        },
      ],
    };

Bundle parse(Object? json) => Bundle.parse(jsonEncode(json), now: now);

void main() {
  group('1.0 import', () {
    late Bundle b;
    setUp(() => b = parse(v1Sample()));

    test('keeps the Inbox id and gives other projects new ids', () {
      expect(b.projects.map((p) => p.name), ['Inbox', 'Work & Research', 'Personal']);
      expect(b.projects.first.id, inboxId);
      expect(b.projects.first.isInbox, isTrue);
      expect(b.projects[1].id, isNot('work'));
    });

    test('converts "#rrggbb" colors to opaque ARGB integers', () {
      expect(b.projects.first.color, 0xFF678AC7);
    });

    test('a project whose only section is General gets no sections', () {
      final inboxSections = b.sections.where((s) => s.projectId == inboxId);
      expect(inboxSections, isEmpty);
      final buy = b.tasks.firstWhere((t) => t.title == 'Buy milk');
      expect(buy.sectionId, isNull);
    });

    test('real sections are kept, in order, and tasks point at them', () {
      final work = b.projects[1];
      final secs = b.sections.where((s) => s.projectId == work.id).toList();
      expect(secs.map((s) => s.name), ['Backlog', 'In Progress', 'Review']);
      expect(secs.map((s) => s.sortOrder), [0, 1, 2]);
      final review = b.tasks.firstWhere((t) => t.title == 'Review paper');
      expect(secs.firstWhere((s) => s.id == review.sectionId).name, 'In Progress');
      expect(review.projectId, work.id);
    });

    test('keeps every task field', () {
      final t = b.tasks.firstWhere((t) => t.title == 'Review paper');
      expect(t.description, 'Chapter 3 notes');
      expect(t.priority, 1);
      expect(t.dueDate, '2026-10-20');
      expect(t.completedAt, isNull);
      expect(t.parentId, isNull);
    });

    test('checklist items become real sub-tasks of the same project', () {
      final parent = b.tasks.firstWhere((t) => t.title == 'Review paper');
      final subs = b.tasks.where((t) => t.parentId == parent.id).toList();
      expect(subs.map((t) => t.title), ['Read abstract', 'Check references']);
      expect(subs.every((t) => t.projectId == parent.projectId), isTrue);
      expect(subs[0].completedAt, isNotNull);
      expect(subs[1].completedAt, isNull);
    });

    test('1.0 stored a completion date only, so completion time is noon', () {
      final t = b.tasks.firstWhere((t) => t.title == 'Buy milk');
      expect(t.completedAt, DateTime(2026, 10, 12, 12));
    });

    test('labels are shared by lower-cased name', () {
      expect(b.labels.map((l) => l.name).toSet(), {'reading', 'deepwork'});
      final review = b.tasks.firstWhere((t) => t.title == 'Review paper');
      final buy = b.tasks.firstWhere((t) => t.title == 'Buy milk');
      final reading = b.labels.firstWhere((l) => l.name == 'reading').id;
      expect(review.labelIds, contains(reading));
      expect(buy.labelIds, [reading]);
    });

    test('comments keep their text and time', () {
      expect(b.comments, hasLength(1));
      expect(b.comments.single.body, 'Ask Sam about figure 2');
      expect(b.comments.single.createdAt.toUtc(), DateTime.utc(2026, 10, 10, 8, 30));
    });

    test('settings carry over', () {
      expect(b.settings['themeMode'], 'dark');
      expect(b.settings['dailyGoal'], '7');
    });

    test('nothing is lost: 2 tasks + 2 sub-tasks, 1 comment', () {
      expect(b.tasks, hasLength(4));
    });
  });

  group('invalid backups are rejected', () {
    void rejects(String why, Object? json) =>
        test(why, () => expect(() => parse(json), throwsFormatException));

    test('not JSON', () => expect(() => Bundle.parse('{oops', now: now), throwsFormatException));
    test('not an object', () => expect(() => Bundle.parse('[1,2]', now: now), throwsFormatException));
    rejects('unknown version', {'version': 3});
    rejects('no version', {'tasks': []});

    Map<String, Object?> mutate(void Function(Map<String, Object?>) f) {
      final m = jsonDecode(jsonEncode(v1Sample())) as Map<String, Object?>;
      f(m);
      return m;
    }

    rejects('no Inbox', mutate((m) => (m['projects'] as List).removeAt(0)));
    rejects('bad priority', mutate((m) => ((m['tasks'] as List)[0] as Map)['priority'] = 9));
    rejects('bad due date', mutate((m) => ((m['tasks'] as List)[0] as Map)['due'] = '2026-02-31'));
    rejects('task in a missing project', mutate((m) => ((m['tasks'] as List)[0] as Map)['projectId'] = 'ghost'));
    rejects('duplicate task id', mutate((m) => ((m['tasks'] as List)[1] as Map)['id'] = 'abc1'));
    rejects('bad project color', mutate((m) => ((m['projects'] as List)[0] as Map)['color'] = 'blue'));
    rejects('unsafe id', mutate((m) => ((m['tasks'] as List)[0] as Map)['id'] = 'a b;'));
    rejects('empty sections', mutate((m) => ((m['projects'] as List)[1] as Map)['sections'] = []));
  });

  group('version 2 round trip', () {
    test('export then parse reproduces the data', () {
      final original = parse(v1Sample());
      final again = Bundle.parse(original.toJsonString(), now: now);
      expect(again.projects.map((p) => p.id), original.projects.map((p) => p.id));
      expect(again.sections.map((s) => s.id), original.sections.map((s) => s.id));
      expect(again.labels.map((l) => l.name), original.labels.map((l) => l.name));
      expect(again.tasks.map((t) => t.id), original.tasks.map((t) => t.id));
      expect(again.tasks.map((t) => t.labelIds), original.tasks.map((t) => t.labelIds));
      expect(again.comments.single.body, original.comments.single.body);
      expect(again.settings, original.settings);
      final t = again.tasks.firstWhere((t) => t.title == 'Buy milk');
      expect(t.completedAt?.toLocal(), DateTime(2026, 10, 12, 12));
    });

    test('a v2 backup with a dangling reference is rejected', () {
      final j = jsonDecode(parse(v1Sample()).toJsonString()) as Map<String, Object?>;
      ((j['tasks'] as List)[0] as Map)['labelIds'] = ['ghost'];
      expect(() => Bundle.parse(jsonEncode(j), now: now), throwsFormatException);
    });
  });
}
