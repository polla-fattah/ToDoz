import 'package:test/test.dart';
import 'package:taskflow_core/date_parser.dart';

// Wednesday 14 October 2026.
final now = DateTime(2026, 10, 14, 15, 30);

DateTime? d(String text, {int weekStart = 1}) =>
    parseDate(text, now, weekStart: weekStart)?.date;

void main() {
  group('relative phrases', () {
    test('today, tonight, tomorrow', () {
      expect(d('today'), DateTime(2026, 10, 14));
      expect(d('tonight'), DateTime(2026, 10, 14));
      expect(d('tomorrow'), DateTime(2026, 10, 15));
      expect(d('tmrw'), DateTime(2026, 10, 15));
    });

    test('next week means the start of next week', () {
      expect(d('next week'), DateTime(2026, 10, 19)); // Monday
      expect(d('next week', weekStart: 7), DateTime(2026, 10, 18)); // Sunday start
    });

    test('next month keeps the day, clamping short months', () {
      expect(d('next month'), DateTime(2026, 11, 14));
      expect(addMonths(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 28));
      expect(addMonths(DateTime(2028, 1, 31), 1), DateTime(2028, 2, 29));
      expect(addMonths(DateTime(2026, 12, 15), 2), DateTime(2027, 2, 15));
    });

    test('in N units and N units from now', () {
      expect(d('in 3 days'), DateTime(2026, 10, 17));
      expect(d('in 2 weeks'), DateTime(2026, 10, 28));
      expect(d('in 1 month'), DateTime(2026, 11, 14));
      expect(d('3 days from now'), DateTime(2026, 10, 17));
      expect(d('2 weeks from now'), DateTime(2026, 10, 28));
    });

    test('end of month', () {
      expect(d('end of month'), DateTime(2026, 10, 31));
      expect(d('end of the month'), DateTime(2026, 10, 31));
    });
  });

  group('weekdays', () {
    test('a bare weekday is the next occurrence after today', () {
      expect(d('fri'), DateTime(2026, 10, 16));
      expect(d('friday'), DateTime(2026, 10, 16));
      expect(d('mon'), DateTime(2026, 10, 19));
      expect(d('wed'), DateTime(2026, 10, 21)); // today is Wednesday
    });

    test('next <weekday> is that day in the following week', () {
      expect(d('next mon'), DateTime(2026, 10, 19));
      expect(d('next fri'), DateTime(2026, 10, 23));
      expect(d('next sun'), DateTime(2026, 10, 25));
    });
  });

  group('calendar dates', () {
    test('month and day, either order', () {
      expect(d('oct 20'), DateTime(2026, 10, 20));
      expect(d('20 oct'), DateTime(2026, 10, 20));
      expect(d('october 20th'), DateTime(2026, 10, 20));
      expect(d('20th of october'), DateTime(2026, 10, 20));
    });

    test('a date already past this year rolls to next year', () {
      expect(d('oct 10'), DateTime(2027, 10, 10));
      expect(d('jan 5'), DateTime(2027, 1, 5));
      expect(d('5 jan'), DateTime(2027, 1, 5));
    });

    test('explicit year', () {
      expect(d('march 3 2028'), DateTime(2028, 3, 3));
      expect(d('3 mar, 2028'), DateTime(2028, 3, 3));
      expect(d('2026-12-25'), DateTime(2026, 12, 25));
    });

    test('impossible dates are not recognised', () {
      expect(d('feb 30'), isNull);
      expect(d('2026-02-31'), isNull);
      expect(d('oct 32'), isNull);
    });
  });

  group('false positives', () {
    test('words that only contain month or weekday letters', () {
      expect(d('market 5'), isNull);
      expect(d('monday-ish thinking'), isNotNull); // "monday" is a real weekday
      expect(d('decide on a plan'), isNull);
      expect(d('Review paper'), isNull);
    });

    test('numbers on their own are not dates', () {
      expect(d('buy 5 apples'), isNull);
      expect(d('chapter 12'), isNull);
    });
  });

  group('spans and precedence', () {
    test('reports where the phrase sits', () {
      final m = parseDate('Call Sam next fri about it', now)!;
      expect('Call Sam next fri about it'.substring(m.start, m.end), 'next fri');
    });

    test('the earliest phrase wins; at one start the longer wins', () {
      final m = parseDate('tomorrow or fri', now)!;
      expect(m.date, DateTime(2026, 10, 15));
      expect(parseDate('next fri', now)!.end, 8);
    });

    test('is case-insensitive', () {
      expect(d('TOMORROW'), DateTime(2026, 10, 15));
      expect(d('Next Fri'), DateTime(2026, 10, 23));
    });
  });

  group('helpers', () {
    test('formatDate and parseIsoDate round trip', () {
      expect(formatDate(DateTime(2026, 3, 4)), '2026-03-04');
      expect(parseIsoDate('2026-03-04'), DateTime(2026, 3, 4));
      expect(parseIsoDate('2026-13-01'), isNull);
      expect(parseIsoDate('nope'), isNull);
    });
  });

  group('time of day', () {
    int? t(String text) => parseTime(text)?.minutes;

    test('12-hour times', () {
      expect(t('4pm'), 16 * 60);
      expect(t('at 4 pm'), 16 * 60);
      expect(t('4:30pm'), 16 * 60 + 30);
      expect(t('12am'), 0);
      expect(t('12pm'), 12 * 60);
      expect(t('9AM'), 9 * 60);
    });
    test('24-hour times', () {
      expect(t('16:30'), 16 * 60 + 30);
      expect(t('at 07:05'), 7 * 60 + 5);
      expect(t('0:00'), 0);
      expect(t('23:59'), 23 * 60 + 59);
    });
    test('noon and midnight', () {
      expect(t('at noon'), 720);
      expect(t('midday'), 720);
      expect(t('midnight'), 0);
    });
    test('things that are not times', () {
      expect(t('at 5'), isNull); // a bare hour is too ambiguous
      expect(t('buy 5 apples'), isNull);
      expect(t('13pm'), isNull);
      expect(t('0am'), isNull);
      expect(t('25:00'), isNull);
      expect(t('9:75'), isNull);
    });
    test('reports where it sits, including "at"', () {
      const line = 'Call Sam tomorrow at 4pm please';
      final m = parseTime(line)!;
      expect(line.substring(m.start, m.end), 'at 4pm');
    });
    test('formatTime and parseClock round trip', () {
      expect(formatTime(16 * 60 + 5), '16:05');
      expect(formatTime(0, use24h: false), '12:00 AM');
      expect(formatTime(13 * 60, use24h: false), '1:00 PM');
      expect(parseClock('07:30'), 450);
      expect(parseClock('7:30'), isNull);
      expect(parseClock('24:00'), isNull);
    });
    test('dueMoment: a date alone ends at midnight, a time is exact', () {
      expect(dueMoment('2026-10-14', null), DateTime(2026, 10, 14, 23, 59, 59));
      expect(dueMoment('2026-10-14', '16:30'), DateTime(2026, 10, 14, 16, 30));
    });
  });
}
