import 'package:flutter/material.dart';
import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/time_grid.dart';

import '../data/database.dart';
import 'calendar_style.dart';
import 'catalog.dart';
import 'common.dart';
import 'month_grid.dart';
import 'time_grid.dart';
import 'views.dart';

/// Window width from which a whole week fits (a computer or a tablet; not a phone).
const calendarWeekMinWidth = 900.0;

const _modeLabels = {CalendarMode.day: 'Day', CalendarMode.threeDays: '3 days', CalendarMode.week: 'Week', CalendarMode.month: 'Month'};

/// The Calendar: Day, 3 days, Week (wide windows only) and Month, over [tasks] (open tasks with a date).
/// The chosen view is remembered; swipe sideways (or use the arrows) to move through time.
class CalendarView extends StatefulWidget {
  const CalendarView({super.key, required this.tasks, this.initialDay});

  final List<Task> tasks;

  /// The day to open on (a test hook; normally today).
  final String? initialDay;

  @override
  State<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends State<CalendarView> {
  String? _anchorOrNull;
  String get _anchor => _anchorOrNull ??= widget.initialDay ?? formatDate(dateOnly(AppScope.repoOf(context).now));
  set _anchor(String v) => _anchorOrNull = v;

  /// As Google's header does: the month (or both months) and the year; a single day is written out. On a phone the
  /// year is left out when it is this year, to leave room for the buttons.
  String _title(CalendarMode mode, List<String> days, {required bool compact, required int thisYear}) {
    const months = ['', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    const short = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final first = parseIsoDate(days.first)!;
    final last = parseIsoDate(days.last)!;
    final a = parseIsoDate(_anchor)!;
    String year(int y) => compact && y == thisYear ? '' : ' $y';
    switch (mode) {
      case CalendarMode.month:
        return '${months[a.month]}${year(a.year)}';
      case CalendarMode.day:
        return '${first.day} ${months[first.month]}${year(first.year)}';
      case CalendarMode.threeDays:
      case CalendarMode.week:
        if (first.year != last.year) return '${short[first.month]}${year(first.year)} – ${short[last.month]}${year(last.year)}';
        if (first.month != last.month) return '${short[first.month]} – ${short[last.month]}${year(last.year)}';
        return '${months[first.month]}${year(first.year)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final width = MediaQuery.of(context).size.width;
    final wide = width >= calendarWeekMinWidth;
    var mode = catalog.calendarMode;
    if (mode == CalendarMode.week && !wide) mode = CalendarMode.threeDays;
    final today = formatDate(dateOnly(catalog.repo.now));
    final days = daysOf(mode, _anchor, weekStart: catalog.weekStart);
    final modes = [for (final m in CalendarMode.values) if (m != CalendarMode.week || wide) m];
    void step(int dir) => setState(() => _anchor = shiftAnchor(mode, _anchor, dir));
    void pick(String day) {
      catalog.setCalendarMode(CalendarMode.day);
      setState(() => _anchor = day);
    }

    final pal = CalendarPalette.of(context);
    final repeats = repeatCopies(widget.tasks, days, catalog.repo.now);
    final compact = width < 600;
    final thisYear = catalog.repo.now.year;
    final pillShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: pal.line));
    final pillText = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: pal.text);

    // Today, back and forward, the month, and the view picker: one row, as in Google Calendar.
    final controls = Row(children: [
      SizedBox(
        height: 36,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(shape: StadiumBorder(side: BorderSide(color: pal.line)), padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16), foregroundColor: pal.text, textStyle: pillText),
          onPressed: () => setState(() => _anchor = today),
          child: const Text('Today'),
        ),
      ),
      const SizedBox(width: 2),
      IconButton(tooltip: 'Previous', visualDensity: VisualDensity.compact, color: pal.text2, icon: const Icon(Icons.chevron_left), onPressed: () => step(-1)),
      IconButton(tooltip: 'Next', visualDensity: VisualDensity.compact, color: pal.text2, icon: const Icon(Icons.chevron_right), onPressed: () => step(1)),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(left: 4, right: 4),
          child: Text(_title(mode, days, compact: compact, thisYear: thisYear), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: compact ? 18 : 22, fontWeight: FontWeight.w400, color: pal.text)),
        ),
      ),
      PopupMenuButton<CalendarMode>(
        tooltip: 'View',
        position: PopupMenuPosition.under,
        initialValue: mode,
        onSelected: catalog.setCalendarMode,
        itemBuilder: (_) => [for (final m in modes) PopupMenuItem(value: m, child: Text(_modeLabels[m]!))],
        shape: pillShape,
        child: Container(
          key: const Key('calendar-view-menu'),
          height: 36,
          padding: EdgeInsets.only(left: compact ? 12 : 16, right: 6),
          decoration: ShapeDecoration(shape: pillShape),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_modeLabels[mode]!, style: pillText),
            Icon(Icons.arrow_drop_down, color: pal.text2),
          ]),
        ),
      ),
    ]);

    return Column(children: [
      Padding(padding: EdgeInsets.fromLTRB(compact ? 8 : 16, 8, compact ? 8 : 16, 4), child: controls),
      Expanded(
        child: mode == CalendarMode.month
            ? MonthGrid(days: days, month: parseIsoDate(_anchor)!.month, tasks: widget.tasks, repeats: repeats, onPickDay: pick, onSwipe: step)
            : TimeGrid(key: ValueKey('${mode.name}-${days.first}'), days: days, tasks: widget.tasks, repeats: repeats, onPickDay: pick, onSwipe: step),
      ),
    ]);
  }
}

/// The Calendar destination: every open task that has a date.
class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.repoOf(context);
    return Screen(
      title: 'Calendar',
      background: CalendarPalette.of(context).surface,
      automaticallyImplyLeading: false,
      selectable: false,
      body: Live<List<Task>>(
        create: repo.watchScheduled,
        builder: (context, data) => CalendarView(tasks: data ?? const []),
      ),
    );
  }
}
