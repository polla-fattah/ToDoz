/// Natural-language date recognition for Quick Add (FR-Q3, R1 subset).
///
/// Pure Dart, no Flutter imports, so it can be shared with the server later.
/// Times of day and recurrence are R2; numeric `1/5` dates wait for the
/// date-format setting (FR-D5).
library;

/// A date phrase found in text, with the span it occupies.
class DateMatch {
  const DateMatch(this.date, this.start, this.end);

  /// Calendar date (time of day is always midnight, local).
  final DateTime date;
  final int start;
  final int end;

  @override
  String toString() => 'DateMatch($date, $start-$end)';
}

const _months = {
  'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3,
  'apr': 4, 'april': 4, 'may': 5, 'jun': 6, 'june': 6, 'jul': 7, 'july': 7,
  'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9, 'oct': 10,
  'october': 10, 'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
};

const _weekdays = {
  'mon': 1, 'monday': 1, 'tue': 2, 'tues': 2, 'tuesday': 2, 'wed': 3,
  'wednesday': 3, 'thu': 4, 'thur': 4, 'thurs': 4, 'thursday': 4, 'fri': 5,
  'friday': 5, 'sat': 6, 'saturday': 6, 'sun': 7, 'sunday': 7,
};

const _monthPattern =
    r'(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|'
    r'august|aug|september|sept|sep|october|oct|november|nov|december|dec)';
const _weekdayPattern =
    r'(monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|'
    r'friday|fri|saturday|sat|sunday|sun)';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Adds [months] calendar months, clamping the day (31 Jan + 1 month = 28/29 Feb).
DateTime addMonths(DateTime d, int months) {
  final total = d.year * 12 + (d.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, d.day > lastDay ? lastDay : d.day);
}

/// `YYYY-MM-DD` as stored in the database.
String formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? parseIsoDate(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final date = DateTime(y, mo, d);
  // Reject 2026-02-31 style dates that DateTime silently rolls over.
  if (date.year != y || date.month != mo || date.day != d) return null;
  return date;
}

/// Finds the first date phrase in [text], or null.
///
/// [now] is injected so tests are deterministic. [weekStart] is the first day
/// of the week (1 = Monday ... 7 = Sunday); `next week` means the start of
/// the next week, as Todoist does.
DateMatch? parseDate(String text, DateTime now, {int weekStart = 1}) {
  final today = dateOnly(now);
  final candidates = <DateMatch>[];

  void add(RegExp re, DateTime? Function(RegExpMatch m) build) {
    for (final m in re.allMatches(text)) {
      final date = build(m);
      if (date != null) candidates.add(DateMatch(date, m.start, m.end));
    }
  }

  RegExp r(String p) => RegExp(p, caseSensitive: false);

  add(r(r'\b\d{4}-\d{2}-\d{2}\b'), (m) => parseIsoDate(m[0]!));
  add(r(r'\btoday\b|\btonight\b'), (_) => today);
  add(r(r'\btomorrow\b|\btmrw\b|\btmr\b'), (_) => today.add(const Duration(days: 1)));
  add(r(r'\bnext\s+week\b'), (_) {
    final daysUntil = (weekStart - today.weekday + 7) % 7;
    return today.add(Duration(days: daysUntil == 0 ? 7 : daysUntil));
  });
  add(r(r'\bnext\s+month\b'), (_) => addMonths(today, 1));
  add(r(r'\bend\s+of\s+(?:the\s+)?month\b'),
      (_) => DateTime(today.year, today.month + 1, 0));
  add(r(r'\bin\s+(\d{1,3})\s+(day|days|week|weeks|month|months)\b'),
      (m) => _offset(today, int.parse(m[1]!), m[2]!));
  add(r(r'\b(\d{1,3})\s+(day|days|week|weeks|month|months)\s+from\s+now\b'),
      (m) => _offset(today, int.parse(m[1]!), m[2]!));

  // "next fri" = that weekday in the following week; bare "fri" = the next
  // occurrence strictly after today.
  add(r('\\b(next\\s+)?$_weekdayPattern\\b'), (m) {
    final wd = _weekdays[m[2]!.toLowerCase()]!;
    var ahead = (wd - today.weekday + 7) % 7;
    if (ahead == 0) ahead = 7;
    if (m[1] != null) {
      final startOfNextWeek = (weekStart - today.weekday + 7) % 7;
      final nextWeekStart = startOfNextWeek == 0 ? 7 : startOfNextWeek;
      final inWeek = (wd - weekStart + 7) % 7;
      ahead = nextWeekStart + inWeek;
    }
    return today.add(Duration(days: ahead));
  });

  // "jan 5", "jan 5th", "jan 5 2027", "january 5, 2027"
  add(r('\\b(?:on\\s+)?$_monthPattern\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?\\b'),
      (m) => _monthDay(today, m[1]!, m[2]!, m[3]));
  // "5 jan", "5th of january", "5 jan 2027"
  add(r('\\b(?:on\\s+)?(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?$_monthPattern\\b(?:,?\\s+(\\d{4}))?'),
      (m) => _monthDay(today, m[2]!, m[1]!, m[3]));

  if (candidates.isEmpty) return null;
  // Earliest start wins; at the same start the longer phrase wins.
  candidates.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : (b.end - b.start).compareTo(a.end - a.start);
  });
  return candidates.first;
}

