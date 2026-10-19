/// Recurring dates (FR-R1 to FR-R10): parsing `every ...` phrases and
/// working out the next occurrence. Pure Dart.
///
/// Supported phrases, by example:
///   every day | daily | every weekday | every week | every month | every year
///   every other week | every 3 days | every 2 months | every quarter | every 3 workdays
///   every mon, fri | every 2, 15, 27 | every 14 jan, 15 jun | every 1st wed | every 1st wed jan
///   every last workday | every 15th workday | every last day
///   ... starting aug 3 | until aug 3 | for 3 weeks | from 10 may until 20 may
///   ... at 8pm | every fri at noon | every 12 hours starting at 9pm
///   every! 2 months | after 10 days   (counted from the day you finish it)
///
/// Anything else is refused with a message (FR-R10) instead of guessing.
library;

import 'date_parser.dart';

class RecurrenceException implements Exception {
  RecurrenceException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum RecurKind { days, weeks, months, years, hours, weekdaySet, monthDays, yearDates, nthWeekday, workdayInterval, workdayOrdinal }

class Recurrence {
  const Recurrence({
    required this.text,
    required this.kind,
    this.fromCompletion = false,
    this.interval = 1,
    this.weekdays = const {},
    this.monthDays = const [],
    this.yearDates = const [],
    this.nth,
    this.nthWeekday,
    this.month,
    this.workdayOrdinal,
    this.timeMinutes,
    this.start,
    this.until,
  });

  /// The phrase as the owner typed it, normalised. This is what is stored.
  final String text;
  final RecurKind kind;

  /// `every!` and `after N days`: the next date counts from completion.
  final bool fromCompletion;
  final int interval;
  final Set<int> weekdays; // 1 = Monday ... 7 = Sunday
  final List<int> monthDays; // 1..31, -1 = last day
  final List<(int, int)> yearDates; // (month, day)
  final int? nth; // 1..5, or -1 for last
  final int? nthWeekday;
  final int? month;
  final int? workdayOrdinal; // 1.. or -1 for last
  final int? timeMinutes;
  final DateTime? start;
  final DateTime? until;

  bool get isHourly => kind == RecurKind.hours;

