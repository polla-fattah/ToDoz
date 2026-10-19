import 'package:test/test.dart';
import 'package:taskflow_core/recurrence.dart';
import 'package:taskflow_core/reminder.dart';

// Wednesday 14 October 2026, 09:00.
final now = DateTime(2026, 10, 14, 9);

void main() {
  group('ReminderSpec', () {
    test('parses clock times and offsets', () {
      expect(parseReminderText('14:00'), const ReminderSpec.at(14 * 60));
      expect(parseReminderText('2pm'), const ReminderSpec.at(14 * 60));
      expect(parseReminderText('30 min before'), const ReminderSpec.before(30));
      expect(parseReminderText('45m'), const ReminderSpec.before(45));
      expect(parseReminderText('1h'), const ReminderSpec.before(60));
      expect(parseReminderText('2 hours before'), const ReminderSpec.before(120));
      expect(parseReminderText('1 day'), const ReminderSpec.before(1440));
      expect(parseReminderText('soon'), isNull);
      expect(parseReminderText('25:00'), isNull);
    });

    test('encode and decode round trip', () {
      for (final s in [const ReminderSpec.at(8 * 60 + 5), const ReminderSpec.before(90), const ReminderSpec.before(0)]) {
        expect(ReminderSpec.decode(s.encode()), s);
      }
      expect(ReminderSpec.decode('garbage'), isNull);
    });

    test('describes itself for the task page', () {
      expect(const ReminderSpec.at(14 * 60).describe(), 'At 14:00');
      expect(const ReminderSpec.at(14 * 60).describe(use24h: false), 'At 2:00 PM');
      expect(const ReminderSpec.before(0).describe(), 'When due');
      expect(const ReminderSpec.before(1).describe(), '1 minute before');
      expect(const ReminderSpec.before(30).describe(), '30 minutes before');
      expect(const ReminderSpec.before(60).describe(), '1 hour before');
      expect(const ReminderSpec.before(180).describe(), '3 hours before');
      expect(const ReminderSpec.before(2880).describe(), '2 days before');
    });
  });

  group('upcomingFires', () {
    ReminderTask task(String id, {String? date, String? time, List<ReminderSpec> reminders = const [], DateTime? snooze}) =>
        ReminderTask(id: id, title: 'T$id', dueDate: date, dueTime: time, reminders: reminders, snoozedUntil: snooze);

    test('a task with a due time gets an automatic reminder 30 minutes before', () {
      final f = upcomingFires([task('a', date: '2026-10-15', time: '10:00')], now);
      expect(f, hasLength(1));
      expect(f.single.at, DateTime(2026, 10, 15, 9, 30));
      expect(f.single.automatic, isTrue);
    });

    test('the automatic lead can be changed or turned off', () {
      final t = [task('a', date: '2026-10-15', time: '10:00')];
      expect(upcomingFires(t, now, autoLeadMinutes: 10).single.at, DateTime(2026, 10, 15, 9, 50));
      expect(upcomingFires(t, now, autoLeadMinutes: null), isEmpty);
    });

    test('a date without a time gets no automatic reminder', () {
      expect(upcomingFires([task('a', date: '2026-10-15')], now), isEmpty);
    });

    test('custom reminders: relative to the due time and at a clock time', () {
      final f = upcomingFires([
        task('a', date: '2026-10-15', time: '15:00', reminders: [const ReminderSpec.before(60), const ReminderSpec.at(8 * 60)]),
      ], now, autoLeadMinutes: null);
      expect(f.map((x) => x.at), [DateTime(2026, 10, 15, 8), DateTime(2026, 10, 15, 14)]);
    });

    test('a relative reminder needs a due time; a clock reminder works with a date alone', () {
      final f = upcomingFires([
        task('a', date: '2026-10-15', reminders: [const ReminderSpec.before(60), const ReminderSpec.at(8 * 60)]),
      ], now);
      expect(f.map((x) => x.at), [DateTime(2026, 10, 15, 8)]);
    });

    test('an explicit reminder at the automatic moment is not doubled', () {
      final f = upcomingFires([
        task('a', date: '2026-10-15', time: '10:00', reminders: [const ReminderSpec.before(30)]),
      ], now);
      expect(f, hasLength(1));
      expect(f.single.automatic, isFalse);
    });

    test('reminders in the past are dropped', () {
      final f = upcomingFires([
        task('old', date: '2026-10-14', time: '09:15'), // auto reminder at 08:45, already passed
        task('later', date: '2026-10-14', time: '10:00'), // auto at 09:30
      ], now);
      expect(f.map((x) => x.taskId), ['later']);
    });

    test('sorted soonest first and capped at the limit', () {
      final tasks = [
        for (var i = 0; i < 5; i++) task('t$i', date: '2026-10-${20 - i}', time: '10:00'),
      ];
      final f = upcomingFires(tasks, now, limit: 3);
      expect(f.map((x) => x.taskId), ['t4', 't3', 't2']);
    });

    test('snooze fires once at the snooze time, even with no date', () {
      final f = upcomingFires([task('a', snooze: DateTime(2026, 10, 14, 9, 10))], now);
      expect(f.single.at, DateTime(2026, 10, 14, 9, 10));
      expect(upcomingFires([task('a', snooze: DateTime(2026, 10, 14, 8))], now), isEmpty);
    });

    test('notification ids are stable and distinct per reminder', () {
      final a = upcomingFires([task('a', date: '2026-10-15', time: '10:00', reminders: [const ReminderSpec.before(60)])], now, autoLeadMinutes: 30);
      expect(a, hasLength(2));
      expect(a[0].notificationId, isNot(a[1].notificationId));
      final again = upcomingFires([task('a', date: '2026-10-15', time: '10:00', reminders: [const ReminderSpec.before(60)])], now, autoLeadMinutes: 30);
      expect(again.map((x) => x.notificationId), a.map((x) => x.notificationId));
    });
  });

  group('isOverdue (FR-D6)', () {
    test('a date without a time is overdue only after its day ends', () {
      expect(isOverdue(dueDate: '2026-10-14', now: DateTime(2026, 10, 14, 23, 0)), isFalse);
      expect(isOverdue(dueDate: '2026-10-13', now: now), isTrue);
    });
    test('a time earlier today is overdue only after that time', () {
      expect(isOverdue(dueDate: '2026-10-14', dueTime: '10:00', now: now), isFalse);
      expect(isOverdue(dueDate: '2026-10-14', dueTime: '08:00', now: now), isTrue);
    });
    test('no date is never overdue', () {
      expect(isOverdue(dueDate: null, now: now), isFalse);
    });
  });

  group('nextDueAfterCompletion (FR-R7)', () {
    Recurrence r(String s) => parseRecurrence(s, now);

    test('moves to the next date and keeps the time', () {
      final n = nextDueAfterCompletion(recurrence: r('every day'), dueDate: '2026-10-14', dueTime: '08:00', completedAt: now)!;
      expect((n.date, n.time), ('2026-10-15', '08:00'));
    });
    test('a time written in the repeat replaces the task time', () {
      final n = nextDueAfterCompletion(recurrence: r('every fri at 20:00'), dueDate: '2026-10-16', dueTime: '09:00', completedAt: DateTime(2026, 10, 16, 9))!;
      expect((n.date, n.time), ('2026-10-23', '20:00'));
    });
    test('hourly repeats move the clock time too', () {
      final n = nextDueAfterCompletion(recurrence: r('every 12 hours'), dueDate: '2026-10-14', dueTime: '21:00', completedAt: DateTime(2026, 10, 14, 21, 5))!;
      expect((n.date, n.time), ('2026-10-15', '09:00'));
    });
    test('a repeat that has ended returns null so the task just completes', () {
      expect(nextDueAfterCompletion(recurrence: r('every day until oct 14'), dueDate: '2026-10-14', completedAt: now), isNull);
    });
  });
}
