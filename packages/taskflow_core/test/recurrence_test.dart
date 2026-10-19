import 'package:test/test.dart';
import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/recurrence.dart';

// Wednesday 14 October 2026.
final now = DateTime(2026, 10, 14, 9);

Recurrence parse(String s) => parseRecurrence(s, now);

/// The date after finishing [due] on [done] (both "yyyy-mm-dd").
String? next(String phrase, String due, {String? done}) {
  final r = parse(phrase);
  final result = nextOccurrence(r, currentDue: parseIsoDate(due)!, completedOn: parseIsoDate(done ?? due)!);
  return result == null ? null : formatDate(result);
}

void main() {
  group('FR-R1 basic phrases', () {
    test('every day, daily', () {
      expect(next('every day', '2026-10-14'), '2026-10-15');
      expect(next('daily', '2026-10-14'), '2026-10-15');
    });
    test('every weekday skips the weekend', () {
      expect(next('every weekday', '2026-10-16'), '2026-10-19'); // Fri -> Mon
      expect(next('every workday', '2026-10-14'), '2026-10-15');
    });
    test('every week, month, year', () {
      expect(next('every week', '2026-10-14'), '2026-10-21');
      expect(next('weekly', '2026-10-14'), '2026-10-21');
      expect(next('every month', '2026-10-14'), '2026-11-14');
      expect(next('monthly', '2026-10-14'), '2026-11-14');
      expect(next('every year', '2026-10-14'), '2027-10-14');
      expect(next('yearly', '2026-10-14'), '2027-10-14');
    });
    test('a month shorter than the day clamps to its last day', () {
      expect(next('every month', '2026-01-31'), '2026-02-28');
      expect(next('every month', '2028-01-31'), '2028-02-29');
    });
    test('a leap day falls back to 28 February', () {
      expect(next('every year', '2028-02-29'), '2029-02-28');
    });
  });

  group('FR-R2 intervals', () {
    test('every other week, every 3 days, every 2 months, every quarter', () {
      expect(next('every other week', '2026-10-14'), '2026-10-28');
      expect(next('every other day', '2026-10-14'), '2026-10-16');
      expect(next('every 3 days', '2026-10-14'), '2026-10-17');
      expect(next('every 2 months', '2026-10-14'), '2026-12-14');
      expect(next('every quarter', '2026-10-14'), '2027-01-14');
      expect(next('every 2 years', '2026-10-14'), '2028-10-14');
    });
    test('every 3 workdays counts business days', () {
      expect(next('every 3 workdays', '2026-10-14'), '2026-10-19'); // Thu, Fri, Mon
    });
    test('the number must be positive', () {
      expect(() => parse('every 0 days'), throwsA(isA<RecurrenceException>()));
    });
  });

  group('FR-R3 lists', () {
    test('every mon, fri', () {
      expect(next('every mon, fri', '2026-10-14'), '2026-10-16');
      expect(next('every mon, fri', '2026-10-16'), '2026-10-19');
      expect(next('every mon and fri', '2026-10-14'), '2026-10-16');
    });
    test('every other fri keeps alternate weeks', () {
      expect(next('every other fri', '2026-10-16'), '2026-10-30');
      // Thu 15 Oct is in an "on" week; Mon 19 and Thu 22 are the off week, so the next is Mon 26.
      expect(next('every other mon, thu', '2026-10-15'), '2026-10-26');
    });
    test('days of the month', () {
      expect(next('every 2, 15, 27', '2026-10-15'), '2026-10-27');
      expect(next('every 2, 15, 27', '2026-10-27'), '2026-11-02');
      expect(next('every 15th', '2026-10-15'), '2026-11-15');
      expect(next('every last day', '2026-10-31'), '2026-11-30');
    });
    test('a day missing from a month is skipped', () {
      expect(next('every 31', '2026-10-31'), '2026-12-31'); // November has no 31st
    });
    test('dates in a year', () {
      expect(next('every 14 jan, 15 jun', '2026-06-15'), '2027-01-14');
      expect(next('every jan 14', '2026-10-14'), '2027-01-14');
    });
    test('nth weekday of the month, optionally of one month', () {
      expect(next('every 1st wed', '2026-10-07'), '2026-11-04');
      expect(next('every last fri', '2026-10-30'), '2026-11-27');
      expect(next('every 1st wed jan', '2026-01-07'), '2027-01-06');
      expect(next('every 2nd sun', '2026-10-11'), '2026-11-08');
    });
    test('last and numbered workdays of the month', () {
      expect(next('every last workday', '2026-10-30'), '2026-11-30');
      expect(next('every 15th workday', '2026-10-14'), '2026-10-21');
      expect(next('every first workday', '2026-10-01'), '2026-11-02');
    });
  });

  group('FR-R4 bounds', () {
    test('until is inclusive and then the repeat ends', () {
      expect(next('every day until oct 16', '2026-10-15'), '2026-10-16');
      expect(next('every day until oct 16', '2026-10-16'), isNull);
    });
    test('for N units ends N units after the start', () {
      expect(parse('every day for 3 weeks').until, DateTime(2026, 11, 4));
      expect(parse('every day starting oct 20 for 1 week').until, DateTime(2026, 10, 27));
    });
    test('starting delays the first occurrence', () {
      final r = parse('every day starting oct 20');
      expect(r.start, DateTime(2026, 10, 20));
      expect(firstOccurrence(r, now), DateTime(2026, 10, 20));
    });
    test('from X until Y', () {
      final r = parse('every day from 10 may until 20 may');
      expect(r.start, DateTime(2027, 5, 10));
      expect(r.until, DateTime(2027, 5, 20));
    });
    test('an end before the start is refused', () {
      expect(() => parse('every day starting nov 10 until nov 1'), throwsA(isA<RecurrenceException>()));
    });
  });

  group('FR-R5 times', () {
    test('a time applies to the whole repeat', () {
      expect(parse('every fri at noon').timeMinutes, 720);
      expect(parse('every mon, fri at 20:00').timeMinutes, 1200);
      expect(parse('every mon, fri at 20:00').weekdays, {1, 5});
      expect(parse('every day at 7am').timeMinutes, 420);
    });
    test('a time without "at" and a start date', () {
      final r = parse('every other tues 7am starting 1 nov');
      expect(r.weekdays, {2});
      expect((r.interval, r.timeMinutes, r.start), (2, 420, DateTime(2026, 11, 1)));
      expect(firstOccurrence(r, now), DateTime(2026, 11, 3)); // first Tuesday on or after the start
      final d = parse('every 14 days 7am starting 1 nov');
      expect((d.kind, d.interval, d.timeMinutes), (RecurKind.days, 14, 420));
      expect(firstOccurrence(d, now), DateTime(2026, 11, 1));
    });
    test('every 12 hours starting at 9pm steps in hours', () {
      final r = parse('every 12 hours starting at 9pm');
      expect((r.kind, r.interval, r.timeMinutes), (RecurKind.hours, 12, 1260));
      final nextDue = nextMoment(r, currentDue: DateTime(2026, 10, 14, 21), completedAt: DateTime(2026, 10, 14, 21, 5));
      expect(nextDue, DateTime(2026, 10, 15, 9));
    });
    test('finishing an hourly task late jumps to the next future slot', () {
      final r = parse('every 6 hours');
      final nextDue = nextMoment(r, currentDue: DateTime(2026, 10, 14, 6), completedAt: DateTime(2026, 10, 14, 20));
      expect(nextDue, DateTime(2026, 10, 15, 0));
    });
  });

  group('FR-R6 every! counts from completion', () {
    test('every! and after N days', () {
      expect(parse('every! 2 months').fromCompletion, isTrue);
      expect(next('every! 2 months', '2026-10-01', done: '2026-10-14'), '2026-12-14');
      expect(next('after 10 days', '2026-10-01', done: '2026-10-14'), '2026-10-24');
      expect(next('every! mon', '2026-10-01', done: '2026-10-14'), '2026-10-19');
    });
    test('fixed schedules stay on their cycle, completion-based ones move', () {
      expect(next('every 3 days', '2026-10-10', done: '2026-10-14'), '2026-10-16');
      expect(next('every! 3 days', '2026-10-10', done: '2026-10-14'), '2026-10-17');
    });
    test('finishing an overdue fixed repeat lands in the future', () {
      expect(next('every day', '2026-10-10', done: '2026-10-14'), '2026-10-15');
      expect(next('every week', '2026-10-07', done: '2026-10-14'), '2026-10-21');
    });
  });

  group('FR-R10 unsupported phrases are refused with a reason', () {
    void refuses(String phrase, Pattern reason) {
      expect(() => parse(phrase), throwsA(isA<RecurrenceException>().having((e) => e.message, 'message', contains(reason))));
    }

    test('different times per day', () => refuses('every mon at 8pm, tue at 9pm', 'One time'));
    test('every day except', () => refuses('every day except fri', 'except'));
    test('monthly interval with a weekday', () => refuses('every 2 months on the first friday', 'weekday'));
    test('two everys', () => refuses('every mon every tue', 'Only one'));
    test('not starting with every', () => refuses('mon and fri', 'every'));
    test('gibberish', () => refuses('every blue moon', 'do not understand'));
    test('a bad bound date', () => refuses('every day until nonsense', 'date'));
    test('an impossible date', () => refuses('every feb 30', 'not a real date'));
    test('an empty phrase', () => refuses('', 'how often'));
  });

  group('first occurrence', () {
    test('every day starts today; every mon starts next Monday', () {
      expect(firstOccurrence(parse('every day'), now), DateTime(2026, 10, 14));
      expect(firstOccurrence(parse('every mon'), now), DateTime(2026, 10, 19));
      expect(firstOccurrence(parse('every wed'), now), DateTime(2026, 10, 14)); // today counts
    });
    test('every other fri starts on the second Friday from now', () {
      expect(firstOccurrence(parse('every other fri'), now), DateTime(2026, 10, 23));
    });
    test('list and ordinal repeats start at their next date', () {
      expect(firstOccurrence(parse('every 2, 15'), now), DateTime(2026, 10, 15));
      expect(firstOccurrence(parse('every 15th workday'), now), DateTime(2026, 10, 21));
      expect(firstOccurrence(parse('every 3 workdays'), now), DateTime(2026, 10, 14));
    });
  });

  group('the dates a repeat comes round again (for a calendar)', () {
    List<String> dates(String phrase, String due, String to) =>
        [for (final d in occurrencesBetween(parse(phrase), due: parseIsoDate(due)!, to: parseIsoDate(to)!)) formatDate(d)];

    test('every mon, fri lists each one after the due date, up to the end', () {
      expect(dates('every mon, fri', '2026-10-16', '2026-10-27'), ['2026-10-19', '2026-10-23', '2026-10-26']);
    });
    test('every day stops at the end date and never includes the due date itself', () {
      expect(dates('every day', '2026-10-14', '2026-10-17'), ['2026-10-15', '2026-10-16', '2026-10-17']);
    });
    test('every other week keeps its rhythm', () {
      expect(dates('every other week', '2026-10-14', '2026-11-30'), ['2026-10-28', '2026-11-11', '2026-11-25']);
    });
    test('a repeat with an until stops at it', () {
      expect(dates('every day until oct 16', '2026-10-14', '2026-10-30'), ['2026-10-15', '2026-10-16']);
    });
    test('month days and the last workday', () {
      expect(dates('every 2, 15', '2026-10-15', '2026-11-20'), ['2026-11-02', '2026-11-15']);
      expect(dates('every last workday', '2026-10-30', '2026-12-31'), ['2026-11-30', '2026-12-31']);
    });
    test('hourly and counted-from-completion repeats give none (they depend on when each is done)', () {
      expect(dates('every 12 hours', '2026-10-14', '2026-10-30'), isEmpty);
      expect(dates('every! 2 days', '2026-10-14', '2026-10-30'), isEmpty);
    });
    test('a window before the due date gives none', () {
      expect(dates('every day', '2026-10-14', '2026-10-10'), isEmpty);
    });
  });

  group('finding a repeat inside a line', () {
    String? span(String line) {
      final m = findRecurrence(line, now).match;
      return m == null ? null : line.substring(m.start, m.end);
    }

    test('stops at the first word that is not repeat vocabulary', () {
      expect(span('Water plants every other day #home'), 'every other day');
      expect(span('Pay rent every 2 months p1'), 'every 2 months');
      expect(span('Gym every mon, wed, fri at 7am'), 'every mon, wed, fri at 7am');
    });
    test('trailing words that do not parse are given back to the title', () {
      expect(span('Report every month for the team'), 'every month');
    });
    test('after N days is a repeat, but a bare "after" is not', () {
      final m = findRecurrence('Call Sam after 3 days', now).match!;
      expect(m.recurrence.fromCompletion, isTrue);
      expect(span('Meet after lunch'), isNull);
    });
    test('"every" used as an ordinary word is left alone', () {
      final r = findRecurrence('Check every box', now);
      expect(r.match, isNull);
      expect(r.error, isNull);
    });
    test('words after a valid repeat that merely look like repeat words stay in the title', () {
      // "every day" is fine on its own; "except fri" is left as title text.
      final r = findRecurrence('Run every day except fri', now);
      expect(r.match, isNotNull);
    });
  });
}