  /// A schedule point matches when [d] is an occurrence, counting from [anchor]
  /// (the current due date, or the completion date for `every!`).
  bool matches(DateTime d, DateTime anchor) {
    if (until != null && d.isAfter(until!)) return false;
    if (start != null && d.isBefore(start!)) return false;
    switch (kind) {
      case RecurKind.days:
        final diff = _days(d) - _days(anchor);
        return diff > 0 && diff % interval == 0;
      case RecurKind.weeks:
        final diff = _days(d) - _days(anchor);
        return diff > 0 && diff % (7 * interval) == 0;
      case RecurKind.months:
        final diff = (d.year - anchor.year) * 12 + d.month - anchor.month;
        return diff > 0 && diff % interval == 0 && d.day == _clampDay(anchor.day, d.year, d.month);
      case RecurKind.years:
        final diff = d.year - anchor.year;
        return diff > 0 && diff % interval == 0 && d.month == anchor.month && d.day == _clampDay(anchor.day, d.year, d.month);
      case RecurKind.weekdaySet:
        if (!weekdays.contains(d.weekday)) return false;
        final weeks = _weekIndex(d) - _weekIndex(anchor);
        return weeks >= 0 && weeks % interval == 0;
      case RecurKind.monthDays:
        final last = DateTime(d.year, d.month + 1, 0).day;
        return monthDays.contains(d.day) || (monthDays.contains(-1) && d.day == last);
      case RecurKind.yearDates:
        return yearDates.any((e) => e.$1 == d.month && e.$2 == d.day);
      case RecurKind.nthWeekday:
        if (d.weekday != nthWeekday) return false;
        if (month != null && d.month != month) return false;
        if (nth == -1) return d.day + 7 > DateTime(d.year, d.month + 1, 0).day;
        return (d.day - 1) ~/ 7 + 1 == nth;
      case RecurKind.workdayInterval:
        if (!_isWorkday(d)) return false;
        final between = _workdaysBetween(anchor, d);
        return between > 0 && between % interval == 0;
      case RecurKind.workdayOrdinal:
        if (!_isWorkday(d)) return false;
        if (workdayOrdinal == -1) {
          var next = d.add(const Duration(days: 1));
          while (!_isWorkday(next)) {
            next = next.add(const Duration(days: 1));
          }
          return next.month != d.month;
        }
        var count = 0;
        for (var day = DateTime(d.year, d.month, 1); !day.isAfter(d); day = day.add(const Duration(days: 1))) {
          if (_isWorkday(day)) count++;
        }
        return count == workdayOrdinal;
      case RecurKind.hours:
        return false; // handled by nextMoment
    }
  }
}

int _days(DateTime d) => DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 86400000;
int _weekIndex(DateTime d) => (_days(d) + 3) ~/ 7; // 1970-01-01 was a Thursday; weeks start Monday
int _clampDay(int day, int year, int month) {
  final last = DateTime(year, month + 1, 0).day;
  return day > last ? last : day;
}

bool _isWorkday(DateTime d) => d.weekday <= 5;

int _workdaysBetween(DateTime anchor, DateTime d) {
  var n = 0;
  for (var x = anchor.add(const Duration(days: 1)); !x.isAfter(d); x = x.add(const Duration(days: 1))) {
    if (_isWorkday(x)) n++;
  }
  return n;
}

// -----------------------------------------------------------------------------
// Next occurrence
// -----------------------------------------------------------------------------

/// The next date after finishing an occurrence, or null when the repeat has
/// ended (past its `until`).
///
/// For a fixed schedule ("every") the search runs from the later of the
/// current due date and the completion day, so finishing an overdue task
/// lands on a future date. For `every!` it counts from the completion day.
DateTime? nextOccurrence(Recurrence r, {required DateTime currentDue, required DateTime completedOn}) {
  if (r.isHourly) throw ArgumentError('Use nextMoment for hourly repeats');
  final done = dateOnly(completedOn);
  final due = dateOnly(currentDue);
  final anchor = r.fromCompletion ? done : due;
  final from = r.fromCompletion || done.isAfter(due) ? done : due;
  var d = from.add(const Duration(days: 1));
  for (var i = 0; i < 366 * 12; i++) {
    if (r.until != null && d.isAfter(r.until!)) return null;
    if (r.matches(d, anchor)) return d;
    d = d.add(const Duration(days: 1));
  }
  return null;
}

/// Next due moment for "every N hours": steps forward from the current due
/// time (or from completion for `every!`) until it is in the future.
DateTime? nextMoment(Recurrence r, {required DateTime currentDue, required DateTime completedAt}) {
  var next = (r.fromCompletion ? completedAt : currentDue).add(Duration(hours: r.interval));
  while (!next.isAfter(completedAt)) {
    next = next.add(Duration(hours: r.interval));
  }
  if (r.until != null && next.isAfter(r.until!.add(const Duration(days: 1)))) return null;
  return next;
}

/// The dates after [due], up to and including [to], on which a repeating task comes round again, for showing in a
/// calendar. Hourly repeats and `every!` / `after` repeats (which depend on when each one is finished) give none.
List<DateTime> occurrencesBetween(Recurrence r, {required DateTime due, required DateTime to, int limit = 3000}) {
  if (r.isHourly || r.fromCompletion) return const [];
  final end = dateOnly(to);
  final out = <DateTime>[];
  var current = dateOnly(due);
  while (out.length < limit && current.isBefore(end)) {
    final next = nextOccurrence(r, currentDue: current, completedOn: current);
    if (next == null || next.isAfter(end)) break;
    out.add(next);
    current = next;
  }
  return out;
}

/// The first due date when a task is created with a repeat and no date.
DateTime firstOccurrence(Recurrence r, DateTime now) {
  final today = dateOnly(now);
  final from = (r.start != null && r.start!.isAfter(today)) ? r.start! : today;
  DateTime scan(bool Function(DateTime) test) {
    var d = from;
    for (var i = 0; i < 366 * 12; i++) {
      if (test(d)) return d;
      d = d.add(const Duration(days: 1));
    }
    return from;
  }

  switch (r.kind) {
    case RecurKind.days:
    case RecurKind.weeks:
    case RecurKind.months:
    case RecurKind.years:
    case RecurKind.hours:
      return from;
    case RecurKind.workdayInterval:
      return scan(_isWorkday);
    case RecurKind.weekdaySet:
      final first = scan((d) => r.weekdays.contains(d.weekday));
      // "every other fri": the first one is the second Friday from now.
      return (r.interval > 1 && r.start == null) ? first.add(Duration(days: 7 * (r.interval - 1))) : first;
    case RecurKind.monthDays:
    case RecurKind.yearDates:
    case RecurKind.nthWeekday:
    case RecurKind.workdayOrdinal:
      return scan((d) => r.matches(d, from));
  }
}

// -----------------------------------------------------------------------------
// Parsing
// -----------------------------------------------------------------------------

const _wdNames = {
  'mon': 1, 'monday': 1, 'tue': 2, 'tues': 2, 'tuesday': 2, 'wed': 3, 'wednesday': 3,
  'thu': 4, 'thur': 4, 'thurs': 4, 'thursday': 4, 'fri': 5, 'friday': 5,
  'sat': 6, 'saturday': 6, 'sun': 7, 'sunday': 7,
};
const _moNames = {
  'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3, 'apr': 4, 'april': 4,
  'may': 5, 'jun': 6, 'june': 6, 'jul': 7, 'july': 7, 'aug': 8, 'august': 8,
  'sep': 9, 'sept': 9, 'september': 9, 'oct': 10, 'october': 10, 'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
};
const _nthNames = {
  '1st': 1, 'first': 1, '2nd': 2, 'second': 2, '3rd': 3, 'third': 3,
  '4th': 4, 'fourth': 4, '5th': 5, 'fifth': 5, 'last': -1,
};

final _wd = _wdNames.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
final _mo = _moNames.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
final _wdAlt = _wd.join('|');
final _moAlt = _mo.join('|');

/// Words that may appear inside a repeat phrase. Used to find where a repeat
/// ends in a longer line such as "water plants every other day #home".
final repeatVocabulary = {
  'every', 'every!', 'after', 'other', 'day', 'days', 'week', 'weeks', 'month', 'months', 'year', 'years',
  'quarter', 'hour', 'hours', 'weekday', 'weekdays', 'workday', 'workdays', 'last', 'first', 'second',
  'third', 'fourth', 'fifth', 'and', 'of', 'the', 'at', 'noon', 'midnight', 'starting', 'on', 'from',
  'until', 'ending', 'through', 'to', 'for', 'am', 'pm', 'tomorrow', 'today', 'next',
  ..._wdNames.keys, ..._moNames.keys,
};

/// True if [word] could be part of a repeat phrase (numbers, times, ordinals too).
bool isRepeatWord(String word) {
  final w = word.toLowerCase().replaceAll(RegExp(r'[,.]$'), '');
  if (repeatVocabulary.contains(w)) return true;
  return RegExp(r'^\d{1,4}(st|nd|rd|th)?$').hasMatch(w) ||
      RegExp(r'^\d{1,2}(:\d{2})?(am|pm)?$').hasMatch(w) ||
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(w);
}

/// Parses one repeat phrase. [now] anchors "for 3 weeks" and the default start.
/// Throws [RecurrenceException] with a plain explanation when the phrase is
/// not supported.
Recurrence parseRecurrence(String input, DateTime now) {
  var s = input.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) throw RecurrenceException('Type how often, for example "every other week".');
  final today = dateOnly(now);

