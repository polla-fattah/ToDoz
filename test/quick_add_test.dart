import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/core/quick_add.dart';
import 'package:taskflow/core/reminder.dart';

// Wednesday 14 October 2026.
final now = DateTime(2026, 10, 14, 9);

void main() {
  test('the 1.0 example line', () {
    final r = parseQuickAdd('Review paper tomorrow p1 @reading #work', now);
    expect(r.title, 'Review paper');
    expect(r.due, DateTime(2026, 10, 15));
    expect(r.priority, 1);
    expect(r.labels, ['reading']);
    expect(r.projectName, 'work');
    expect(r.sectionName, isNull);
  });

  test('a plain line is left alone', () {
    final r = parseQuickAdd('Buy milk', now);
    expect(r.title, 'Buy milk');
    expect(r.due, isNull);
    expect(r.priority, isNull);
    expect(r.labels, isEmpty);
    expect(r.tokens, isEmpty);
  });

  test('% and @ both mark labels, duplicates collapse, case is folded', () {
    final r = parseQuickAdd('Plan trip %Travel @travel %Errands', now);
    expect(r.labels, ['travel', 'errands']);
    expect(r.title, 'Plan trip');
  });

  test('a section is recognised only after a project', () {
    final withProject = parseQuickAdd('Fix bug #work /backlog', now);
    expect(withProject.projectName, 'work');
    expect(withProject.sectionName, 'backlog');
    expect(withProject.title, 'Fix bug');

    final without = parseQuickAdd('Read a/b notes /backlog', now);
    expect(without.sectionName, isNull);
    expect(without.title, 'Read a/b notes /backlog');
  });

  test('quoted names may contain spaces', () {
    final r = parseQuickAdd('Draft #"Work & Research" /"In Progress" outline', now);
    expect(r.projectName, 'Work & Research');
    expect(r.sectionName, 'In Progress');
    expect(r.title, 'Draft outline');
  });

  test('priority must be a whole word between p1 and p4', () {
    expect(parseQuickAdd('Ship p4', now).priority, 4);
    expect(parseQuickAdd('Ship p5', now).priority, isNull);
    expect(parseQuickAdd('Ship p1x', now).priority, isNull);
    expect(parseQuickAdd('Ship p1x', now).title, 'Ship p1x');
  });

  test('email addresses and mid-word symbols are not tokens', () {
    final r = parseQuickAdd('Write to sam@example.com about c#', now);
    expect(r.labels, isEmpty);
    expect(r.projectName, isNull);
    expect(r.title, 'Write to sam@example.com about c#');
  });

  test('tokens inside labels do not leak into the date parser', () {
    final r = parseQuickAdd('Pay rent @monday', now);
    expect(r.labels, ['monday']);
    expect(r.due, isNull);
  });

  test('smart date recognition can be switched off', () {
    final r = parseQuickAdd('Plan for tomorrow p2', now, parseDates: false);
    expect(r.due, isNull);
    expect(r.title, 'Plan for tomorrow');
    expect(r.priority, 2);
  });

  test('token spans point at the original text for live highlighting', () {
    const line = 'Call Sam next fri p2 @work';
    final r = parseQuickAdd(line, now);
    String text(QuickAddKind k) {
      final t = r.tokens.firstWhere((t) => t.kind == k);
      return line.substring(t.start, t.end);
    }

    expect(text(QuickAddKind.date), 'next fri');
    expect(text(QuickAddKind.priority), 'p2');
    expect(text(QuickAddKind.label), '@work');
    expect(r.title, 'Call Sam');
  });

  test('a line that is only tokens leaves an empty title', () {
    final r = parseQuickAdd('tomorrow p1', now);
    expect(r.title, isEmpty);
    expect(r.due, DateTime(2026, 10, 15));
  });

  test('normaliseName matches 1.0 project-id style references', () {
    expect(normaliseName('Work & Research'), 'work-&-research');
    expect(normaliseName('  Personal  '), 'personal');
    expect(normaliseName('Work Research'), 'work-research');
  });

  group('R2 tokens', () {
    test('a time after a date', () {
      final r = parseQuickAdd('Call Sam tomorrow at 4pm', now);
      expect(r.title, 'Call Sam');
      expect(r.due, DateTime(2026, 10, 15));
      expect(r.dueTime, 16 * 60);
    });

    test('a time alone has no date', () {
      final r = parseQuickAdd('Stand-up 9:30', now);
      expect(r.dueTime, 9 * 60 + 30);
      expect(r.due, isNull);
      expect(r.title, 'Stand-up');
    });

    test('a repeat takes its first date and its time', () {
      final r = parseQuickAdd('Gym every mon, fri at 7am p2', now);
      expect(r.title, 'Gym');
      expect(r.recurrence?.weekdays, {1, 5});
      expect(r.due, DateTime(2026, 10, 16)); // next Friday; today is Wednesday
      expect(r.dueTime, 7 * 60);
      expect(r.priority, 2);
    });

    test('the repeat phrase stops at the first title word', () {
      final r = parseQuickAdd('Water plants every other day #home', now);
      expect(r.title, 'Water plants');
      expect(r.recurrence?.interval, 2);
      expect(r.projectName, 'home');
    });

    test('dates inside a repeat are not read twice', () {
      final r = parseQuickAdd('Report every month starting nov 3', now);
      expect(r.title, 'Report');
      expect(r.recurrence?.start, DateTime(2026, 11, 3));
      expect(r.due, DateTime(2026, 11, 3));
    });

    test('a typed date wins as the first date of a repeat', () {
      final r = parseQuickAdd('Review every week tomorrow', now);
      expect(r.recurrence, isNotNull);
      expect(r.due, DateTime(2026, 10, 15));
    });

    test('"every" as an ordinary word is not a repeat', () {
      final r = parseQuickAdd('Check every box', now);
      expect(r.recurrence, isNull);
      expect(r.title, 'Check every box');
    });

    test('a deadline in braces is separate from the due date', () {
      final r = parseQuickAdd('Submit report tomorrow {oct 30}', now);
      expect(r.due, DateTime(2026, 10, 15));
      expect(r.deadline, DateTime(2026, 10, 30));
      expect(r.title, 'Submit report');
    });

    test('braces that are not a date stay in the title', () {
      final r = parseQuickAdd('Format {name} placeholder', now);
      expect(r.deadline, isNull);
      expect(r.title, 'Format {name} placeholder');
    });

    test('reminders: a clock time and minutes before', () {
      final r = parseQuickAdd('Dentist tomorrow 3pm !30 min before !1h !14:00', now);
      expect(r.title, 'Dentist');
      expect(r.reminders, [const ReminderSpec.before(30), const ReminderSpec.before(60), const ReminderSpec.at(14 * 60)]);
      expect(r.dueTime, 15 * 60);
    });

    test('an exclamation mark in ordinary text is not a reminder', () {
      final r = parseQuickAdd('Wow! great !', now);
      expect(r.reminders, isEmpty);
      expect(r.title, 'Wow! great !');
    });

    test('smart dates off keeps dates, times and repeats as text, but explicit tokens still work', () {
      final r = parseQuickAdd('Call every day at 4pm {oct 30} !10m', now, parseDates: false);
      expect(r.recurrence, isNull);
      expect(r.dueTime, isNull);
      expect(r.deadline, DateTime(2026, 10, 30));
      expect(r.reminders, [const ReminderSpec.before(10)]);
      expect(r.title, 'Call every day at 4pm');
    });

    test('token spans cover the new kinds', () {
      const line = 'Pay rent every 2 months at 9am {nov 1} !15m';
      final r = parseQuickAdd(line, now);
      String text(QuickAddKind k) {
        final t = r.tokens.firstWhere((t) => t.kind == k);
        return line.substring(t.start, t.end);
      }

      expect(text(QuickAddKind.repeat), 'every 2 months at 9am');
      expect(text(QuickAddKind.deadline), '{nov 1}');
      expect(text(QuickAddKind.reminder), '!15m');
      expect(r.title, 'Pay rent');
    });
  });
}
