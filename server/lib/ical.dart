/// The calendar feed (FR-X8): a read-only iCalendar file of dated tasks that
/// Google Calendar, Apple Calendar, Outlook and others can subscribe to by
/// address. The address contains a secret token, so only people who have it
/// can read the feed; the person can replace it at any time.
library;

import 'dart:convert';

import 'package:taskflow_core/date_parser.dart';

import 'model.dart';

String _escape(String s) => s.replaceAll(r'\', r'\\').replaceAll(';', r'\;').replaceAll(',', r'\,').replaceAll('\r\n', r'\n').replaceAll('\n', r'\n');

/// Folds a content line to at most 75 bytes per line, never splitting a character.
String foldLine(String line) {
  if (utf8.encode(line).length <= 75) return line;
  final out = StringBuffer();
  var bytes = 0;
  var limit = 75;
  for (final rune in line.runes) {
    final ch = String.fromCharCode(rune);
    final n = utf8.encode(ch).length;
    if (bytes + n > limit) {
      out.write('\r\n ');
      bytes = 1; // the leading space counts
      limit = 75;
    }
    out.write(ch);
    bytes += n;
  }
  return out.toString();
}

String _compactDate(String iso) => iso.replaceAll('-', '');

String _stamp(DateTime utc) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}

/// The feed for the person [m] describes: one event for each open task with a
/// due date (at its time, or all day), and one all-day event for each open
/// task's deadline.
String buildCalendar(UserModel m, {String name = 'TaskFlow'}) {
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//TaskFlow//Task feed//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:${_escape(name)}',
    // Calendar apps that honour this refresh about hourly; Google decides for itself.
    'REFRESH-INTERVAL;VALUE=DURATION:PT1H',
    'X-PUBLISHED-TTL:PT1H',
  ];
  final stamp = _stamp(m.now.toUtc());
  final projects = {for (final p in m.projects()) p['id'] as String: p['name'] as String};
  for (final t in m.tasks()) {
    final id = t['id'] as String;
    final title = t['title'] as String;
    final due = t['due'] as Map<String, Object?>?;
    final project = projects[t['project_id']];
    final description = [
      if ((t['description'] as String).isNotEmpty) t['description'] as String,
      if (due?['recurrence'] != null) 'Repeats: ${due!['recurrence']}',
      if (project != null) 'Project: $project',
    ].join('\n');
    final priority = switch (t['priority']) { 1 => 1, 2 => 3, 3 => 5, _ => 0 };
    final labels = (t['labels'] as List).cast<String>();

    void event(String uid, String summary, String dateIso, {String? time, int minutes = 30}) {
      final d = parseIsoDate(dateIso);
      if (d == null) return;
      lines.addAll(['BEGIN:VEVENT', 'UID:$uid@taskflow', 'DTSTAMP:$stamp']);
      if (time != null && parseClock(time) != null) {
        final start = DateTime(d.year, d.month, d.day, parseClock(time)! ~/ 60, parseClock(time)! % 60);
        final end = start.add(Duration(minutes: minutes));
        String local(DateTime x) => '${_compactDate(formatDate(x))}T${x.hour.toString().padLeft(2, '0')}${x.minute.toString().padLeft(2, '0')}00';
        // No zone: the time is shown as written, whatever zone the viewer is in.
        lines.addAll(['DTSTART:${local(start)}', 'DTEND:${local(end)}']);
      } else {
        lines.addAll(['DTSTART;VALUE=DATE:${_compactDate(dateIso)}', 'DTEND;VALUE=DATE:${_compactDate(formatDate(DateTime(d.year, d.month, d.day + 1)))}']);
      }
      lines.add('SUMMARY:${_escape(summary)}');
      if (description.isNotEmpty) lines.add('DESCRIPTION:${_escape(description)}');
      if (labels.isNotEmpty) lines.add('CATEGORIES:${labels.map(_escape).join(',')}');
      if (priority != 0) lines.add('PRIORITY:$priority');
      lines.addAll(['TRANSP:TRANSPARENT', 'STATUS:CONFIRMED', 'END:VEVENT']);
    }

    if (due != null) event(id, title, due['date'] as String, time: due['time'] as String?, minutes: (t['duration_minutes'] as int?) ?? 30);
    final deadline = t['deadline'] as String?;
    if (deadline != null) event('$id-deadline', 'Deadline: $title', deadline);
  }
  lines.add('END:VCALENDAR');
  return '${lines.map(foldLine).join('\r\n')}\r\n';
}