  // Phrases that are clearly outside the supported set get a specific reason.
  if (RegExp(r'\bexcept\b').hasMatch(s)) {
    throw RecurrenceException('"except" is not supported. List the days you want instead, for example "every mon, tue, wed".');
  }
  if (RegExp(r'\bevery\b.*\bevery\b').hasMatch(s)) {
    throw RecurrenceException('Only one "every" per task. Create separate tasks for different repeats.');
  }
  final timesFound = RegExp(r'\d{1,2}(:\d{2})?\s*(am|pm)|\d{1,2}:\d{2}|noon|midnight').allMatches(s).length;
  if (timesFound > 1 && RegExp(r'(am|pm|:\d{2}|noon|midnight)\s*,').hasMatch(s) && !s.contains('starting')) {
    throw RecurrenceException('One time applies to every listed day. Create separate tasks for different times.');
  }

  // Shorthand words.
  s = s
      .replaceFirst(RegExp(r'^daily\b'), 'every day')
      .replaceFirst(RegExp(r'^weekly\b'), 'every week')
      .replaceFirst(RegExp(r'^monthly\b'), 'every month')
      .replaceFirst(RegExp(r'^(yearly|annually)\b'), 'every year')
      .replaceFirst(RegExp(r'^quarterly\b'), 'every 3 months')
      .replaceFirst(RegExp(r'^weekdays\b'), 'every weekday');

