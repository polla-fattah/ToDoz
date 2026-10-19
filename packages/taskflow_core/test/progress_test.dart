import 'package:taskflow_core/progress.dart';
import 'package:test/test.dart';

CompletionFact done(String day, {String? due, int priority = 4, int hour = 12}) {
  final d = DateTime.parse(day);
  return CompletionFact(completedAt: DateTime(d.year, d.month, d.day, hour), dueDate: due, priority: priority);
}

List<CompletionFact> many(String day, int n) => [for (var i = 0; i < n; i++) done(day)];

Progress build(List<CompletionFact> c, {Goals goals = const Goals(daily: 2, weekly: 0), String today = '2026-10-19', List<OpenFact> open = const []}) =>
    Progress(completions: c, open: open, goals: goals, today: DateTime.parse(today));

void main() {
  group('daily streak', () {
    test('counts consecutive days that reached the goal, and today in progress does not break it', () {
      final p = build([...many('2026-10-16', 2), ...many('2026-10-17', 3), ...many('2026-10-18', 2)]);
      expect(p.dailyStreak.current, 3);
      expect(p.dailyStreak.longest, 3);
    });

    test('today counts once the goal is met', () {
      final p = build([...many('2026-10-18', 2), ...many('2026-10-19', 2)]);
      expect(p.dailyStreak.current, 2);
      expect(p.dailyGoalReachedToday, isTrue);
    });

    test('a missed day ends the run, and the longest run is remembered', () {
      final p = build([...many('2026-10-10', 2), ...many('2026-10-11', 2), ...many('2026-10-12', 2), ...many('2026-10-14', 2), ...many('2026-10-15', 2)]);
      expect(p.dailyStreak.longest, 3);
      expect(p.dailyStreak.current, 0, reason: '16th to 18th were missed');
    });

    test('a day short of the goal breaks it', () {
      final p = build([...many('2026-10-17', 2), ...many('2026-10-18', 1)]);
      expect(p.dailyStreak.current, 0);
    });

    test('days off are skipped, neither counted nor breaking', () {
      // Sat 17 and Sun 18 are days off; Fri 16 and Mon 19 (today, done) count.
      final goals = const Goals(daily: 2, weekly: 0, daysOff: {6, 7});
      final p = build([...many('2026-10-15', 2), ...many('2026-10-16', 2), ...many('2026-10-19', 2)], goals: goals);
      expect(p.dailyStreak.current, 3);
    });

    test('vacation freezes the streak for its dates, including an open range', () {
      final goals = Goals(daily: 2, weekly: 0, vacations: const [('2026-10-17', null)]);
      final p = build(many('2026-10-16', 2), goals: goals);
      expect(p.dailyStreak.current, 1, reason: '17th, 18th and today are on vacation');
      final without = build(many('2026-10-16', 2));
      expect(without.dailyStreak.current, 0, reason: 'the 17th was missed');
    });

    test('goal 0 turns streaks off', () {
      final p = build(many('2026-10-18', 5), goals: const Goals(daily: 0, weekly: 0));
      expect(p.dailyStreak.current, 0);
      expect(p.dailyGoalReachedToday, isFalse);
    });
  });

  group('weekly streak', () {
    test('counts weeks that reached the goal; the current week in progress does not break it', () {
      final goals = const Goals(daily: 0, weekly: 3);
      // Weeks start Monday: 5 Oct, 12 Oct, and today is in the week of 19 Oct.
      final p = build([...many('2026-10-06', 2), ...many('2026-10-08', 1), ...many('2026-10-13', 3)], goals: goals);
      expect(p.weeklyStreak.current, 2);
      expect(p.weeklyStreak.longest, 2);
    });

    test('a short week breaks it', () {
      final goals = const Goals(daily: 0, weekly: 3);
      final p = build([...many('2026-10-06', 3), ...many('2026-10-13', 2)], goals: goals);
      expect(p.weeklyStreak.current, 0);
      expect(p.weeklyStreak.longest, 1);
    });

    test('the week start setting moves the boundaries', () {
      final sunday = const Goals(daily: 0, weekly: 2, weekStart: 7);
      // Sunday 11 Oct starts a week; Sat 17 Oct ends it.
      final p = build([...many('2026-10-11', 1), ...many('2026-10-17', 1)], goals: sunday);
      expect(p.doneInWeek(DateTime(2026, 10, 14)), 2);
    });
  });

  group('charts', () {
    test('per day, week and month', () {
      final p = build([...many('2026-10-19', 2), ...many('2026-10-18', 1), ...many('2026-10-05', 4), ...many('2026-09-30', 3)]);
      final days = p.perDay(3);
      expect(days.map((e) => e.$2), [0, 1, 2]);
      expect(days.first.$1, DateTime(2026, 10, 17));
      expect(p.perWeek(2).map((e) => e.$2), [1, 2], reason: 'Sunday the 18th belongs to the week that began on the 12th');
      expect(p.perMonth(2).map((e) => e.$2), [3, 7]);
    });

    test('per week: weeks are keyed by their first day', () {
      final p = build([...many('2026-10-19', 2), ...many('2026-10-13', 5)]);
      final w = p.perWeek(3);
      expect(w.map((e) => e.$1), [DateTime(2026, 10, 5), DateTime(2026, 10, 12), DateTime(2026, 10, 19)]);
      expect(w.map((e) => e.$2), [0, 5, 2]);
    });

    test('per month crosses a year boundary', () {
      final p = build([...many('2026-01-15', 2), ...many('2025-12-31', 1), ...many('2025-11-30', 4)], today: '2026-01-20');
      final m = p.perMonth(3);
      expect(m.map((e) => e.$1), [DateTime(2025, 11), DateTime(2025, 12), DateTime(2026, 1)]);
      expect(m.map((e) => e.$2), [4, 1, 2]);
    });
  });

  group('Karma', () {
    test('points per task: base, on time, priority', () {
      expect(Progress.pointsFor(done('2026-10-19')), 15, reason: 'no due date counts as on time');
      expect(Progress.pointsFor(done('2026-10-19', due: '2026-10-19')), 15);
      expect(Progress.pointsFor(done('2026-10-20', due: '2026-10-19')), 10, reason: 'late');
      expect(Progress.pointsFor(done('2026-10-19', priority: 1)), 24);
      expect(Progress.pointsFor(done('2026-10-19', priority: 2)), 21);
      expect(Progress.pointsFor(done('2026-10-19', priority: 3)), 18);
    });

    test('goal days and weeks add bonuses', () {
      final c = many('2026-10-19', 3); // 3 x 15
      expect(build(c, goals: const Goals(daily: 3, weekly: 0)).karmaPoints, 45 + 20);
      expect(build(c, goals: const Goals(daily: 0, weekly: 3)).karmaPoints, 45 + 50);
      expect(build(c, goals: const Goals(daily: 4, weekly: 4)).karmaPoints, 45);
    });

    test('tasks overdue four or more days cost points, at most 14 each', () {
      final base = many('2026-10-19', 20); // 300 points
      final open = [
        const OpenFact(dueDate: '2026-10-16'), // 3 days late: free
        const OpenFact(dueDate: '2026-10-15'), // 4 days: -1
        const OpenFact(dueDate: '2026-10-09'), // 10 days: -7
        const OpenFact(dueDate: '2026-01-01'), // long ago: -14
        const OpenFact(), // no due date: nothing
      ];
      final g = const Goals(daily: 0, weekly: 0);
      expect(build(base, goals: g, open: open).karmaPoints, 300 - 1 - 7 - 14);
    });

    test('never below zero', () {
      expect(build(const [], goals: const Goals(daily: 0, weekly: 0), open: [const OpenFact(dueDate: '2020-01-01')]).karmaPoints, 0);
    });

    test('levels and the progress bar', () {
      final g = const Goals(daily: 0, weekly: 0);
      var k = build(const [], goals: g).karma;
      expect(k.level.name, 'Beginner');
      expect(k.next!.name, 'Novice');
      expect(k.progress, 0);
      // 34 tasks x 15 = 510 points.
      k = build(many('2026-10-19', 34), goals: g).karma;
      expect(k.points, 510);
      expect(k.level.name, 'Novice');
      expect(k.progress, closeTo(10 / 2000, 1e-9));
      // Thresholds rise with each level.
      for (var i = 1; i < karmaLevels.length; i++) {
        expect(karmaLevels[i].from, greaterThan(karmaLevels[i - 1].from));
      }
    });

    test('the top level has a full bar and no next level', () {
      final k = build(many('2026-10-19', 2100), goals: const Goals(daily: 0, weekly: 0)).karma;
      expect(k.level.name, 'Enlightened');
      expect(k.next, isNull);
      expect(k.progress, 1);
    });
  });

  test('vacation ranges are saved as text and read back', () {
    final v = [('2026-08-01', '2026-08-14'), ('2026-10-01', null)];
    expect(Goals.encodeVacations(v), '2026-08-01..2026-08-14,2026-10-01..');
    expect(Goals.parseVacations(Goals.encodeVacations(v)), v);
    expect(Goals.parseVacations('garbage,2026-13-40..,'), isEmpty);
    expect(Goals.parseVacations(null), isEmpty);
  });
}
