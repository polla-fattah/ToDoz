/// Goals, streaks, Karma and chart numbers (SRS 4.9, FR-K1..K5, K10).
///
/// Everything here is computed from the completion history and the open
/// tasks, never stored, so every device shows the same numbers after a sync
/// and the rules below can be read in one place.
///
/// Karma (FR-K3). Todoist's own formula is not public, so this app has its
/// own, fixed across updates:
///
///  * each completed task earns 10 points;
///  * +5 if it was done on or before its due date (or had none);
///  * +9, +6 or +3 for priority 1, 2 or 3;
///  * +20 for each day that reached the daily goal, +50 for each week that
///    reached the weekly goal;
///  * minus 1 point per day beyond the third that an open task is overdue,
///    at most 14 per task.
///
/// The total never goes below 0.
library;

import 'date_parser.dart';

/// One finished task (or one finished occurrence of a repeating task).
class CompletionFact {
  const CompletionFact({required this.completedAt, this.dueDate, this.priority = 4});

  /// When it was done, in the person's local time.
  final DateTime completedAt;

  /// The due date it had at that moment, `YYYY-MM-DD`.
  final String? dueDate;
  final int priority;
}

/// An unfinished task, for the overdue penalty.
class OpenFact {
  const OpenFact({this.dueDate});
  final String? dueDate;
}

/// Goals and the days that do not count against a streak.
class Goals {
  const Goals({this.daily = 5, this.weekly = 30, this.daysOff = const {}, this.vacations = const [], this.weekStart = 1});

  /// Tasks to finish each day; 0 turns the goal (and its streak) off.
  final int daily;

  /// Tasks to finish each week; 0 turns it off.
  final int weekly;

  /// Weekdays that never break a streak, 1 = Monday .. 7 = Sunday.
  final Set<int> daysOff;

  /// Vacation periods as inclusive `YYYY-MM-DD` ranges. An open range has a null end.
  final List<(String, String?)> vacations;
  final int weekStart;

  bool isFrozen(DateTime day, DateTime today) {
    if (daysOff.contains(day.weekday)) return true;
    final key = formatDate(day);
    for (final (from, to) in vacations) {
      if (key.compareTo(from) >= 0 && (to == null || key.compareTo(to) <= 0)) return true;
    }
    return false;
  }

  /// Reads `from..to` pairs such as `2026-08-01..2026-08-14,2026-10-01..`.
  static List<(String, String?)> parseVacations(String? text) {
    if (text == null || text.trim().isEmpty) return const [];
    final out = <(String, String?)>[];
    for (final part in text.split(',')) {
      final bits = part.trim().split('..');
      if (bits.isEmpty || parseIsoDate(bits[0]) == null) continue;
      final to = bits.length > 1 && bits[1].isNotEmpty && parseIsoDate(bits[1]) != null ? bits[1] : null;
      out.add((bits[0], to));
    }
    return out;
  }

  static String encodeVacations(List<(String, String?)> v) => v.map((r) => '${r.$1}..${r.$2 ?? ''}').join(',');
}

class Streak {
  const Streak({required this.current, required this.longest});
  final int current;
  final int longest;
}

class KarmaLevel {
  const KarmaLevel(this.name, this.from);
  final String name;
  final int from;
}

const karmaLevels = [
  KarmaLevel('Beginner', 0),
  KarmaLevel('Novice', 500),
  KarmaLevel('Intermediate', 2500),
  KarmaLevel('Professional', 5000),
  KarmaLevel('Expert', 7500),
  KarmaLevel('Master', 10000),
  KarmaLevel('Grandmaster', 20000),
  KarmaLevel('Enlightened', 30000),
];

class KarmaStatus {
  const KarmaStatus({required this.points, required this.level, required this.next, required this.progress});
  final int points;
  final KarmaLevel level;

  /// The next level, or null at the top.
  final KarmaLevel? next;

  /// 0..1 through the current level.
  final double progress;
}

class Progress {
  Progress({required List<CompletionFact> completions, required List<OpenFact> open, required this.goals, required DateTime today})
      : today = dateOnly(today),
        completions = List.unmodifiable(completions),
        open = List.unmodifiable(open) {
    for (final c in completions) {
      final k = formatDate(dateOnly(c.completedAt));
      _perDay[k] = (_perDay[k] ?? 0) + 1;
    }
  }

  final List<CompletionFact> completions;
  final List<OpenFact> open;
  final Goals goals;
  final DateTime today;
  final Map<String, int> _perDay = {};

  int doneOn(DateTime day) => _perDay[formatDate(dateOnly(day))] ?? 0;

  /// Monday-based (or [Goals.weekStart]-based) first day of the week holding [d].
  DateTime weekStartOf(DateTime d) {
    final day = dateOnly(d);
    final back = (day.weekday - goals.weekStart + 7) % 7;
    return DateTime(day.year, day.month, day.day - back);
  }

  int doneInWeek(DateTime anyDayInWeek) {
    final start = weekStartOf(anyDayInWeek);
    var n = 0;
    for (var i = 0; i < 7; i++) {
      n += doneOn(DateTime(start.year, start.month, start.day + i));
    }
    return n;
  }

  // --- charts --------------------------------------------------------------------