  var fromCompletion = false;
  final after = RegExp(r'^after (\d+) (day|days|week|weeks|month|months|year|years)\b').firstMatch(s);
  if (after != null) {
    fromCompletion = true;
    s = s.replaceFirst(after[0]!, 'every ${after[1]} ${after[2]}');
  }
  if (s.startsWith('every!')) {
    fromCompletion = true;
    s = s.replaceFirst('every!', 'every');
  }
  if (!s.startsWith('every ') && s != 'every') {
    throw RecurrenceException('A repeat starts with "every", for example "every 2 weeks".');
  }

  // Time of day, anywhere in the phrase ("every fri at noon", "7am").
  final tm = parseTime(s);
  int? time;
  if (tm != null) {
    time = tm.minutes;
    s = (s.substring(0, tm.start) + s.substring(tm.end)).replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceFirst(RegExp(r'\b(starting|from|on)\s*$'), '').trim(); // "starting at 9pm" leaves "starting"
  }

  // Bounds: "from X until Y", "starting X", "until Y", "for N units".
  DateTime? start, until;
  DateTime? parseBound(String text, String clause) {
    final m = parseDate(text.trim(), now);
    if (m == null || text.trim().isEmpty) {
      throw RecurrenceException('I could not read the date in "$clause".');
    }
    return m.date;
  }

  final fromUntil = RegExp(r'\bfrom (.+?) (?:until|to|through) (.+)$').firstMatch(s);
  if (fromUntil != null) {
    start = parseBound(fromUntil[1]!, fromUntil[0]!);
    until = parseBound(fromUntil[2]!, fromUntil[0]!);
    s = s.substring(0, fromUntil.start).trim();
  } else {
    // "for 3 weeks" is taken off first; it counts from the start date.
    final forM = RegExp(r'\bfor (\d+) (day|days|week|weeks|month|months|year|years)$').firstMatch(s);
    if (forM != null) s = s.substring(0, forM.start).trim();
    final untilM = RegExp(r'\b(?:until|ending(?: on)?|through) (.+)$').firstMatch(s);
    if (untilM != null) {
      until = parseBound(untilM[1]!, untilM[0]!);
      s = s.substring(0, untilM.start).trim();
    }
    final startM = RegExp(r'\b(?:starting|beginning)(?: on)? (.+)$').firstMatch(s);
    if (startM != null) {
      start = parseBound(startM[1]!, startM[0]!);
      s = s.substring(0, startM.start).trim();
    }
    if (forM != null) {
      final from = start ?? today;
      final n = int.parse(forM[1]!);
      final u = forM[2]!;
      until = u.startsWith('day')
          ? from.add(Duration(days: n))
          : u.startsWith('week')
              ? from.add(Duration(days: 7 * n))
              : u.startsWith('month')
                  ? addMonths(from, n)
                  : DateTime(from.year + n, from.month, from.day);
    }
  }
  if (start != null && until != null && until.isBefore(start)) {
    throw RecurrenceException('The end date is before the start date.');
  }

