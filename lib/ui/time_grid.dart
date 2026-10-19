import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/time_grid.dart';

import '../data/database.dart';
import 'calendar_style.dart';
import 'catalog.dart';
import 'common.dart';
import 'quick_add_sheet.dart';
import 'task_widgets.dart';

/// Pixels per hour on the grid.
const timeGridHourHeight = 56.0;
const _px = timeGridHourHeight / 60;
const _gutter = 52.0;

/// A task being moved or resized: where it would land if let go now.
class _Drag {
  const _Drag({required this.id, required this.resize, required this.day, required this.minutes, required this.allDay});
  final String id;
  final bool resize;
  final String day;

  /// Moving: the new start. Resizing: where the end is now.
  final int minutes;
  final bool allDay;
}

/// Calls back for one press on something that can be dragged: a tap, or a drag. A mouse starts dragging as soon as
/// it moves; a finger has to rest for a moment first (so scrolling still works).
class _DragSource extends StatefulWidget {
  const _DragSource({required this.child, required this.onTap, required this.onStart, required this.onUpdate, required this.onEnd, required this.onCancel});
  final Widget child;
  final VoidCallback onTap;
  final void Function(Offset global) onStart;
  final void Function(Offset global) onUpdate;
  final VoidCallback onEnd;
  final VoidCallback onCancel;

  @override
  State<_DragSource> createState() => _DragSourceState();
}

class _DragSourceState extends State<_DragSource> {
  int? _pointer;
  Offset _down = Offset.zero;
  PointerDeviceKind _kind = PointerDeviceKind.mouse;
  Timer? _timer;
  bool _active = false;

  void _start() {
    _active = true;
    widget.onStart(_down);
  }

  void _reset() {
    _timer?.cancel();
    _pointer = null;
    _active = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (_pointer != null) return;
          if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return;
          _pointer = e.pointer;
          _down = e.position;
          _kind = e.kind;
          _active = false;
          if (_kind != PointerDeviceKind.mouse) _timer = Timer(const Duration(milliseconds: 320), _start);
        },
        onPointerMove: (e) {
          if (e.pointer != _pointer) return;
          if (!_active) {
            final far = (e.position - _down).distance;
            if (_kind == PointerDeviceKind.mouse) {
              if (far > 4) _start();
            } else if (far > 10) {
              _reset(); // the finger is scrolling
              return;
            }
          }
          if (_active) widget.onUpdate(e.position);
        },
        onPointerUp: (e) {
          if (e.pointer != _pointer) return;
          final wasActive = _active;
          final moved = (e.position - _down).distance > 6;
          _reset();
          if (wasActive) {
            widget.onEnd();
          } else if (!moved) {
            widget.onTap();
          }
        },
        onPointerCancel: (e) {
          if (e.pointer != _pointer) return;
          final wasActive = _active;
          _reset();
          if (wasActive) widget.onCancel();
        },
        child: widget.child,
      );
}

/// One or more days side by side on a time grid. Timed tasks are blocks (press and drag to move, drag the bottom edge
/// to change the length, tap to open); tasks with a date but no time sit in the all-day row; tap an empty spot to add
/// a task there. The rules (overlap, snapping, what a drop means) are in taskflow_core/time_grid.dart.
class TimeGrid extends StatefulWidget {
  const TimeGrid({super.key, required this.days, required this.tasks, this.repeats = const [], required this.onPickDay, required this.onSwipe});

  final List<String> days;
  final List<Task> tasks;

  /// Later days of repeating tasks, shown faded (the task itself sits on its next date).
  final List<RepeatCopy> repeats;
  final ValueChanged<String> onPickDay;

  /// Previous (-1) or next (1), from a horizontal swipe.
  final ValueChanged<int> onSwipe;

  @override
  State<TimeGrid> createState() => _TimeGridState();
}