  /// Completed tasks for each of the last [days] days, oldest first.
  List<(DateTime, int)> perDay(int days) => [
        for (var i = days - 1; i >= 0; i--) (DateTime(today.year, today.month, today.day - i), doneOn(DateTime(today.year, today.month, today.day - i))),
      ];

  /// Completed tasks for each of the last [weeks] weeks, oldest first, keyed by the week's first day.
  List<(DateTime, int)> perWeek(int weeks) {
    final thisWeek = weekStartOf(today);
    return [
      for (var i = weeks - 1; i >= 0; i--)
        (DateTime(thisWeek.year, thisWeek.month, thisWeek.day - 7 * i), doneInWeek(DateTime(thisWeek.year, thisWeek.month, thisWeek.day - 7 * i))),
    ];
  }

  /// Completed tasks for each of the last [months] months, oldest first, keyed by the 1st.
  List<(DateTime, int)> perMonth(int months) {
    final out = <(DateTime, int)>[];
    for (var i = months - 1; i >= 0; i--) {
      final first = DateTime(today.year, today.month - i, 1);
      var n = 0;
      final prefix = '${first.year.toString().padLeft(4, '0')}-${first.month.toString().padLeft(2, '0')}-';
      _perDay.forEach((k, v) {
        if (k.startsWith(prefix)) n += v;
      });
      out.add((first, n));
    }
    return out;
  }

  // --- streaks ---------------------------------------------------------------------

  DateTime? get _firstDay {
    if (_perDay.isEmpty) return null;
    return parseIsoDate(_perDay.keys.reduce((a, b) => a.compareTo(b) <= 0 ? a : b));
  }

  /// Consecutive days that reached the daily goal. Days off and vacation days
  /// neither count nor break it. Today never breaks it while it is still open.
  Streak get dailyStreak {
    final goal = goals.daily;
    final first = _firstDay;
    if (goal <= 0 || first == null) return const Streak(current: 0, longest: 0);
    var longest = 0, run = 0;
    for (var d = first; !d.isAfter(today); d = DateTime(d.year, d.month, d.day + 1)) {
      if (goals.isFrozen(d, today)) continue;
      if (doneOn(d) >= goal) {
        run++;
        if (run > longest) longest = run;
      } else if (d == today) {
        // Today is still in progress: it neither extends nor breaks the run.
      } else {
        run = 0;
      }
    }
    return Streak(current: run, longest: longest);
  }

  /// Consecutive weeks that reached the weekly goal. A week whose every day is frozen is skipped.
  Streak get weeklyStreak {
    final goal = goals.weekly;
    final first = _firstDay;
    if (goal <= 0 || first == null) return const Streak(current: 0, longest: 0);
    final thisWeek = weekStartOf(today);
    var longest = 0, run = 0;
    for (var w = weekStartOf(first); !w.isAfter(thisWeek); w = DateTime(w.year, w.month, w.day + 7)) {
      var allFrozen = true;
      for (var i = 0; i < 7; i++) {
        if (!goals.isFrozen(DateTime(w.year, w.month, w.day + i), today)) allFrozen = false;
      }
      if (allFrozen) continue;
      if (doneInWeek(w) >= goal) {
        run++;
        if (run > longest) longest = run;
      } else if (w == thisWeek) {
        // The current week is still open.
      } else {
        run = 0;
      }
    }
    return Streak(current: run, longest: longest);
  }

  bool get dailyGoalReachedToday => goals.daily > 0 && doneOn(today) >= goals.daily;

  // --- Karma -----------------------------------------------------------------------

  static int pointsFor(CompletionFact c) {
    var p = 10;
    final due = c.dueDate;
    if (due == null || formatDate(dateOnly(c.completedAt)).compareTo(due) <= 0) p += 5;
    if (c.priority >= 1 && c.priority <= 3) p += (4 - c.priority) * 3;
    return p;
  }

  int get karmaPoints {
    var total = 0;
    for (final c in completions) {
      total += pointsFor(c);
    }
    if (goals.daily > 0) {
      _perDay.forEach((k, n) {
        final d = parseIsoDate(k);
        if (d != null && n >= goals.daily && !goals.isFrozen(d, today)) total += 20;
      });
    }
    if (goals.weekly > 0) {
      final seen = <String>{};
      for (final k in _perDay.keys) {
        final d = parseIsoDate(k);
        if (d == null) continue;
        final w = weekStartOf(d);
        if (seen.add(formatDate(w)) && doneInWeek(w) >= goals.weekly) total += 50;
      }
    }
    for (final t in open) {
      final due = t.dueDate == null ? null : parseIsoDate(t.dueDate!);
      if (due == null) continue;
      final late = today.difference(due).inDays;
      if (late >= 4) total -= (late - 3).clamp(1, 14);
    }
    return total < 0 ? 0 : total;
  }

  KarmaStatus get karma {
    final pts = karmaPoints;
    var idx = 0;
    for (var i = 0; i < karmaLevels.length; i++) {
      if (pts >= karmaLevels[i].from) idx = i;
    }
    final level = karmaLevels[idx];
    final next = idx + 1 < karmaLevels.length ? karmaLevels[idx + 1] : null;
    final progress = next == null ? 1.0 : (pts - level.from) / (next.from - level.from);
    return KarmaStatus(points: pts, level: level, next: next, progress: progress.clamp(0.0, 1.0));
  }
}