  final core = s.replaceFirst(RegExp(r'^every\s*'), '').replaceAll(RegExp(r'\s*,\s*'), ', ').replaceAll(RegExp(r'\s+and\s+'), ', ').trim();
  final normalised = input.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  Recurrence make(RecurKind kind, {
    int interval = 1,
    Set<int> weekdays = const {},
    List<int> monthDays = const [],
    List<(int, int)> yearDates = const [],
    int? nth,
    int? nthWeekday,
    int? month,
    int? ordinal,
  }) =>
      Recurrence(
        text: normalised, kind: kind, fromCompletion: fromCompletion, interval: interval, weekdays: weekdays,
        monthDays: monthDays, yearDates: yearDates, nth: nth, nthWeekday: nthWeekday, month: month,
        workdayOrdinal: ordinal, timeMinutes: time, start: start, until: until,
      );

  RecurKind unitKind(String u) {
    if (u.startsWith('day')) return RecurKind.days;
    if (u.startsWith('week') && !u.startsWith('weekday')) return RecurKind.weeks;
    if (u.startsWith('month')) return RecurKind.months;
    if (u.startsWith('year')) return RecurKind.years;
    if (u.startsWith('hour')) return RecurKind.hours;
    return RecurKind.workdayInterval; // workday(s), weekday(s)
  }

  Match? m;
  // every day / week / month / year / quarter / hour
  m = RegExp(r'^(day|week|month|year|hour)$').firstMatch(core);
  if (m != null) return make(unitKind(m[1]!));
  if (core == 'quarter') return make(RecurKind.months, interval: 3);
  if (core == 'weekday' || core == 'workday') return make(RecurKind.weekdaySet, weekdays: {1, 2, 3, 4, 5});

  // every other day/week/month/year
  m = RegExp(r'^other (day|week|month|year|workday|weekday)$').firstMatch(core);
  if (m != null) return make(unitKind(m[1]!), interval: 2);

  // every 3 days / 2 months / 3 workdays / 12 hours
  m = RegExp(r'^(\d+) (days?|weeks?|months?|years?|hours?|workdays?|weekdays?)$').firstMatch(core);
  if (m != null) {
    final n = int.parse(m[1]!);
    if (n < 1) throw RecurrenceException('The number must be at least 1.');
    return make(unitKind(m[2]!), interval: n);
  }

  // every 15th workday / last workday
  m = RegExp(r'^(\d+(?:st|nd|rd|th)|first|last) (workday|weekday)$').firstMatch(core);
  if (m != null) {
    final word = m[1]!;
    final ordinal = word == 'last' ? -1 : (word == 'first' ? 1 : int.parse(word.replaceAll(RegExp(r'\D'), '')));
    return make(RecurKind.workdayOrdinal, ordinal: ordinal);
  }

  // every mon, fri / every other fri
  final wdList = '(?:$_wdAlt)(?:, (?:$_wdAlt))*';
  m = RegExp('^(other )?($wdList)\$').firstMatch(core);
  if (m != null) {
    final days = m[2]!.split(', ').map((x) => _wdNames[x]!).toSet();
    return make(RecurKind.weekdaySet, weekdays: days, interval: m[1] != null ? 2 : 1);
  }

  // every 1st wed / every last fri / every 1st wed jan
  m = RegExp('^(1st|first|2nd|second|3rd|third|4th|fourth|5th|fifth|last) ($_wdAlt)(?: (?:of )?($_moAlt))?\$').firstMatch(core);
  if (m != null) {
    return make(RecurKind.nthWeekday, nth: _nthNames[m[1]!], nthWeekday: _wdNames[m[2]!], month: m[3] == null ? null : _moNames[m[3]!]);
  }

  // every 14 jan, 15 jun / every jan 14
  final dm = '(?:\\d{1,2}(?:st|nd|rd|th)? (?:$_moAlt)|(?:$_moAlt) \\d{1,2}(?:st|nd|rd|th)?)';
  m = RegExp('^$dm(?:, $dm)*\$').firstMatch(core);
  if (m != null) {
    final dates = <(int, int)>[];
    for (final part in core.split(', ')) {
      final pm = RegExp('^(?:(\\d{1,2})(?:st|nd|rd|th)? ($_moAlt)|($_moAlt) (\\d{1,2})(?:st|nd|rd|th)?)\$').firstMatch(part)!;
      final month = _moNames[pm[2] ?? pm[3]!]!;
      final day = int.parse(pm[1] ?? pm[4]!);
      if (day < 1 || DateTime(2024, month, day).month != month) {
        throw RecurrenceException('"$part" is not a real date.');
      }
      dates.add((month, day));
    }
    return make(RecurKind.yearDates, yearDates: dates);
  }

