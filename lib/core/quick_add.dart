/// Quick Add line parser (FR-Q1, FR-Q2 for R1: date, p1-p4, %label/@label,
/// #project, /section). Reminders (`!`), deadlines (`{}`) and assignees (`+`)
/// arrive with R2 and R6.
library;

import 'date_parser.dart';

enum QuickAddKind { date, priority, label, project, section }

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
    this.priority,
    this.labels = const [],
    this.projectName,
    this.sectionName,
  });

  /// The text left after every recognised token is removed.
  final String title;
  final List<QuickAddToken> tokens;
  final DateTime? due;

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

/// Parses one Quick Add line. When [parseDates] is false (the owner turned
/// "smart date recognition" off, FR-U2) date phrases stay in the title.
QuickAddResult parseQuickAdd(
  String input,
  DateTime now, {
  bool parseDates = true,
  int weekStart = 1,
}) {
  final tokens = <QuickAddToken>[];
  final masked = StringBuffer();
  // A same-length copy of the input where recognised tokens are blanked, so
  // later passes (the date parser) cannot match inside them.
  var working = input;

  String blank(String s, int start, int end) =>
      s.replaceRange(start, end, ' ' * (end - start));

  int? priority;
  for (final m in _priority.allMatches(working).toList()) {
    priority ??= int.parse(m[1]!);
    tokens.add(QuickAddToken(QuickAddKind.priority, m.start, m.end));
  }
  for (final t in tokens.where((t) => t.kind == QuickAddKind.priority)) {
    working = blank(working, t.start, t.end);
  }

  final labels = <String>[];
  for (final m in _label.allMatches(working).toList()) {
    labels.add(m[1]!.toLowerCase());
    tokens.add(QuickAddToken(QuickAddKind.label, m.start, m.end));
    working = blank(working, m.start, m.end);
  }

  String? projectName;
  final pm = _project.firstMatch(working);
  if (pm != null) {
    projectName = pm[1] ?? pm[2];
    tokens.add(QuickAddToken(QuickAddKind.project, pm.start, pm.end));
    working = blank(working, pm.start, pm.end);
  }

  // A section only makes sense after a project (FR-Q2).
  String? sectionName;
  if (projectName != null) {
    final sm = _section.firstMatch(working);
    if (sm != null) {
      sectionName = sm[1] ?? sm[2];
      tokens.add(QuickAddToken(QuickAddKind.section, sm.start, sm.end));
      working = blank(working, sm.start, sm.end);
    }
  }

  DateTime? due;
  if (parseDates) {
    final dm = parseDate(working, now, weekStart: weekStart);
    if (dm != null) {
      due = dm.date;
      tokens.add(QuickAddToken(QuickAddKind.date, dm.start, dm.end));
      working = blank(working, dm.start, dm.end);
    }
  }

  // Build the title from the original text minus the token spans.
  tokens.sort((a, b) => a.start.compareTo(b.start));
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
    priority: priority,
    labels: labels.toSet().toList(),
    projectName: projectName,
    sectionName: sectionName,
  );
}

/// Normalises a project or section name so `#work-research` matches
/// "Work Research" (as 1.0 did for `#project-id`).
String normaliseName(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