DateTime? _offset(DateTime today, int n, String unit) {
  final u = unit.toLowerCase();
  if (u.startsWith('day')) return today.add(Duration(days: n));
  if (u.startsWith('week')) return today.add(Duration(days: 7 * n));
  return addMonths(today, n);
}

DateTime? _monthDay(DateTime today, String monthName, String dayText, String? yearText) {
  final month = _months[monthName.toLowerCase()]!;
  final day = int.parse(dayText);
  if (day < 1 || day > 31) return null;
  if (yearText != null) {
    final y = int.parse(yearText);
    final d = DateTime(y, month, day);
    return (d.month == month && d.day == day) ? d : null;
  }
  var d = DateTime(today.year, month, day);
  if (d.month != month || d.day != day) return null; // e.g. 30 Feb
  if (d.isBefore(today)) {
    d = DateTime(today.year + 1, month, day);
    if (d.month != month || d.day != day) return null;
  }
  return d;
}

// -----------------------------------------------------------------------------
// Time of day (FR-Q3, FR-D1)
// -----------------------------------------------------------------------------

/// A time of day found in text, as minutes after midnight (0-1439).
class TimeMatch {
  const TimeMatch(this.minutes, this.start, this.end);
  final int minutes;
  final int start;
  final int end;

  @override
  String toString() => 'TimeMatch(${formatTime(minutes)}, $start-$end)';
}

/// Finds the first time of day in [text]: `4pm`, `at 4 pm`, `16:30`,
/// `4:30pm`, `noon`, `midnight`. A bare hour such as "at 5" is not a time:
/// it is too easily part of a title ("chapter at 5 points").
TimeMatch? parseTime(String text) {
  final found = <TimeMatch>[];
  RegExp r(String p) => RegExp(p, caseSensitive: false);

  for (final m in r(r'\b(?:at\s+)?(noon|midday|midnight)\b').allMatches(text)) {
    found.add(TimeMatch(m[1]!.toLowerCase() == 'midnight' ? 0 : 720, m.start, m.end));
  }
  // 16:30, 4:30pm. A trailing "am/pm" decides 12- or 24-hour reading.
  for (final m in r(r'\b(?:at\s+)?(\d{1,2}):(\d{2})(?:\s*(am|pm))?\b').allMatches(text)) {
    final t = _clock(int.parse(m[1]!), int.parse(m[2]!), m[3]);
    if (t != null) found.add(TimeMatch(t, m.start, m.end));
  }
  for (final m in r(r'\b(?:at\s+)?(\d{1,2})\s*(am|pm)\b').allMatches(text)) {
    final t = _clock(int.parse(m[1]!), 0, m[2]);
    if (t != null) found.add(TimeMatch(t, m.start, m.end));
  }
  if (found.isEmpty) return null;
  found.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : (b.end - b.start).compareTo(a.end - a.start);
  });
  return found.first;
}

int? _clock(int h, int m, String? meridiem) {
  if (m > 59) return null;
  if (meridiem != null) {
    if (h < 1 || h > 12) return null;
    final pm = meridiem.toLowerCase() == 'pm';
    return ((h % 12) + (pm ? 12 : 0)) * 60 + m;
  }
  if (h > 23) return null;
  return h * 60 + m;
}

/// `HH:MM` as stored in the database.
String formatTime(int minutes, {bool use24h = true}) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (use24h) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${m.toString().padLeft(2, '0')} ${h < 12 ? 'AM' : 'PM'}';
}

int? parseClock(String s) {
  final m = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(s);
  if (m == null) return null;
  return _clock(int.parse(m[1]!), int.parse(m[2]!), null);
}

/// Combines a stored date (`YYYY-MM-DD`) and optional time (`HH:MM`) into a
/// local [DateTime]. Without a time the result is the end of that day, which
/// is when a date-only task becomes overdue.
DateTime dueMoment(String date, String? time) {
  final d = parseIsoDate(date)!;
  final t = time == null ? null : parseClock(time);
  return t == null ? DateTime(d.year, d.month, d.day, 23, 59, 59) : DateTime(d.year, d.month, d.day, t ~/ 60, t % 60);
}