  // every 2, 15, 27 / every 15th / every last day
  final md = '(?:\\d{1,2}(?:st|nd|rd|th)?|last(?: day)?)';
  m = RegExp('^(?:the )?$md(?:, $md)*\$').firstMatch(core);
  if (m != null) {
    final days = <int>[];
    for (final part in core.replaceFirst('the ', '').split(', ')) {
      if (part.startsWith('last')) {
        days.add(-1);
      } else {
        final day = int.parse(part.replaceAll(RegExp(r'\D'), ''));
        if (day < 1 || day > 31) throw RecurrenceException('Day of month must be 1 to 31.');
        days.add(day);
      }
    }
    return make(RecurKind.monthDays, monthDays: days);
  }

  if (RegExp(r'^\d+ (months?) .*(first|last|\d+(st|nd|rd|th)) ').hasMatch(core) ||
      (RegExp(r'\b(months?)\b').hasMatch(core) && RegExp('\\b($_wdAlt)\\b').hasMatch(core))) {
    throw RecurrenceException('A monthly interval with a weekday is not supported. List the dates instead.');
  }
  throw RecurrenceException('I do not understand "$input". Try "every other week", "every mon, fri" or "every 15th".');
}

/// A repeat found inside a longer line (Quick Add).
class RecurrenceMatch {
  const RecurrenceMatch(this.recurrence, this.start, this.end);
  final Recurrence recurrence;
  final int start;
  final int end;
}

/// What [findRecurrence] can report besides a match.
class RecurrenceSearch {
  const RecurrenceSearch({this.match, this.error});
  final RecurrenceMatch? match;

  /// Set when the line clearly tried to repeat ("every other ...") but the
  /// phrase is unsupported; shown to the owner instead of being ignored.
  final String? error;
}

/// Finds an `every ...` or `after N days` phrase in [text]. The phrase runs
/// over repeat vocabulary and stops at the first other word, so
/// "Water plants every other day #home" yields "every other day".
RecurrenceSearch findRecurrence(String text, DateTime now) {
  final starts = RegExp(r'(?<!\S)(every!?|after)(?=\s)', caseSensitive: false).allMatches(text);
  for (final sm in starts) {
    final words = RegExp(r'\S+').allMatches(text, sm.start).toList();
    var n = 1;
    while (n < words.length && isRepeatWord(words[n].group(0)!)) {
      n++;
    }
    // "after" needs a number and a unit; otherwise it is just a word.
    if (sm.group(1)!.toLowerCase() == 'after' && n < 3) continue;
    // Take the longest run that parses, trimming trailing words ("for", "on").
    for (var take = n; take >= 2; take--) {
      final end = words[take - 1].end;
      final phrase = text.substring(sm.start, end);
      try {
        return RecurrenceSearch(match: RecurrenceMatch(parseRecurrence(phrase, now), sm.start, end));
      } on RecurrenceException catch (e) {
        if (take == 2) {
          // Only complain if the word after "every" is real repeat vocabulary.
          final next = words.length > 1 ? words[1].group(0)!.toLowerCase().replaceAll(RegExp(r'[,.]$'), '') : '';
          final plausible = RegExp(r'^(other|\d+|day|days|week|weeks|month|months|year|years|quarter|weekday|weekdays|workday|workdays|last|first)$').hasMatch(next) ||
              _wdNames.containsKey(next) ||
              _moNames.containsKey(next);
          if (plausible && sm.group(1)!.toLowerCase() != 'after') return RecurrenceSearch(error: e.message);
        }
      }
    }
  }
  return const RecurrenceSearch();
}
