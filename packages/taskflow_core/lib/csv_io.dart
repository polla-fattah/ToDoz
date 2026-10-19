/// Reading and writing tasks as text: Todoist's CSV layout (FR-X4, FR-X5,
/// FR-X6), plain lines and Markdown checklists (FR-X7), and iCalendar tasks.
///
/// The Todoist layout is the project export's:
/// `TYPE,CONTENT,DESCRIPTION,PRIORITY,INDENT,AUTHOR,RESPONSIBLE,DATE,DATE_LANG,TIMEZONE`
/// with `section`, `task` and `note` rows. It was written from Todoist's
/// documentation and examples, not checked against a live export file.
library;

import 'date_parser.dart';
import 'quick_add.dart';
import 'recurrence.dart';

const todoistCsvHeader = ['TYPE', 'CONTENT', 'DESCRIPTION', 'PRIORITY', 'INDENT', 'AUTHOR', 'RESPONSIBLE', 'DATE', 'DATE_LANG', 'TIMEZONE'];

// -----------------------------------------------------------------------------
// CSV text
// -----------------------------------------------------------------------------

/// Splits CSV text into rows of fields: quoted fields, doubled quotes, and
/// line breaks inside quotes. A byte order mark and `\r\n` are accepted.
List<List<String>> parseCsvRows(String text) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var fieldStarted = false;
  void endField() {
    row.add(field.toString());
    field.clear();
    fieldStarted = false;
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"' && !fieldStarted) {
      inQuotes = true;
      fieldStarted = true;
    } else if (c == ',') {
      endField();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
    } else {
      field.write(c);
      fieldStarted = true;
    }
  }
  if (field.isNotEmpty || fieldStarted || row.isNotEmpty) endRow();
  return rows;
}

String csvField(String s) => s.contains(RegExp(r'[",\r\n]')) || s != s.trim() ? '"${s.replaceAll('"', '""')}"' : s;

String writeCsvRows(List<List<String>> rows) => '${rows.map((r) => r.map(csvField).join(',')).join('\r\n')}\r\n';

// -----------------------------------------------------------------------------
// What an import creates
// -----------------------------------------------------------------------------

/// One thing to create. [kind] is `section`, `task` or `note`.
class ImportItem {
  ImportItem.section(this.content)
      : kind = 'section',
        description = '',
        priority = 4,
        indent = 1,
        date = null,
        labels = const [],
        done = false;

  ImportItem.task(
    this.content, {
    this.description = '',
    this.priority = 4,
    this.indent = 1,
    this.date,
    this.labels = const [],
    this.done = false,
  }) : kind = 'task';

  ImportItem.note(this.content)
      : kind = 'note',
        description = '',
        priority = 4,
        indent = 1,
        date = null,
        labels = const [],
        done = false;

  final String kind;
  final String content;
  final String description;
  final int priority;

  /// 1 = top level .. 4.
  final int indent;

  /// A date phrase or `YYYY-MM-DD[ HH:MM]`, as Todoist writes in DATE.
  final String? date;
  final List<String> labels;
  final bool done;

  @override
  String toString() => '$kind($content, p$priority, indent $indent, $date, $labels)';
}

class ImportReport {
  ImportReport({required this.items, this.skipped = 0, this.warnings = const []});
  final List<ImportItem> items;
  final int skipped;
  final List<String> warnings;

  int get taskCount => items.where((i) => i.kind == 'task').length;
}

final _labelAtEnd = RegExp(r'(?:^|\s)@([\p{L}\p{N}_-]+)', unicode: true);

/// Reads a Todoist CSV project export. A `note` row is a comment on the task
/// above it (or on the project, before any task). Rows it does not know are
/// skipped and counted.
ImportReport parseTodoistCsv(String text) {
  final rows = parseCsvRows(text);
  if (rows.isEmpty) throw const FormatException('The file is empty');
  final header = rows.first.map((h) => h.trim().toUpperCase()).toList();
  if (!header.contains('TYPE') || !header.contains('CONTENT')) {
    throw const FormatException('This is not a Todoist CSV: the TYPE and CONTENT columns are missing');
  }
  int col(String name) => header.indexOf(name);
  String cell(List<String> r, String name) {
    final i = col(name);
    return i >= 0 && i < r.length ? r[i] : '';
  }

  final items = <ImportItem>[];
  var skipped = 0;
  final warnings = <String>[];
  for (var n = 1; n < rows.length; n++) {
    final r = rows[n];
    if (r.every((c) => c.trim().isEmpty)) continue;
    final type = cell(r, 'TYPE').trim().toLowerCase();
    var content = cell(r, 'CONTENT').trim();
    switch (type) {
      case 'section':
        if (content.isNotEmpty) items.add(ImportItem.section(content));
      case 'task':
        if (content.isEmpty) {
          skipped++;
          continue;
        }
        final labels = <String>[];
        for (final m in _labelAtEnd.allMatches(content)) {
          labels.add(m[1]!.toLowerCase());
        }
        if (labels.isNotEmpty) content = content.replaceAll(_labelAtEnd, '').replaceAll(RegExp(r'\s+'), ' ').trim();
        if (content.isEmpty) {
          skipped++;
          continue;
        }
        final p = int.tryParse(cell(r, 'PRIORITY').trim()) ?? 4;
        final indent = (int.tryParse(cell(r, 'INDENT').trim()) ?? 1).clamp(1, 4);
        final date = cell(r, 'DATE').trim();
        items.add(ImportItem.task(
          content,
          description: cell(r, 'DESCRIPTION'),
          priority: p.clamp(1, 4),
          indent: indent,
          date: date.isEmpty ? null : date,
          labels: labels,
        ));
      case 'note':
        if (content.isNotEmpty) items.add(ImportItem.note(content));
      case 'meta':
        break; // view settings
      default:
        skipped++;
    }
  }
  if (items.isEmpty) warnings.add('No tasks were found in this file');
  return ImportReport(items: items, skipped: skipped, warnings: warnings);
}