class _TimeGridState extends State<TimeGrid> {
  ScrollController? _scrollController;
  ScrollController get _scroll => _scrollController!;
  final _dayKeys = <String, GlobalKey>{};
  final _allDayKey = GlobalKey();
  final _drag = ValueNotifier<_Drag?>(null);
  Timer? _clock;
  DateTime _now = DateTime(2000);
  double _grab = 0;
  bool _scrollLocked = false;
  final _viewportKey = GlobalKey();
  Timer? _edgeScroll;
  Offset _pointer = Offset.zero;
  Task? _dragTask;
  bool _dragResize = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scrollController != null) return;
    // Start at the current time (when today is shown), otherwise at the morning.
    final repo = AppScope.repoOf(context);
    final now = repo.now;
    _now = now;
    final today = formatDate(dateOnly(now));
    final target = widget.days.contains(today) ? now.hour * 60 + now.minute - 90 : 7 * 60;
    _scrollController = ScrollController(initialScrollOffset: (target * _px).clamp(0, 24 * timeGridHourHeight - 200).toDouble());
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => mounted ? setState(() => _now = repo.now) : null);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _edgeScroll?.cancel();
    _scrollController?.dispose();
    _drag.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(String day) => _dayKeys.putIfAbsent(day, GlobalKey.new);

  Task? _task(String id) {
    for (final t in widget.tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The day and minute under a point on screen; the all-day row counts as a place without a minute.
  _Drag? _targetAt(Offset global, Task task, {required bool resize, required int startMinutes}) {
    String? best;
    var bestDist = double.infinity;
    for (final day in widget.days) {
      final box = _keyFor(day).currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final local = box.globalToLocal(global);
      final dist = local.dx < 0 ? -local.dx : (local.dx > box.size.width ? local.dx - box.size.width : 0.0);
      if (dist < bestDist) {
        best = day;
        bestDist = dist;
      }
    }
    if (best == null) return null;
    if (!resize) {
      final row = _allDayKey.currentContext?.findRenderObject() as RenderBox?;
      if (row != null && row.attached) {
        final local = row.globalToLocal(global);
        if (local.dy >= 0 && local.dy <= row.size.height) return _Drag(id: task.id, resize: false, day: best, minutes: startMinutes, allDay: true);
      }
    }
    final box = _keyFor(best).currentContext!.findRenderObject() as RenderBox;
    final minutes = ((box.globalToLocal(global).dy - _grab) / _px).round();
    return _Drag(id: task.id, resize: resize, day: best, minutes: minutes, allDay: false);
  }

  void _begin(Task task, Offset global, {required bool resize}) {
    final span = _spanOf(task);
    final box = _keyFor(task.dueDate!).currentContext?.findRenderObject() as RenderBox?;
    if (resize) {
      _grab = 0;
    } else if (box != null && task.dueTime != null) {
      _grab = box.globalToLocal(global).dy - span.start * _px;
    } else {
      _grab = 0;
    }
    setState(() => _scrollLocked = true);
    _drag.value = _Drag(id: task.id, resize: resize, day: task.dueDate!, minutes: resize ? span.end : span.start, allDay: task.dueTime == null && !resize);
    _dragTask = task;
    _dragResize = resize;
    _pointer = global;
    _edgeScroll?.cancel();
    _edgeScroll = Timer.periodic(const Duration(milliseconds: 16), (_) => _scrollNearEdge());
  }

  /// While something is held near the top or bottom of the hours, the grid scrolls by itself (faster the closer to
  /// the edge), so a task can be taken to a time that is off the screen.
  void _scrollNearEdge() {
    final task = _dragTask;
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (task == null || _drag.value == null || box == null || !box.attached || !_scroll.hasClients) return;
    const edge = 56.0;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    var speed = 0.0;
    // Above the hours is the all-day row (a place to drop), so only the top band itself scrolls upwards.
    if (_pointer.dy >= top && _pointer.dy < top + edge) speed = -(1 - (_pointer.dy - top) / edge) * 14;
    if (_pointer.dy > bottom - edge) speed = (1 - ((bottom - _pointer.dy) / edge).clamp(0.0, 1.0)) * 14;
    if (speed == 0) return;
    final to = (_scroll.offset + speed).clamp(_scroll.position.minScrollExtent, _scroll.position.maxScrollExtent).toDouble();
    if (to == _scroll.offset) return;
    _scroll.jumpTo(to);
    _update(task, _pointer, resize: _dragResize); // the block under the finger is now a different time
  }

  void _update(Task task, Offset global, {required bool resize}) {
    _pointer = global;
    final span = _spanOf(task);
    final next = _targetAt(global, task, resize: resize, startMinutes: span.start);
    if (next != null) _drag.value = next;
  }

  Future<void> _end(Task task) async {
    _edgeScroll?.cancel();
    _dragTask = null;
    final d = _drag.value;
    _drag.value = null;
    if (mounted) setState(() => _scrollLocked = false);
    if (d == null) return;
    final repo = AppScope.repoOf(context);
    final span = _spanOf(task);
    if (d.resize) {
      final duration = resizeDuration(span.start, d.minutes);
      if (duration != (task.durationMinutes ?? defaultBlockMinutes)) {
        await guarded(context, () => repo.updateTask(task.id, durationMinutes: Value(duration)));
      }
      return;
    }
    final drop = d.allDay ? dropAt(day: d.day) : dropAt(day: d.day, minutes: d.minutes);
    if (drop.date != task.dueDate || drop.time != task.dueTime) {
      await guarded(context, () => repo.updateTask(task.id, dueDate: Value(drop.date), dueTime: Value(drop.time)));
    }
  }

  void _cancel() {
    _edgeScroll?.cancel();
    _dragTask = null;
    _drag.value = null;
    if (mounted) setState(() => _scrollLocked = false);
  }

  ({int start, int end}) _spanOf(Task t) => blockSpan(minutesOf(t.dueTime) ?? 0, t.durationMinutes);

  void _addAt(String day, double dy) {
    final minutes = ((dy / _px) / snapMinutes).floor() * snapMinutes;
    final time = formatMinutes(minutes.clamp(0, minutesPerDay - snapMinutes));
    showQuickAdd(context, defaultDue: day, defaultTime: time);
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final pal = CalendarPalette.of(context);
    final today = formatDate(dateOnly(_now));
    final byDay = <String, List<Task>>{for (final d in widget.days) d: []};
    for (final t in widget.tasks) {
      if (t.dueDate != null) byDay[t.dueDate]?.add(t);
    }
    final repeatsByDay = <String, List<Task>>{for (final d in widget.days) d: []};
    for (final r in widget.repeats) {
      repeatsByDay[r.day]?.add(r.task);
    }

    return ColoredBox(
      color: pal.surface,
      child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_drag.value == null && v.abs() > 350) widget.onSwipe(v < 0 ? 1 : -1);
      },
      child: Column(children: [
        // Day headings.
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          SizedBox(width: _gutter, child: Padding(padding: const EdgeInsets.only(right: 8, bottom: 6), child: Text(zoneLabel(_now), textAlign: TextAlign.right, maxLines: 1, style: TextStyle(fontSize: 10, color: pal.text2)))),
          for (final d in widget.days) Expanded(child: _DayHead(day: d, today: today, onTap: () => widget.onPickDay(d))),
        ]),
        // Tasks with a date and no time.
        Container(
          key: _allDayKey,
          constraints: const BoxConstraints(minHeight: 28),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: pal.line))),
          child: ValueListenableBuilder<_Drag?>(
            valueListenable: _drag,
            builder: (context, drag, _) => IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SizedBox(width: _gutter),
                for (final d in widget.days)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => showQuickAdd(context, defaultDue: d),
                      child: Container(
                        decoration: BoxDecoration(
                          color: drag != null && drag.allDay && drag.day == d ? pal.blueSoft : null,
                          border: Border(left: BorderSide(color: pal.line)),
                        ),
                        padding: const EdgeInsets.fromLTRB(2, 2, 4, 4),
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          for (final t in byDay[d]!.where((t) => minutesOf(t.dueTime) == null))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: _DragSource(
                                onTap: () => openTask(context, t.id),
                                onStart: (p) => _begin(t, p, resize: false),
                                onUpdate: (p) => _update(t, p, resize: false),
                                onEnd: () => _end(t),
                                onCancel: _cancel,
                                child: _AllDayChip(task: t, dimmed: drag?.id == t.id),
                              ),
                            ),
                          for (final t in repeatsByDay[d]!.where((t) => minutesOf(t.dueTime) == null))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: GestureDetector(onTap: () => openTask(context, t.id), child: _AllDayChip(task: t, dimmed: false, repeat: true)),
                            ),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        // The hours.
        Expanded(
          child: SingleChildScrollView(
            key: _viewportKey,
            controller: _scroll,
            physics: _scrollLocked ? const NeverScrollableScrollPhysics() : null,
            child: SizedBox(
              height: 24 * timeGridHourHeight,
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: _gutter,
                  child: Stack(children: [
                    for (var h = 1; h < 24; h++)
                      Positioned(
                        top: h * timeGridHourHeight - 7,
                        right: 8,
                        child: Text(formatTime(h * 60, use24h: catalog.use24h), style: TextStyle(fontSize: 10, color: pal.text2)),
                      ),
                  ]),
                ),
                for (final d in widget.days)
                  Expanded(
                    child: _DayColumn(
                      key: _keyFor(d),
                      day: d,
                      isToday: d == today,
                      nowMinutes: _now.hour * 60 + _now.minute,
                      tasks: byDay[d]!.where((t) => minutesOf(t.dueTime) != null).toList(),
                      repeats: repeatsByDay[d]!.where((t) => minutesOf(t.dueTime) != null).toList(),
                      drag: _drag,
                      onAdd: (dy) => _addAt(d, dy),
                      onBegin: _begin,
                      onUpdate: _update,
                      onEnd: _end,
                      onCancel: _cancel,
                      spanOf: _spanOf,
                      taskOf: _task,
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ]),
      ),
    );
  }
}

