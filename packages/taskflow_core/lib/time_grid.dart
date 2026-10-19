/// The rules of the calendar views (Day, 3 Days, Month), as plain functions: where a task sits on the time grid,
/// how tasks that overlap share a column, which days a view shows and what dropping a task somewhere means.
///
/// The web client (server/web/src/lib/timegrid.ts) has the same functions with the same test cases, so every device
/// behaves the same. Change both together.
library;

import 'date_parser.dart';

const minutesPerDay = 1440;

/// A task with a time but no length is drawn this long.
const defaultBlockMinutes = 30;

/// Blocks are never drawn shorter than this, so they can be read and grabbed.
const minBlockMinutes = 15;

/// Moving and resizing snap to this.
const snapMinutes = 15;

/// `week` is for wide screens (web and desktop); phones show `day`, `threeDays` and `month`.
enum CalendarMode { day, threeDays, week, month }

/// "09:30" to 570; null for anything else.
int? minutesOf(String? hhmm) {
  if (hhmm == null) return null;
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm);
  if (m == null) return null;
  final h = int.parse(m[1]!), min = int.parse(m[2]!);
  return h < 24 && min < 60 ? h * 60 + min : null;
}

/// 570 to "09:30" (1440 and over wrap to the last minute of the day, never "24:00").
String formatMinutes(int minutes) {
  final m = minutes.clamp(0, minutesPerDay - 1);
  return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

/// The nearest multiple of [step], kept inside the day.
int snap(int minutes, {int step = snapMinutes}) => ((minutes / step).round() * step).clamp(0, minutesPerDay);

/// Where a task is drawn: from its start for its duration (or [defaultBlockMinutes]), kept inside the day and at
/// least [minBlockMinutes] long.
({int start, int end}) blockSpan(int start, int? durationMinutes) {
  final s = start.clamp(0, minutesPerDay - minBlockMinutes);
  final length = (durationMinutes == null || durationMinutes < 1) ? defaultBlockMinutes : durationMinutes;
  final e = (s + length).clamp(s + minBlockMinutes, minutesPerDay);
  return (start: s, end: e > minutesPerDay ? minutesPerDay : e);
}

class GridItem {
  const GridItem(this.id, this.start, this.end);
  final String id;
  final int start;
  final int end;
}

class PlacedItem {
  const PlacedItem(this.id, this.start, this.end, this.column, this.columns);
  final String id;
  final int start;
  final int end;

  /// Which column of its group the block takes (0 is leftmost), and how many columns the group has: the block is
  /// `1 / columns` wide and starts at `column / columns`.
  final int column;
  final int columns;

  @override
  bool operator ==(Object other) => other is PlacedItem && other.id == id && other.start == start && other.end == end && other.column == column && other.columns == columns;
  @override
  int get hashCode => Object.hash(id, start, end, column, columns);
  @override
  String toString() => '$id $start-$end col $column/$columns';
}

/// Lays the blocks of one day side by side where they overlap. Blocks that touch (one ends when the next starts)
/// do not overlap. Items that are linked through a chain of overlaps share one group, so they get the same width.
List<PlacedItem> layoutDay(List<GridItem> items) {
  final sorted = [...items]..sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : b.end.compareTo(a.end));
  final out = <PlacedItem>[];
  var group = <({GridItem item, int column})>[];
  var columnEnds = <int>[];
  var groupEnd = -1;

  void flush() {
    for (final g in group) {
      out.add(PlacedItem(g.item.id, g.item.start, g.item.end, g.column, columnEnds.length));
    }
    group = [];
    columnEnds = [];
    groupEnd = -1;
  }

  for (final item in sorted) {
    if (group.isNotEmpty && item.start >= groupEnd) flush();
    var column = columnEnds.indexWhere((end) => end <= item.start);
    if (column < 0) {
      column = columnEnds.length;
      columnEnds.add(item.end);
    } else {
      columnEnds[column] = item.end;
    }
    group.add((item: item, column: column));
    if (item.end > groupEnd) groupEnd = item.end;
  }
  flush();
  return out;
}

/// The days a view shows, as `YYYY-MM-DD`: one day, three days from [anchor], the seven days of the week that
/// contains [anchor], or the six weeks of a month grid that contains [anchor]. Weeks start on [weekStart]
/// (1 = Monday ... 7 = Sunday).
List<String> daysOf(CalendarMode mode, String anchor, {int weekStart = 1}) {
  final a = parseIsoDate(anchor)!;
  switch (mode) {
    case CalendarMode.day:
      return [anchor];
    case CalendarMode.threeDays:
      return [for (var i = 0; i < 3; i++) formatDate(DateTime(a.year, a.month, a.day + i))];
    case CalendarMode.week:
      final back = (a.weekday - weekStart + 7) % 7;
      return [for (var i = 0; i < 7; i++) formatDate(DateTime(a.year, a.month, a.day - back + i))];
    case CalendarMode.month:
      final first = DateTime(a.year, a.month, 1);
      final back = (first.weekday - weekStart + 7) % 7;
      return [for (var i = 0; i < 42; i++) formatDate(DateTime(first.year, first.month, 1 - back + i))];
  }
}

/// The anchor after pressing Previous (-1) or Next (+1): a day, three days, a week, or a month (the same day of
/// the month, or the last day of a shorter one).
String shiftAnchor(CalendarMode mode, String anchor, int direction) {
  final a = parseIsoDate(anchor)!;
  switch (mode) {
    case CalendarMode.day:
      return formatDate(DateTime(a.year, a.month, a.day + direction));
    case CalendarMode.threeDays:
      return formatDate(DateTime(a.year, a.month, a.day + 3 * direction));
    case CalendarMode.week:
      return formatDate(DateTime(a.year, a.month, a.day + 7 * direction));
    case CalendarMode.month:
      final first = DateTime(a.year, a.month + direction, 1);
      final last = DateTime(first.year, first.month + 1, 0).day;
      return formatDate(DateTime(first.year, first.month, a.day > last ? last : a.day));
  }
}

/// What dropping a task at a place means: its new date, and its time (null for the all-day row).
({String date, String? time}) dropAt({required String day, int? minutes}) =>
    (date: day, time: minutes == null ? null : formatMinutes(snap(minutes, step: snapMinutes).clamp(0, minutesPerDay - minBlockMinutes)));

/// The duration after dragging the bottom edge of a block that starts at [start] to [endMinutes]: snapped, at least
/// [minBlockMinutes], and not past the end of the day.
int resizeDuration(int start, int endMinutes) {
  final end = snap(endMinutes).clamp(start + minBlockMinutes, minutesPerDay);
  return end - start;
}