// -----------------------------------------------------------------------------
// Writing
// -----------------------------------------------------------------------------

/// One open task to export.
class ExportTask {
  const ExportTask({
    required this.title,
    this.description = '',
    this.priority = 4,
    this.indent = 1,
    this.dueDate,
    this.dueTime,
    this.recurrence,
    this.labels = const [],
    this.comments = const [],
  });
  final String title;
  final String description;
  final int priority;
  final int indent;
  final String? dueDate;
  final String? dueTime;
  final String? recurrence;
  final List<String> labels;
  final List<String> comments;
}

/// A section and the tasks in it. A null [name] is "no section", written first.
class ExportSection {
  const ExportSection(this.name, this.tasks);
  final String? name;
  final List<ExportTask> tasks;
}

/// Writes a project in Todoist's layout. With [template] there are no dates:
/// the project can be copied as a fresh start (FR-X6).
String writeTodoistCsv(List<ExportSection> sections, {bool template = false, List<String> projectNotes = const [], String timezone = ''}) {
  final rows = <List<String>>[todoistCsvHeader];
  for (final n in projectNotes) {
    rows.add(['note', n, '', '', '', '', '', '', '', '']);
  }
  for (final s in sections) {
    if (s.name != null) rows.add(['section', s.name!, '', '', '', '', '', '', '', '']);
    for (final t in s.tasks) {
      final content = [t.title, for (final l in t.labels) '@$l'].join(' ');
      String date = '';
      if (!template) {
        if (t.recurrence != null) {
          date = t.recurrence!;
        } else if (t.dueDate != null) {
          date = t.dueTime == null ? t.dueDate! : '${t.dueDate} ${t.dueTime}';
        }
      }
      rows.add(['task', content, t.description, '${t.priority}', '${t.indent}', '', '', date, date.isEmpty ? '' : 'en', date.isEmpty ? '' : timezone]);
      for (final c in t.comments) {
        rows.add(['note', c, '', '', '', '', '', '', '', '']);
      }
    }
    rows.add(['', '', '', '', '', '', '', '', '', '']);
  }
  return writeCsvRows(rows);
}

// -----------------------------------------------------------------------------
// Turning a DATE cell into task fields
// -----------------------------------------------------------------------------

class ImportedWhen {
  const ImportedWhen({this.dueDate, this.dueTime, this.recurrence});
  final String? dueDate;
  final String? dueTime;
  final String? recurrence;
}

/// Reads a DATE cell: `2026-10-14`, `2026-10-14 09:00`, `tomorrow at 4pm`,
/// `every mon at 8am`. Text it cannot read gives no date (the caller may
/// count it as a warning).
ImportedWhen? parseImportedWhen(String text, DateTime now, {int weekStart = 1}) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final q = parseQuickAdd(t, now, weekStart: weekStart);
  if (q.due == null && q.recurrence == null) return null;
  String? rec;
  for (final tok in q.tokens) {
    if (tok.kind == QuickAddKind.repeat) rec = t.substring(tok.start, tok.end).trim();
  }
  String? time;
  if (q.dueTime != null) time = formatTime(q.dueTime!);
  return ImportedWhen(dueDate: q.due == null ? null : formatDate(q.due!), dueTime: time, recurrence: rec);
}

/// Checks a repeat phrase parses (so an import never stores one the app cannot read).
bool isReadableRepeat(String phrase, DateTime now) {
  try {
    parseRecurrence(phrase, now);
    return true;
  } on RecurrenceException {
    return false;
  }
}

// -----------------------------------------------------------------------------
// Plain text and Markdown checklists (FR-X7)
// -----------------------------------------------------------------------------

