import 'package:taskflow_core/csv_io.dart';
import 'package:test/test.dart';

final now = DateTime(2026, 10, 14, 9); // a Wednesday

void main() {
  group('CSV text', () {
    test('quotes, doubled quotes, commas and line breaks inside fields', () {
      final rows = parseCsvRows('a,"b, c","say ""hi""","line1\nline2",\r\nx,,z\r\n');
      expect(rows, [
        ['a', 'b, c', 'say "hi"', 'line1\nline2', ''],
        ['x', '', 'z'],
      ]);
    });

    test('a byte order mark and a missing final newline are fine', () {
      expect(parseCsvRows('﻿TYPE,CONTENT\ntask,x'), [['TYPE', 'CONTENT'], ['task', 'x']]);
    });

    test('writing and reading are inverse', () {
      final rows = [
        ['plain', 'with, comma', 'with "quote"', 'multi\nline', ' padded ', ''],
        ['', '', '', '', '', ''],
      ];
      expect(parseCsvRows(writeCsvRows(rows)), rows);
    });
  });

  group('Todoist CSV', () {
    const sample = '''TYPE,CONTENT,DESCRIPTION,PRIORITY,INDENT,AUTHOR,RESPONSIBLE,DATE,DATE_LANG,TIMEZONE
meta,view_style,list,,,,,,,
task,Buy milk @errands,"2 litres, semi-skimmed",1,1,Polla (1),,2026-10-15,en,Asia/Riyadh
task,Whole milk only,,4,2,,,,,
note,Check the date on the bottle,,,,,,,,
section,Later,,,,,,,,
task,Water the plants,,3,1,,,every week,en,
task,Call the bank,,2,1,,,tomorrow at 4pm,en,
mystery,what,,,,,,,,
''';

    test('reads tasks, sections, notes, labels, priority, indent and dates; skips meta and unknown rows', () {
      final r = parseTodoistCsv(sample);
      expect(r.items.map((i) => i.kind), ['task', 'task', 'note', 'section', 'task', 'task']);
      final milk = r.items[0];
      expect((milk.content, milk.priority, milk.indent, milk.date, milk.description), ('Buy milk', 1, 1, '2026-10-15', '2 litres, semi-skimmed'));
      expect(milk.labels, ['errands']);
      expect(r.items[1].indent, 2);
      expect(r.items[2].content, 'Check the date on the bottle');
      expect(r.items[3].content, 'Later');
      expect(r.skipped, 1);
      expect(r.taskCount, 4);
    });

    test('refuses a file that is not a Todoist export', () {
      expect(() => parseTodoistCsv('name,age\nx,1\n'), throwsFormatException);
      expect(() => parseTodoistCsv(''), throwsFormatException);
    });

    test('export then import then export again gives the same text', () {
      final sections = [
        ExportSection(null, [
          const ExportTask(title: 'Pay rent', priority: 1, dueDate: '2026-11-01', labels: ['home'], comments: ['Transfer on the 1st']),
          const ExportTask(title: 'Gym', dueDate: '2026-10-15', dueTime: '07:00', recurrence: 'every mon, fri at 7am'),
          const ExportTask(title: 'Sub item', indent: 2, description: 'details, with "quotes"'),
        ]),
        ExportSection('Later', [const ExportTask(title: 'Dentist', dueDate: '2026-12-01', dueTime: '09:30', priority: 2)]),
      ];
      final first = writeTodoistCsv(sections);
      final read = parseTodoistCsv(first);

      // Rebuild the export model from what was read, as an import followed by an export would.
      final rebuilt = <ExportSection>[];
      var current = ExportSection(null, []);
      rebuilt.add(current);
      var tasks = current.tasks;
      for (final i in read.items) {
        if (i.kind == 'section') {
          tasks = <ExportTask>[];
          current = ExportSection(i.content, tasks);
          rebuilt.add(current);
        } else if (i.kind == 'task') {
          final w = i.date == null ? null : parseImportedWhen(i.date!, now);
          tasks.add(ExportTask(
            title: i.content,
            description: i.description,
            priority: i.priority,
            indent: i.indent,
            dueDate: w?.recurrence == null ? w?.dueDate : null,
            dueTime: w?.recurrence == null ? w?.dueTime : null,
            recurrence: w?.recurrence,
            labels: i.labels,
          ));
        } else if (tasks.isNotEmpty) {
          final last = tasks.removeLast();
          tasks.add(ExportTask(
            title: last.title, description: last.description, priority: last.priority, indent: last.indent,
            dueDate: last.dueDate, dueTime: last.dueTime, recurrence: last.recurrence, labels: last.labels,
            comments: [...last.comments, i.content],
          ));
        }
      }
      final nonEmpty = rebuilt.where((s) => s.name != null || s.tasks.isNotEmpty).toList();
      expect(writeTodoistCsv(nonEmpty), first);
    });

    test('a template has no dates', () {
      final csv = writeTodoistCsv([
        ExportSection(null, [const ExportTask(title: 'Pack passport', dueDate: '2026-11-01', dueTime: '08:00', recurrence: 'every day')]),
      ], template: true);
      final r = parseTodoistCsv(csv);
      expect(r.items.single.date, isNull);
      expect(csv, isNot(contains('every day')));
    });
  });

  group('DATE cells', () {
    test('ISO date, date and time, natural language and repeats', () {
      var w = parseImportedWhen('2026-10-14', now)!;
      expect((w.dueDate, w.dueTime, w.recurrence), ('2026-10-14', null, null));
      w = parseImportedWhen('2026-10-14 09:30', now)!;
      expect((w.dueDate, w.dueTime), ('2026-10-14', '09:30'));
      w = parseImportedWhen('tomorrow at 4pm', now)!;
      expect((w.dueDate, w.dueTime), ('2026-10-15', '16:00'));
      w = parseImportedWhen('every mon, fri at 8am', now)!;
      expect(w.recurrence, 'every mon, fri at 8am');
      expect(w.dueTime, '08:00');
      expect(w.dueDate, isNotNull);
      w = parseImportedWhen('14 Oct 2026', now)!;
      expect(w.dueDate, '2026-10-14');
    });

    test('unreadable text gives no date rather than a wrong one', () {
      expect(parseImportedWhen('someday maybe', now), isNull);
      expect(parseImportedWhen('', now), isNull);
    });

    test('a repeat phrase is checked for readability', () {
      expect(isReadableRepeat('every 2 weeks', now), isTrue);
      expect(isReadableRepeat('every blue moon', now), isFalse);
    });
  });

  group('plain text and Markdown', () {
    test('lines, bullets, checkboxes, indentation and headings', () {
      final r = parseTextTasks('''# Groceries
- [ ] Milk
- [x] Bread
  - brown
    - [ ] sliced
* Eggs
1. Butter

plain line
\t- tabbed
''');
      expect(r.items.map((i) => '${i.kind}:${i.content}:${i.indent}:${i.done}'), [
        'section:Groceries:1:false',
        'task:Milk:1:false',
        'task:Bread:1:true',
        'task:brown:2:false',
        'task:sliced:3:false',
        'task:Eggs:1:false',
        'task:Butter:1:false',
        'task:plain line:1:false',
        'task:tabbed:2:false',
      ]);
    });

    test('empty text reports it', () {
      expect(parseTextTasks('\n \n').warnings, isNotEmpty);
    });
  });

  group('iCalendar tasks', () {
    test('summary, notes, due date and time, priority, status, repeats and folded lines', () {
      final r = parseIcsTasks('BEGIN:VCALENDAR\r\n'
          'BEGIN:VTODO\r\nSUMMARY:Pay the\r\n  electricity bill\r\nDESCRIPTION:Account 123\\, ref A\\nsecond line\r\nDUE;VALUE=DATE:20261101\r\nPRIORITY:1\r\nEND:VTODO\r\n'
          'BEGIN:VTODO\r\nSUMMARY:Standup\r\nDUE:20261015T093000Z\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE\r\nPRIORITY:5\r\nEND:VTODO\r\n'
          'BEGIN:VTODO\r\nSUMMARY:Done thing\r\nSTATUS:COMPLETED\r\nEND:VTODO\r\n'
          'BEGIN:VTODO\r\nDESCRIPTION:no summary\r\nEND:VTODO\r\n'
          'END:VCALENDAR\r\n');
      expect(r.items.length, 3);
      expect(r.skipped, 1);
      expect((r.items[0].content, r.items[0].description, r.items[0].date, r.items[0].priority), ('Pay the electricity bill', 'Account 123, ref A\nsecond line', '2026-11-01', 1));
      expect((r.items[1].date, r.items[1].priority), ('every mon, wed', 3));
      expect(r.items[2].done, isTrue);
    });

    test('a calendar with no tasks says so', () {
      expect(parseIcsTasks('BEGIN:VCALENDAR\nEND:VCALENDAR').warnings, isNotEmpty);
    });
  });
}
