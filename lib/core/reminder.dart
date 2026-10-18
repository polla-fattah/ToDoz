/// Reminder rules (FR-N1, FR-N2) and the pure logic that turns tasks into the
/// moments a notification should fire. No Flutter or database imports, so it
/// is fully unit-tested; the Android layer only schedules what this returns.
library;

import 'date_parser.dart';
import 'recurrence.dart';

/// One reminder on a task: either at a clock time on the due date
/// (`!14:00`) or a number of minutes before the due moment (`!30 min before`).
class ReminderSpec {
  const ReminderSpec.at(int this.timeMinutes) : offsetMinutes = null;
  const ReminderSpec.before(int this.offsetMinutes) : timeMinutes = null;

  final int? timeMinutes;
  final int? offsetMinutes;

  bool get isRelative => offsetMinutes != null;

  /// `14:00` or `30m` for storage.
  String encode() => isRelative ? '${offsetMinutes}m' : formatTime(timeMinutes!);

  static ReminderSpec? decode(String s) {
    final rel = RegExp(r'^(\d+)m$').firstMatch(s);
    if (rel != null) return ReminderSpec.before(int.parse(rel[1]!));
    final t = parseClock(s);
    return t == null ? null : ReminderSpec.at(t);
  }

  String describe({bool use24h = true}) {
    if (!isRelative) return 'At ${formatTime(timeMinutes!, use24h: use24h)}';
    final m = offsetMinutes!;
    if (m == 0) return 'When due';
    if (m % 1440 == 0) return '${m ~/ 1440} day${m == 1440 ? '' : 's'} before';
    if (m % 60 == 0) return '${m ~/ 60} hour${m == 60 ? '' : 's'} before';
    return '$m minutes before';
  }

  @override
  bool operator ==(Object other) =>
      other is ReminderSpec && other.timeMinutes == timeMinutes && other.offsetMinutes == offsetMinutes;

  @override
  int get hashCode => Object.hash(timeMinutes, offsetMinutes);
}

/// Parses the text after `!` in Quick Add: `14:00`, `2pm`, `30 min before`,
/// `1h`, `2 hours before`.
ReminderSpec? parseReminderText(String text) {
  final t = text.trim().toLowerCase();
  final rel = RegExp(r'^(\d+)\s*(min|mins|minute|minutes|m|hour|hours|hr|hrs|h|day|days|d)(?:\s+before)?$').firstMatch(t);
  if (rel != null) {
    final n = int.parse(rel[1]!);
    final u = rel[2]!;
    final minutes = u.startsWith('d') ? n * 1440 : (u.startsWith('h') ? n * 60 : n);
    return ReminderSpec.before(minutes);
  }
  final tm = parseTime(t);
  if (tm != null && tm.start == 0 && tm.end == t.length) return ReminderSpec.at(tm.minutes);
  return null;
}

/// A concrete notification: which task, when, and why.
class Fire {
  const Fire({required this.taskId, required this.at, required this.title, required this.spec, required this.automatic});
  final String taskId;
  final DateTime at;
  final String title;
  final ReminderSpec spec;

  /// True for the automatic reminder added to a task with a due time.
  final bool automatic;

  /// A stable id for the OS notification: the same task and reminder always
  /// map to the same number, so rescheduling replaces rather than duplicates.
  int get notificationId => _stable('$taskId|${spec.encode()}|${automatic ? 'a' : 'c'}');

  static int _stable(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x3fffffff;
    }
    return h;
  }
}

/// What the scheduler needs to know about one open task.
class ReminderTask {
  const ReminderTask({
    required this.id,
    required this.title,
    required this.dueDate,
    this.dueTime,
    this.reminders = const [],
    this.snoozedUntil,
  });
  final String id;
  final String title;
  final String? dueDate; // yyyy-mm-dd
  final String? dueTime; // HH:MM
  final List<ReminderSpec> reminders;

  /// Set by "snooze"; fires once at this moment regardless of the due date.
  final DateTime? snoozedUntil;
}

/// The reminders that should fire after [now], soonest first, at most [limit].
///
/// A task with a due time gets an automatic reminder [autoLeadMinutes] before
/// it (null turns that off), unless it already has an explicit reminder at
/// the same moment. Reminders in the past are dropped; android keeps only a
/// limited number of alarms, so the caller schedules a rolling window.
List<Fire> upcomingFires(
  List<ReminderTask> tasks,
  DateTime now, {
  int? autoLeadMinutes = 30,
  int limit = 60,
}) {
  final out = <Fire>[];
  for (final t in tasks) {
    if (t.snoozedUntil != null && t.snoozedUntil!.isAfter(now)) {
      out.add(Fire(taskId: t.id, at: t.snoozedUntil!, title: t.title, spec: const ReminderSpec.before(0), automatic: false));
    }
    final date = t.dueDate == null ? null : parseIsoDate(t.dueDate!);
    if (date == null) continue;
    final dueMinutes = t.dueTime == null ? null : parseClock(t.dueTime!);
    final due = dueMinutes == null ? null : DateTime(date.year, date.month, date.day, dueMinutes ~/ 60, dueMinutes % 60);
    final used = <DateTime>{};
    for (final r in t.reminders) {
      final at = r.isRelative
          ? due?.subtract(Duration(minutes: r.offsetMinutes!))
          : DateTime(date.year, date.month, date.day, r.timeMinutes! ~/ 60, r.timeMinutes! % 60);
      if (at == null || !at.isAfter(now)) continue;
      used.add(at);
      out.add(Fire(taskId: t.id, at: at, title: t.title, spec: r, automatic: false));
    }
    if (due != null && autoLeadMinutes != null) {
      final at = due.subtract(Duration(minutes: autoLeadMinutes));
      if (at.isAfter(now) && !used.contains(at)) {
        out.add(Fire(taskId: t.id, at: at, title: t.title, spec: ReminderSpec.before(autoLeadMinutes), automatic: true));
      }
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// Whether a task counts as overdue at [now] (FR-D6): a dated task with a
/// time is overdue only after that time; without a time, after its day ends.
bool isOverdue({required String? dueDate, String? dueTime, required DateTime now}) {
  if (dueDate == null || parseIsoDate(dueDate) == null) return false;
  return dueMoment(dueDate, dueTime).isBefore(now);
}

/// The due moment of a recurring task after completion, as stored fields.
class NextDue {
  const NextDue(this.date, this.time);
  final String date;
  final String? time;
}

/// Works out where a recurring task goes when completed (FR-R7), or null if
/// the repeat has ended and the task should simply complete.
NextDue? nextDueAfterCompletion({
  required Recurrence recurrence,
  required String dueDate,
  String? dueTime,
  required DateTime completedAt,
}) {
  final date = parseIsoDate(dueDate);
  if (date == null) return null;
  if (recurrence.isHourly) {
    final t = dueTime == null ? null : parseClock(dueTime);
    final current = DateTime(date.year, date.month, date.day, (t ?? 0) ~/ 60, (t ?? 0) % 60);
    final next = nextMoment(recurrence, currentDue: current, completedAt: completedAt);
    if (next == null) return null;
    return NextDue(formatDate(next), formatTime(next.hour * 60 + next.minute));
  }
  final next = nextOccurrence(recurrence, currentDue: date, completedOn: completedAt);
  if (next == null) return null;
  return NextDue(formatDate(next), recurrence.timeMinutes != null ? formatTime(recurrence.timeMinutes!) : dueTime);
}
