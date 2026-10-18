/// Quick Add line parser (FR-Q1 to FR-Q3).
///
/// Recognises: dates and times, repeats (`every other week`), `p1`-`p4`,
/// `%label` / `@label`, `#project`, `/section`, `!reminder`, `{deadline}`.
/// The assignee `+name` arrives with R6.
library;

import 'date_parser.dart';
import 'recurrence.dart';
import 'reminder.dart';

enum QuickAddKind { date, time, repeat, deadline, reminder, priority, label, project, section }

/// A recognised token, used to highlight the typed text live (FR-Q1).
class QuickAddToken {
  const QuickAddToken(this.kind, this.start, this.end);
  final QuickAddKind kind;
  final int start;
  final int end;
}

class QuickAddResult {
  const QuickAddResult({
    required this.title,
    required this.tokens,
    this.due,
    this.dueTime,
    this.recurrence,
    this.repeatError,
    this.deadline,
    this.reminders = const [],
    this.priority,
    this.labels = const [],
    this.projectName,
    this.sectionName,
  });

  /// The text left after every recognised token is removed.
  final String title;
  final List<QuickAddToken> tokens;

  /// The due date: a typed date, or the first date of a typed repeat.
  final DateTime? due;

  /// Minutes after midnight, from a typed time or a repeat's time.
  final int? dueTime;
  final Recurrence? recurrence;

  /// Why a typed repeat was not understood; the text stays in the title.
  final String? repeatError;
  final DateTime? deadline;
  final List<ReminderSpec> reminders;

  /// 1 (urgent) to 4 (none); null when the line has no `pN` token.
  final int? priority;
  final List<String> labels;

  /// Raw names as typed; the caller resolves them (and offers to create
  /// unknown ones, FR-Q5).
  final String? projectName;
  final String? sectionName;
}

final _priority = RegExp(r'(?<!\S)p([1-4])(?!\S)', caseSensitive: false);
final _label = RegExp(r'(?<!\S)[%@]([\p{L}\p{N}_-]+)', unicode: true);
final _project = RegExp(r'(?<!\S)#(?:"([^"]+)"|([\p{L}\p{N}_-]+))', unicode: true);
final _section = RegExp(r'(?<!\S)/(?:"([^"]+)"|([\p{L}\p{N}_-]+))', unicode: true);
final _deadline = RegExp(r'\{([^{}]+)\}');
final _reminder = RegExp(
  r'(?<!\S)!(\d{1,2}:\d{2}|\d{1,2}\s*(?:am|pm)|\d+\s*(?:min|mins|minute|minutes|m|hour|hours|hr|hrs|h|day|days|d)(?:\s+before)?)(?!\S)',
  caseSensitive: false,
);

/// Parses one Quick Add line. When [parseDates] is false (the owner turned
/// "smart date recognition" off, FR-U2) dates, times and repeats stay in the
/// title; explicit `{}` and `!` tokens still work.
QuickAddResult parseQuickAdd(
  String input,
  DateTime now, {
  bool parseDates = true,
  int weekStart = 1,
}) {
  final tokens = <QuickAddToken>[];
  var working = input;

  String blank(String s, int start, int end) => s.replaceRange(start, end, ' ' * (end - start));
  void take(QuickAddKind kind, int start, int end) {
    tokens.add(QuickAddToken(kind, start, end));
    working = blank(working, start, end);
  }

  int? priority;
  for (final m in _priority.allMatches(working).toList()) {
    priority ??= int.parse(m[1]!);
    take(QuickAddKind.priority, m.start, m.end);
  }

  final labels = <String>[];
  for (final m in _label.allMatches(working).toList()) {
    labels.add(m[1]!.toLowerCase());
    take(QuickAddKind.label, m.start, m.end);
  }

  String? projectName;
  final pm = _project.firstMatch(working);
  if (pm != null) {
    projectName = pm[1] ?? pm[2];
    take(QuickAddKind.project, pm.start, pm.end);
  }

  // A section only makes sense after a project (FR-Q2).
  String? sectionName;
  if (projectName != null) {
    final sm = _section.firstMatch(working);
    if (sm != null) {
      sectionName = sm[1] ?? sm[2];
      take(QuickAddKind.section, sm.start, sm.end);
    }
  }

  // {march 30}: a deadline, separate from the due date.
  DateTime? deadline;
  for (final m in _deadline.allMatches(working).toList()) {
    final dm = parseDate(m[1]!, now, weekStart: weekStart);
    if (dm != null && deadline == null) {
      deadline = dm.date;
      take(QuickAddKind.deadline, m.start, m.end);
    }
  }

  // !14:00, !30 min before
  final reminders = <ReminderSpec>[];
  for (final m in _reminder.allMatches(working).toList()) {
    final spec = parseReminderText(m[1]!);
    if (spec != null) {
      reminders.add(spec);
      take(QuickAddKind.reminder, m.start, m.end);
    }
  }

  DateTime? due;
  int? dueTime;
  Recurrence? recurrence;
  String? repeatError;
  if (parseDates) {
    // The repeat is found first: its phrase may contain dates and times
    // ("every fri at noon starting aug 3") that must not be read separately.
    final found = findRecurrence(working, now);
    if (found.match != null) {
      recurrence = found.match!.recurrence;
      take(QuickAddKind.repeat, found.match!.start, found.match!.end);
      dueTime = recurrence.timeMinutes;
    } else {
      repeatError = found.error;
    }

    final dm = parseDate(working, now, weekStart: weekStart);
    if (dm != null) {
      due = dm.date;
      take(QuickAddKind.date, dm.start, dm.end);
    }
    final tm = parseTime(working);
    if (tm != null) {
      dueTime = tm.minutes;
      take(QuickAddKind.time, tm.start, tm.end);
    }
    if (recurrence != null && due == null) due = firstOccurrence(recurrence, now);
  }

  // Build the title from the original text minus the token spans.
  tokens.sort((a, b) => a.start.compareTo(b.start));
  final masked = StringBuffer();
  var cursor = 0;
  for (final t in tokens) {
    masked.write(input.substring(cursor, t.start));
    cursor = t.end;
  }
  masked.write(input.substring(cursor));
  final title = masked.toString().replaceAll(RegExp(r'\s+'), ' ').trim();

  return QuickAddResult(
    title: title,
    tokens: tokens,
    due: due,
    dueTime: dueTime,
    recurrence: recurrence,
    repeatError: repeatError,
    deadline: deadline,
    reminders: reminders,
    priority: priority,
    labels: labels.toSet().toList(),
    projectName: projectName,
    sectionName: sectionName,
  );
}

/// Normalises a project or section name so `#work-research` matches
/// "Work Research" (as 1.0 did for `#project-id`).
String normaliseName(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
