import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/time_grid.dart';

import '../data/database.dart';
import 'calendar_style.dart';
import 'catalog.dart';
import 'common.dart';
import 'quick_add_sheet.dart';
import 'task_widgets.dart';

/// A month as six weeks. Tasks are chips in their day (small dots when a cell is narrow); press and drag one onto
/// another day to move it (its time stays); tap the number to open that day; tap an empty spot to add a task.
class MonthGrid extends StatelessWidget {
  const MonthGrid({super.key, required this.days, required this.month, required this.tasks, this.repeats = const [], required this.onPickDay, required this.onSwipe});

  final List<String> days;

  /// The month being shown (1-12): days of other months are dimmed.
  final int month;
  final List<Task> tasks;

  /// Later days of repeating tasks, shown faded.
  final List<RepeatCopy> repeats;
  final ValueChanged<String> onPickDay;
  final ValueChanged<int> onSwipe;

  @override
  Widget build(BuildContext context) {
    final pal = CalendarPalette.of(context);
    final today = formatDate(dateOnly(AppScope.repoOf(context).now));
    final byDay = <String, List<_Entry>>{};
    for (final t in tasks) {
      if (t.dueDate != null) byDay.putIfAbsent(t.dueDate!, () => []).add(_Entry(t, false));
    }
    for (final r in repeats) {
      byDay.putIfAbsent(r.day, () => []).add(_Entry(r.task, true));
    }
    for (final list in byDay.values) {
      list.sort((a, b) {
        final byTime = (a.task.dueTime ?? '').compareTo(b.task.dueTime ?? '');
        return byTime != 0 ? byTime : a.task.priority.compareTo(b.task.priority);
      });
    }
    const names = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final first = parseIsoDate(days.first)!;

    return ColoredBox(
      color: pal.surface,
      child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() > 350) onSwipe(v < 0 ? 1 : -1);
      },
      child: Column(children: [
        Row(children: [
          for (var i = 0; i < 7; i++)
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 8, bottom: 6), child: Center(child: Text(names[DateTime(first.year, first.month, first.day + i).weekday].toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.8, color: pal.text2))))),
        ]),
        Container(height: 1, color: pal.line),
        Expanded(
          child: Column(children: [
            for (var w = 0; w < 6; w++)
              Expanded(
                child: Row(children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(child: _Cell(day: days[w * 7 + i], inMonth: parseIsoDate(days[w * 7 + i])!.month == month, isToday: days[w * 7 + i] == today, entries: byDay[days[w * 7 + i]] ?? const [], onPickDay: onPickDay)),
                ]),
              ),
          ]),
        ),
      ]),
      ),
    );
  }
}

const _short = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class _Entry {
  const _Entry(this.task, this.repeat);
  final Task task;

  /// A later day of a repeating task, not the task itself.
  final bool repeat;
}

class _Cell extends StatelessWidget {
  const _Cell({required this.day, required this.inMonth, required this.isToday, required this.entries, required this.onPickDay});
  final String day;
  final bool inMonth;
  final bool isToday;
  final List<_Entry> entries;
  final ValueChanged<String> onPickDay;

  @override
  Widget build(BuildContext context) {
    final pal = CalendarPalette.of(context);
    final catalog = AppScope.of(context);
    final tasks = [for (final e in entries) e.task];
    final date = parseIsoDate(day)!;
    return DragTarget<String>(
      onAcceptWithDetails: (d) => guarded(context, () => AppScope.repoOf(context).updateTask(d.data, dueDate: Value(day))),
      builder: (context, candidates, _) => LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 96;
        final room = ((box.maxHeight - 32) / 23).floor().clamp(0, 6);
        final shown = wide ? (entries.length > room ? (room - 1).clamp(0, 6) : entries.length) : 0;
        final more = entries.length - shown;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showQuickAdd(context, defaultDue: day),
          child: Container(
            decoration: BoxDecoration(
              color: candidates.isNotEmpty ? pal.blueSoft : null,
              border: Border(right: BorderSide(color: pal.line), bottom: BorderSide(color: pal.line)),
            ),
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Align(
                alignment: Alignment.center,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onPickDay(day),
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    decoration: BoxDecoration(color: isToday ? pal.blue : null, borderRadius: BorderRadius.circular(14)),
                    child: Center(widthFactor: 1, heightFactor: 1, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(date.day == 1 ? '1 ${_short[date.month]}' : '${date.day}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: isToday ? pal.onBlue : (inMonth ? pal.text : pal.text2))))),
                  ),
                ),
              ),
              if (wide)
                for (final e in entries.take(shown))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: e.repeat
                        // A later day of a repeating task: faded, not draggable; a tap opens the task.
                        ? Opacity(
                            opacity: 0.55,
                            child: GestureDetector(onTap: () => openTask(context, e.task.id), child: _Chip(task: e.task, colour: CalendarPalette.eventColour(catalog.colorOf(e.task.projectId)), use24h: catalog.use24h)),
                          )
                        : LongPressDraggable<String>(
                            data: e.task.id,
                            delay: const Duration(milliseconds: 250),
                            feedback: Material(elevation: 6, borderRadius: BorderRadius.circular(6), child: Padding(padding: const EdgeInsets.all(8), child: Text(e.task.title))),
                            childWhenDragging: Opacity(opacity: 0.35, child: _Chip(task: e.task, colour: CalendarPalette.eventColour(catalog.colorOf(e.task.projectId)), use24h: catalog.use24h)),
                            child: GestureDetector(onTap: () => openTask(context, e.task.id), child: _Chip(task: e.task, colour: CalendarPalette.eventColour(catalog.colorOf(e.task.projectId)), use24h: catalog.use24h)),
                          ),
                  ),
              if (wide && more > 0)
                InkWell(onTap: () => onPickDay(day), child: Padding(padding: const EdgeInsets.only(left: 6, top: 1), child: Text('$more more', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: pal.text2)))),
              if (!wide && entries.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Wrap(alignment: WrapAlignment.center, spacing: 2, runSpacing: 2, children: [
                    for (final t in tasks.take(4)) Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: CalendarPalette.eventColour(catalog.colorOf(t.projectId)))),
                    if (tasks.length > 4) Text('+', style: TextStyle(fontSize: 8, color: pal.text2, height: 0.8)),
                  ]),
                ),
            ]),
          ),
        );
      }),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.task, required this.colour, required this.use24h});
  final Task task;
  final Color colour;
  final bool use24h;

  @override
  Widget build(BuildContext context) {
    final pal = CalendarPalette.of(context);
    final minutes = minutesOf(task.dueTime);
    // A task with a time is a dot, the time and the title; one without is a solid bar, as in Google Calendar.
    if (minutes != null) {
      return Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: colour)),
          const SizedBox(width: 4),
          Text('${formatTime(minutes, use24h: use24h)} ', style: TextStyle(fontSize: 12, color: pal.text)),
          Expanded(child: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: pal.text))),
        ]),
      );
    }
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(4)),
      child: Align(alignment: Alignment.centerLeft, child: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: CalendarPalette.onColour(colour)))),
    );
  }
}