/// One task per line. Understands `- [ ] item`, `- [x] item` (done), bullets
/// (`-`, `*`, `+`, `1.`), indentation for sub-tasks (two spaces or a tab per
/// level), and `# Heading` lines as sections.
ImportReport parseTextTasks(String text) {
  final items = <ImportItem>[];
  var skipped = 0;
  final bullet = RegExp(r'^(?:[-*+]|\d+[.)])\s+');
  final box = RegExp(r'^\[( |x|X)\]\s+');
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    if (raw.trim().isEmpty) continue;
    final heading = RegExp(r'^\s*#{1,6}\s+(.+?)\s*#*\s*$').firstMatch(raw);
    if (heading != null) {
      items.add(ImportItem.section(heading[1]!));
      continue;
    }
    final lead = RegExp(r'^[ \t]*').firstMatch(raw)![0]!;
    var level = 0;
    var spaces = 0;
    for (final ch in lead.split('')) {
      if (ch == '\t') {
        level++;
        spaces = 0;
      } else if (++spaces == 2) {
        level++;
        spaces = 0;
      }
    }
    var line = raw.trim();
    line = line.replaceFirst(bullet, '');
    var done = false;
    final b = box.firstMatch(line);
    if (b != null) {
      done = b[1] != ' ';
      line = line.substring(b.end);
    }
    line = line.trim();
    if (line.isEmpty) {
      skipped++;
      continue;
    }
    if (line.length > 500) line = line.substring(0, 500);
    items.add(ImportItem.task(line, indent: (level + 1).clamp(1, 4), done: done));
  }
  return ImportReport(items: items, skipped: skipped, warnings: items.isEmpty ? ['No tasks were found'] : const []);
}

// -----------------------------------------------------------------------------
// iCalendar tasks (VTODO)
// -----------------------------------------------------------------------------

String _unescapeIcs(String s) => s.replaceAll(r'\n', '\n').replaceAll(r'\N', '\n').replaceAll(r'\,', ',').replaceAll(r'\;', ';').replaceAll(r'\\', r'\');

String? _icsRepeat(String rrule) {
  final parts = {
    for (final p in rrule.split(';'))
      if (p.contains('=')) p.split('=')[0].toUpperCase(): p.split('=')[1],
  };
  final freq = parts['FREQ'];
  final interval = int.tryParse(parts['INTERVAL'] ?? '1') ?? 1;
  const days = {'MO': 'mon', 'TU': 'tue', 'WE': 'wed', 'TH': 'thu', 'FR': 'fri', 'SA': 'sat', 'SU': 'sun'};
  String every(String unit) => interval == 1 ? 'every $unit' : 'every $interval ${unit}s';
  switch (freq) {
    case 'DAILY':
      return every('day');
    case 'WEEKLY':
      final by = parts['BYDAY']?.split(',').map((d) => days[d.replaceAll(RegExp(r'[-+\d]'), '')]).whereType<String>().toList();
      if (by != null && by.isNotEmpty && interval == 1) return 'every ${by.join(', ')}';
      return every('week');
    case 'MONTHLY':
      return every('month');
    case 'YEARLY':
      return every('year');
  }
  return null;
}

/// Reads the VTODO entries of an iCalendar file: summary, description,
/// due date and time, priority, completion and a simple repeat.
ImportReport parseIcsTasks(String text) {
  final lines = <String>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    if ((raw.startsWith(' ') || raw.startsWith('\t')) && lines.isNotEmpty) {
      lines[lines.length - 1] += raw.substring(1); // a folded line continues the one above
    } else {
      lines.add(raw);
    }
  }
  final items = <ImportItem>[];
  var skipped = 0;
  Map<String, String>? cur;
  for (final line in lines) {
    final upper = line.toUpperCase();
    if (upper == 'BEGIN:VTODO') {
      cur = {};
    } else if (upper == 'END:VTODO') {
      final c = cur;
      cur = null;
      if (c == null) continue;
      final summary = _unescapeIcs(c['SUMMARY'] ?? '').trim();
      if (summary.isEmpty) {
        skipped++;
        continue;
      }
      final p = int.tryParse(c['PRIORITY'] ?? '') ?? 0;
      final priority = p == 0 ? 4 : (p == 1 ? 1 : (p <= 4 ? 2 : (p == 5 ? 3 : 4)));
      String? date;
      final due = c['DUE'] ?? c['DTSTART'];
      if (due != null) {
        final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2}))?').firstMatch(due);
        if (m != null) date = '${m[1]}-${m[2]}-${m[3]}${m[4] != null ? ' ${m[4]}:${m[5]}' : ''}';
      }
      final rep = c['RRULE'] == null ? null : _icsRepeat(c['RRULE']!);
      items.add(ImportItem.task(
        summary,
        description: _unescapeIcs(c['DESCRIPTION'] ?? ''),
        priority: priority,
        date: rep ?? date,
        done: (c['STATUS'] ?? '').toUpperCase() == 'COMPLETED',
      ));
    } else if (cur != null) {
      final i = line.indexOf(':');
      if (i > 0) {
        final name = line.substring(0, i).split(';').first.toUpperCase();
        cur.putIfAbsent(name, () => line.substring(i + 1));
      }
    }
  }
  return ImportReport(items: items, skipped: skipped, warnings: items.isEmpty ? ['No tasks were found in this calendar file'] : const []);
}