class _DayHead extends StatelessWidget {
  const _DayHead({required this.day, required this.today, required this.onTap});
  final String day;
  final String today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pal = CalendarPalette.of(context);
    final date = parseIsoDate(day)!;
    final isToday = day == today;
    const names = ['', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    return LayoutBuilder(builder: (context, box) {
      // A narrow column (a phone showing three days) gets a smaller number, as Google's does.
      final roomy = box.maxWidth >= 100;
      final size = roomy ? 46.0 : 38.0;
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 6, 0, 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(names[date.weekday], style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.8, color: isToday ? pal.blue : pal.text2)),
            const SizedBox(height: 2),
            Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: isToday ? pal.blue : null),
              child: Text('${date.day}', style: TextStyle(fontSize: roomy ? 26 : 21, fontWeight: FontWeight.w400, color: isToday ? pal.onBlue : pal.text)),
            ),
          ]),
        ),
      );
    });
  }
}

class _AllDayChip extends StatelessWidget {
  const _AllDayChip({required this.task, required this.dimmed, this.repeat = false});
  final Task task;
  final bool dimmed;

  /// A later day of a repeating task: faded, with a repeat mark instead of a check.
  final bool repeat;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final c = CalendarPalette.eventColour(catalog.colorOf(task.projectId));
    final fg = CalendarPalette.onColour(c);
    return Opacity(
      opacity: dimmed ? 0.35 : (repeat ? 0.55 : 1),
      child: Container(
        height: 22,
        padding: const EdgeInsets.fromLTRB(1, 0, 6, 0),
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(4)),
        child: Row(children: [
          if (repeat) Padding(padding: const EdgeInsets.all(3), child: Icon(Icons.repeat, size: 14, color: fg)) else _MiniCheck(task: task, colour: fg),
          const SizedBox(width: 2),
          Expanded(child: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg))),
        ]),
      ),
    );
  }
}

