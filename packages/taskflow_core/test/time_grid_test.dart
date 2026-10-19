import 'package:taskflow_core/time_grid.dart';
import 'package:test/test.dart';

// The cases below are repeated in server/web/src/lib/timegrid.test.ts. Keep them the same.
void main() {
  PlacedItem p(String id, int s, int e, int c, int n) => PlacedItem(id, s, e, c, n);
  GridItem g(String id, int s, int e) => GridItem(id, s, e);

  group('time and snapping', () {
    test('reads and writes HH:MM', () {
      expect(minutesOf('09:30'), 570);
      expect(minutesOf('9:05'), 545);
      expect(minutesOf('24:00'), isNull);
      expect(minutesOf('12:60'), isNull);
      expect(minutesOf('noon'), isNull);
      expect(minutesOf(null), isNull);
      expect(formatMinutes(570), '09:30');
      expect(formatMinutes(0), '00:00');
      expect(formatMinutes(1440), '23:59');
    });

    test('snaps to the nearest quarter hour inside the day', () {
      expect(snap(7), 0);
      expect(snap(8), 15);
      expect(snap(22), 15);
      expect(snap(23), 30);
      expect(snap(-30), 0);
      expect(snap(1500), 1440);
    });

    test('a block lasts its duration, or half an hour, never less than a quarter, never past midnight', () {
      expect(blockSpan(540, null), (start: 540, end: 570));
      expect(blockSpan(540, 90), (start: 540, end: 630));
      expect(blockSpan(540, 5), (start: 540, end: 555));
      expect(blockSpan(1420, 60), (start: 1420, end: 1440));
      expect(blockSpan(1439, null), (start: 1425, end: 1440));
      expect(blockSpan(540, 0), (start: 540, end: 570));
    });
  });

  group('overlapping blocks', () {
    test('blocks that do not overlap each have a whole column; touching is not overlapping', () {
      expect(layoutDay([g('a', 540, 600), g('b', 600, 660)]), [p('a', 540, 600, 0, 1), p('b', 600, 660, 0, 1)]);
    });

    test('two that overlap sit side by side', () {
      expect(layoutDay([g('a', 540, 630), g('b', 570, 660)]), [p('a', 540, 630, 0, 2), p('b', 570, 660, 1, 2)]);
    });

    test('a chain of overlaps shares one width, and a freed column is reused', () {
      expect(layoutDay([g('a', 540, 600), g('b', 570, 630), g('c', 600, 660)]), [p('a', 540, 600, 0, 2), p('b', 570, 630, 1, 2), p('c', 600, 660, 0, 2)]);
    });

    test('three at the same time get three columns', () {
      final r = layoutDay([g('a', 540, 600), g('b', 540, 600), g('c', 540, 600)]);
      expect(r.map((x) => x.column), [0, 1, 2]);
      expect(r.every((x) => x.columns == 3), isTrue);
    });

    test('separate groups are independent', () {
      expect(layoutDay([g('late2', 870, 930), g('early', 540, 600), g('late1', 840, 900)]),
          [p('early', 540, 600, 0, 1), p('late1', 840, 900, 0, 2), p('late2', 870, 930, 1, 2)]);
    });

    test('a long block comes first when two start together', () {
      final r = layoutDay([g('short', 540, 570), g('long', 540, 660)]);
      expect(r.firstWhere((x) => x.id == 'long').column, 0);
      expect(r.firstWhere((x) => x.id == 'short').column, 1);
    });

    test('nothing in, nothing out', () => expect(layoutDay([]), isEmpty));
  });

  group('which days a view shows', () {
    test('a day, three days, or the six weeks of a month grid', () {
      expect(daysOf(CalendarMode.day, '2026-10-19'), ['2026-10-19']);
      expect(daysOf(CalendarMode.threeDays, '2026-10-30'), ['2026-10-30', '2026-10-31', '2026-11-01']);
      final monday = daysOf(CalendarMode.month, '2026-10-19', weekStart: 1);
      expect(monday, hasLength(42));
      expect(monday.first, '2026-09-28');
      expect(monday.last, '2026-11-08');
      expect(daysOf(CalendarMode.month, '2026-10-19', weekStart: 7).first, '2026-09-27');
      expect(daysOf(CalendarMode.month, '2026-11-15', weekStart: 1).first, '2026-10-26');
    });

    test('a week is the seven days around the anchor, from the first day of the week', () {
      expect(daysOf(CalendarMode.week, '2026-10-21', weekStart: 1), ['2026-10-19', '2026-10-20', '2026-10-21', '2026-10-22', '2026-10-23', '2026-10-24', '2026-10-25']);
      expect(daysOf(CalendarMode.week, '2026-10-21', weekStart: 7).first, '2026-10-18');
      expect(daysOf(CalendarMode.week, '2026-10-25', weekStart: 1).first, '2026-10-19', reason: 'a Sunday belongs to the week before when weeks start on Monday');
      expect(daysOf(CalendarMode.week, '2026-11-01', weekStart: 1), contains('2026-10-26'));
    });

    test('previous and next move by a day, three days or a month', () {
      expect(shiftAnchor(CalendarMode.day, '2026-10-31', 1), '2026-11-01');
      expect(shiftAnchor(CalendarMode.day, '2026-03-01', -1), '2026-02-28');
      expect(shiftAnchor(CalendarMode.threeDays, '2026-10-29', 1), '2026-11-01');
      expect(shiftAnchor(CalendarMode.threeDays, '2026-10-19', -1), '2026-10-16');
      expect(shiftAnchor(CalendarMode.week, '2026-10-29', 1), '2026-11-05');
      expect(shiftAnchor(CalendarMode.week, '2026-10-05', -1), '2026-09-28');
      expect(shiftAnchor(CalendarMode.month, '2026-10-19', 1), '2026-11-19');
      expect(shiftAnchor(CalendarMode.month, '2026-01-31', 1), '2026-02-28');
      expect(shiftAnchor(CalendarMode.month, '2026-01-15', -1), '2025-12-15');
    });
  });

  group('dropping and resizing', () {
    test('a drop gives a date and a snapped time, or no time in the all-day row', () {
      expect(dropAt(day: '2026-10-20', minutes: 553), (date: '2026-10-20', time: '09:15'));
      expect(dropAt(day: '2026-10-20', minutes: 600), (date: '2026-10-20', time: '10:00'));
      expect(dropAt(day: '2026-10-20'), (date: '2026-10-20', time: null));
      expect(dropAt(day: '2026-10-20', minutes: 1439), (date: '2026-10-20', time: '23:45'), reason: 'room for a quarter hour');
    });

    test('resizing snaps, keeps at least a quarter hour, and stops at midnight', () {
      expect(resizeDuration(540, 647), 105);
      expect(resizeDuration(540, 541), 15);
      expect(resizeDuration(540, 500), 15);
      expect(resizeDuration(1380, 1500), 60);
    });
  });
}
