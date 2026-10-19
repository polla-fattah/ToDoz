import 'package:flutter/material.dart';
import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/recurrence.dart';

import '../data/database.dart';

/// The colours the calendar is drawn in: Google Calendar's blue for today, thin grey lines, solid event colours, a red
/// "now" line. Light and dark, the same on every device (the web client uses the same values in calendar.css).
class CalendarPalette {
  const CalendarPalette._({
    required this.surface,
    required this.blue,
    required this.onBlue,
    required this.blueSoft,
    required this.red,
    required this.line,
    required this.text,
    required this.text2,
    required this.hover,
  });

  /// The page behind the calendar: white, or Google's dark grey.
  final Color surface;
  final Color blue;
  final Color onBlue;
  final Color blueSoft;
  final Color red;
  final Color line;
  final Color text;
  final Color text2;
  final Color hover;

  static const _light = CalendarPalette._(
    surface: Colors.white,
    blue: Color(0xFF1A73E8),
    onBlue: Colors.white,
    blueSoft: Color(0xFFE8F0FE),
    red: Color(0xFFEA4335),
    line: Color(0xFFDADCE0),
    text: Color(0xFF3C4043),
    text2: Color(0xFF70757A),
    hover: Color(0xFFF1F3F4),
  );

  static const _dark = CalendarPalette._(
    surface: Color(0xFF202124),
    blue: Color(0xFF8AB4F8),
    onBlue: Color(0xFF202124),
    blueSoft: Color(0xFF2B3A55),
    red: Color(0xFFF28B82),
    line: Color(0xFF3C4043),
    text: Color(0xFFE8EAED),
    text2: Color(0xFF9AA0A6),
    hover: Color(0xFF2A2B30),
  );

  static CalendarPalette of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  /// Google Calendar's event colours (Tomato, Flamingo, Tangerine, Banana, Sage, Basil, Peacock, Blueberry, Lavender,
  /// Grape, Graphite).
  static const eventColours = [
    Color(0xFFD50000),
    Color(0xFFE67C73),
    Color(0xFFF4511E),
    Color(0xFFF6BF26),
    Color(0xFF33B679),
    Color(0xFF0B8043),
    Color(0xFF039BE5),
    Color(0xFF3F51B5),
    Color(0xFF7986CB),
    Color(0xFF8E24AA),
    Color(0xFF616161),
  ];

  /// The Google event colour closest to a project's colour, so the calendar is drawn in Google's palette.
  static Color eventColour(Color c) {
    var best = eventColours.first;
    var bestDistance = double.infinity;
    for (final e in eventColours) {
      final dr = (e.r - c.r) * 255, dg = (e.g - c.g) * 255, db = (e.b - c.b) * 255;
      final d = dr * dr + dg * dg + db * db;
      if (d < bestDistance) {
        best = e;
        bestDistance = d;
      }
    }
    return best;
  }

  /// Text that stays readable on a filled event colour: white on dark colours, near-black on light ones.
  static Color onColour(Color c) => c.computeLuminance() > 0.4 ? const Color(0xFF202124) : Colors.white;
}

/// A day on which a repeating task comes round again. It is shown faded (the task itself sits on its next date);
/// tapping it opens the task.
class RepeatCopy {
  const RepeatCopy(this.task, this.day);
  final Task task;
  final String day;
}

/// The copies of repeating [tasks] that fall on the shown [days], after today and after each task's own date.
List<RepeatCopy> repeatCopies(List<Task> tasks, List<String> days, DateTime now) {
  final first = days.first;
  final last = parseIsoDate(days.last)!;
  final today = formatDate(dateOnly(now));
  final out = <RepeatCopy>[];
  for (final t in tasks) {
    if (t.recurrence == null || t.dueDate == null) continue;
    final Recurrence r;
    try {
      r = parseRecurrence(t.recurrence!, now);
    } on RecurrenceException {
      continue;
    }
    for (final d in occurrencesBetween(r, due: parseIsoDate(t.dueDate!)!, to: last)) {
      final day = formatDate(d);
      if (day.compareTo(first) >= 0 && day.compareTo(today) > 0) out.add(RepeatCopy(t, day));
    }
  }
  return out;
}

/// The time zone the grid is drawn in, as Google's grid shows it (GMT+3, GMT+5:30).
String zoneLabel(DateTime now) {
  final off = now.timeZoneOffset;
  final minutes = off.inMinutes.abs();
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return 'GMT${off.isNegative ? '-' : '+'}$h${m == 0 ? '' : ':${m.toString().padLeft(2, '0')}'}';
}