class _MiniCheck extends StatelessWidget {
  const _MiniCheck({required this.task, required this.colour});
  final Task task;
  final Color colour;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => toggleTask(context, task),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Container(width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: colour.withValues(alpha: 0.9), width: 1.5))),
        ),
      );
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    super.key,
    required this.day,
    required this.isToday,
    required this.nowMinutes,
    required this.tasks,
    required this.repeats,
    required this.drag,
    required this.onAdd,
    required this.onBegin,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    required this.spanOf,
    required this.taskOf,
  });

  final String day;
  final bool isToday;
  final int nowMinutes;
  final List<Task> tasks;
  final List<Task> repeats;
  final ValueNotifier<_Drag?> drag;
  final ValueChanged<double> onAdd;
  final void Function(Task task, Offset global, {required bool resize}) onBegin;
  final void Function(Task task, Offset global, {required bool resize}) onUpdate;
  final Future<void> Function(Task task) onEnd;
  final VoidCallback onCancel;
  final ({int start, int end}) Function(Task) spanOf;
  final Task? Function(String id) taskOf;

  @override
  Widget build(BuildContext context) {
    final pal = CalendarPalette.of(context);
    final catalog = AppScope.of(context);
    final byId = {for (final t in tasks) t.id: t};
    final copyById = {for (final t in repeats) 'repeat:${t.id}': t};
    final placed = layoutDay([for (final t in tasks) GridItem(t.id, spanOf(t).start, spanOf(t).end), for (final e in copyById.entries) GridItem(e.key, spanOf(e.value).start, spanOf(e.value).end)]);

    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      return Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => onAdd(d.localPosition.dy),
            child: CustomPaint(painter: _GridPainter(pal.line)),
          ),
        ),
        for (final p in placed)
          Positioned(
            top: p.start * _px,
            height: (p.end - p.start) * _px - 2,
            left: width * p.column / p.columns + 2,
            width: width / p.columns - 4,
            child: copyById.containsKey(p.id)
                ? _RepeatBlock(task: copyById[p.id]!, height: (p.end - p.start) * _px, colour: CalendarPalette.eventColour(catalog.colorOf(copyById[p.id]!.projectId)))
                : _Block(
              key: ValueKey('block-${p.id}'),
              task: byId[p.id]!,
              height: (p.end - p.start) * _px,
              colour: CalendarPalette.eventColour(catalog.colorOf(byId[p.id]!.projectId)),
              drag: drag,
              onBegin: onBegin,
              onUpdate: onUpdate,
              onEnd: onEnd,
              onCancel: onCancel,
            ),
          ),
        ValueListenableBuilder<_Drag?>(
          valueListenable: drag,
          builder: (context, d, _) {
            if (d == null || d.allDay || d.day != day) return const SizedBox.shrink();
            final t = taskOf(d.id);
            if (t == null) return const SizedBox.shrink();
            final span = spanOf(t);
            final start = d.resize ? span.start : minutesOf(dropAt(day: day, minutes: d.minutes).time) ?? 0;
            final end = d.resize ? span.start + resizeDuration(span.start, d.minutes) : (start + span.end - span.start).clamp(0, minutesPerDay);
            return Positioned(
              top: start * _px,
              height: (end - start).clamp(minBlockMinutes, minutesPerDay) * _px - 2,
              left: 2,
              right: 2,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: pal.blue.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 2))],
                  ),
                  child: Text('${formatTime(start, use24h: catalog.use24h)} – ${formatTime(end.clamp(0, minutesPerDay - 1), use24h: catalog.use24h)}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: pal.onBlue)),
                ),
              ),
            );
          },
        ),
        if (isToday)
          Positioned(
            top: nowMinutes * _px,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Stack(clipBehavior: Clip.none, children: [
                Container(height: 2, color: pal.red),
                Positioned(left: -6, top: -5, child: Container(width: 12, height: 12, decoration: BoxDecoration(color: pal.red, shape: BoxShape.circle))),
              ]),
            ),
          ),
      ]);
    });
  }
}

/// A later day of a repeating task: the same block, faded, with a repeat mark; it cannot be dragged (move the task
/// itself), and a tap opens the task.
class _RepeatBlock extends StatelessWidget {
  const _RepeatBlock({required this.task, required this.height, required this.colour});
  final Task task;
  final double height;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final fg = CalendarPalette.onColour(colour);
    final span = blockSpan(minutesOf(task.dueTime) ?? 0, task.durationMinutes);
    final tight = height < 34;
    final start = formatTime(span.start, use24h: catalog.use24h);
    return Opacity(
      opacity: 0.55,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openTask(context, task.id),
        child: Container(
          padding: EdgeInsets.fromLTRB(5, tight ? 0 : 2, 6, tight ? 0 : 2),
          decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(6), border: Border.all(color: CalendarPalette.of(context).surface)),
          child: Row(crossAxisAlignment: tight ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
            Padding(padding: EdgeInsets.only(top: tight ? 0 : 2), child: Icon(Icons.repeat, size: 13, color: fg)),
            const SizedBox(width: 4),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: tight ? MainAxisAlignment.center : MainAxisAlignment.start, children: [
                Text(tight ? '${task.title}, $start' : task.title, maxLines: tight ? 1 : 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.25, color: fg)),
                if (height >= 44) Text('$start – ${formatTime(span.end.clamp(0, minutesPerDay - 1), use24h: catalog.use24h)}', style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.9))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({super.key, required this.task, required this.height, required this.colour, required this.drag, required this.onBegin, required this.onUpdate, required this.onEnd, required this.onCancel});
  final Task task;
  final double height;
  final Color colour;
  final ValueNotifier<_Drag?> drag;
  final void Function(Task task, Offset global, {required bool resize}) onBegin;
  final void Function(Task task, Offset global, {required bool resize}) onUpdate;
  final Future<void> Function(Task task) onEnd;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final span = blockSpan(minutesOf(task.dueTime) ?? 0, task.durationMinutes);
    final tight = height < 34;
    final fg = CalendarPalette.onColour(colour);
    final surface = Theme.of(context).colorScheme.surface;
    final start = formatTime(span.start, use24h: catalog.use24h);
    return ValueListenableBuilder<_Drag?>(
      valueListenable: drag,
      builder: (context, d, _) => Opacity(
        opacity: d?.id == task.id ? 0.35 : 1,
        child: Stack(children: [
          Positioned.fill(
            child: _DragSource(
              onTap: () => openTask(context, task.id),
              onStart: (p) => onBegin(task, p, resize: false),
              onUpdate: (p) => onUpdate(task, p, resize: false),
              onEnd: () => onEnd(task),
              onCancel: onCancel,
              child: Container(
                padding: EdgeInsets.fromLTRB(2, tight ? 0 : 2, 6, tight ? 0 : 2),
                decoration: BoxDecoration(
                  color: colour,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: surface),
                ),
                child: Row(crossAxisAlignment: tight ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
                  _MiniCheck(task: task, colour: fg),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: tight ? MainAxisAlignment.center : MainAxisAlignment.start, children: [
                      // A short block is one line, "Title, 12:00", as in Google Calendar.
                      if (tight)
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(text: task.title, style: const TextStyle(fontWeight: FontWeight.w500)),
                            TextSpan(text: ', $start', style: const TextStyle(fontWeight: FontWeight.w400)),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, height: 1.25, color: fg),
                        )
                      else
                        Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.25, color: fg)),
                      if (height >= 44) Text('$start – ${formatTime((span.end).clamp(0, minutesPerDay - 1), use24h: catalog.use24h)}', style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.9))),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          // The bottom edge: drag to change how long it lasts.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 14,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (d) => onBegin(task, d.globalPosition, resize: true),
              onVerticalDragUpdate: (d) => onUpdate(task, d.globalPosition, resize: true),
              onVerticalDragEnd: (_) => onEnd(task),
              onVerticalDragCancel: onCancel,
              child: MouseRegion(cursor: SystemMouseCursors.resizeUpDown, child: const SizedBox.expand()),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Thin hour lines and a line down the left of the column, nothing else (as in Google Calendar).
class _GridPainter extends CustomPainter {
  _GridPainter(this.line);
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = line..strokeWidth = 1;
    for (var h = 0; h < 24; h++) {
      final y = h * timeGridHourHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    canvas.drawLine(Offset.zero, Offset(0, size.height), paint);
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.line != line;
}
