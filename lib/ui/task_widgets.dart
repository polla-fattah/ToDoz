import 'package:flutter/material.dart';

import 'package:taskflow_core/date_parser.dart' show formatDuration;
import 'package:taskflow_core/reminder.dart' show isOverdue;
import '../data/database.dart';
import 'catalog.dart';
import 'common.dart';
import 'drag_scroll.dart';
import 'selection.dart';
import 'task_detail.dart';
import 'task_tree.dart';

/// Completes or reopens [task], asking about sub-tasks first (FR-T3) and
/// offering Undo (FR-T8). A repeating task does not complete: it moves to its
/// next date (FR-R7).
Future<void> toggleTask(BuildContext context, Task task) async {
  final repo = AppScope.repoOf(context);
  final done = task.completedAt != null;
  if (done) {
    await repo.reopenTask(task.id);
    if (context.mounted) showUndo(context, 'Task reopened', () => repo.completeTask(task.id));
    return;
  }
  var withSubtasks = false;
  final repeating = task.recurrence != null && task.dueDate != null;
  final open = repeating ? const <Task>[] : await repo.openDescendants(task.id);
  if (open.isNotEmpty && context.mounted) {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Complete sub-tasks too?'),
        content: Text('"${task.title}" has ${open.length} open sub-task${open.length == 1 ? '' : 's'}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'only'), child: const Text('Only this task')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'all'), child: const Text('Complete all')),
        ],
      ),
    );
    if (choice == null) return;
    withSubtasks = choice == 'all';
  }
  final outcome = await repo.completeTask(task.id, withSubtasks: withSubtasks);
  if (!context.mounted) return;
  final use24h = AppScope.of(context).use24h;
  final message = outcome.wasRescheduled
      ? 'Done. Next: ${dueText(outcome.nextDueDate!, (await repo.getTask(task.id))?.dueTime, repo.now, use24h: use24h)}'
      : 'Task completed';
  if (!context.mounted) return;
  showUndo(context, message, () => repo.undoCompletion(outcome));

  // Completing the last open sub-task offers to complete the parent.
  final parentId = task.parentId;
  if (parentId != null && !outcome.wasRescheduled) {
    final parent = await repo.getTask(parentId);
    if (parent != null && parent.completedAt == null && (await repo.openDescendants(parentId)).isEmpty) {
      if (!context.mounted) return;
      final yes = await confirm(context, 'All sub-tasks are done', 'Complete "${parent.title}" too?', action: 'Complete');
      if (yes) await repo.completeTask(parentId);
    }
  }
}

class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.row,
    this.showProject = true,
    this.onTap,
    this.draggable = false,
    this.dragHandle = false,
    this.showDetails = true,
  });

  final TreeRow row;
  final bool showProject;

  /// Whether to show the description line under the title.
  final bool showDetails;
  final VoidCallback? onTap;

  /// Long-press picks the task up to drop on a day or column (Upcoming, calendar).
  /// Otherwise long-press starts a multi-selection.
  final bool draggable;

  /// Show a grip at the end of the row: drag it to move the task to another section or to reorder it.
  /// (Long-press stays for selecting several tasks.)
  final bool dragHandle;

  Task get task => row.task;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final done = task.completedAt != null;
    final labels = catalog.labelsFor(task.id);
    final counts = catalog.subtaskCounts[task.id];
    final now = repo.now;
    final overdue = !done && isOverdue(dueDate: task.dueDate, dueTime: task.dueTime, now: now);
    final dueToday = !done && !overdue && task.dueDate == _iso(now);
    final pColor = priorityColor(task.priority, cs);

    final meta = <Widget>[
      if (task.dueDate != null)
        _meta(
          context,
          task.recurrence != null ? Icons.repeat : Icons.event_outlined,
          dueText(task.dueDate!, task.dueTime, now, use24h: catalog.use24h),
          color: overdue ? cs.error : (dueToday ? const Color(0xFF058527) : null),
        ),
      if (task.deadline != null)
        _meta(
          context,
          Icons.flag_circle_outlined,
          'Deadline ${dueLabel(task.deadline!, now)}',
          color: !done && task.deadline!.compareTo(_iso(now)) < 0 ? cs.error : null,
        ),
      if (task.durationMinutes != null) _meta(context, Icons.timer_outlined, formatDuration(task.durationMinutes!)),
      if (counts != null) _meta(context, Icons.account_tree_outlined, '${counts.$1}/${counts.$2}'),
      if (task.assigneeId != null && catalog.isShared(task.projectId))
        _meta(context, Icons.person_outline, catalog.displayName(task.assigneeId), color: task.assigneeId == catalog.me ? cs.primary : null),
      for (final l in labels) _meta(context, Icons.sell_outlined, l.name, color: Color(l.color)),
      if (showProject)
        _meta(
          context,
          Icons.circle,
          catalog.project(task.projectId)?.name ?? '',
          color: catalog.colorOf(task.projectId),
          iconSize: 9,
        ),
    ];

    final selection = SelectionScope.maybeOf(context);
    final selected = selection?.contains(task.id) ?? false;
    final selecting = selection?.active ?? false;
    final tile = Material(
      color: selected ? cs.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
      child: InkWell(
      onTap: selecting ? () => selection!.toggle(task.id) : (onTap ?? () => openTask(context, task.id)),
      onLongPress: selection != null && !draggable ? () => selection.toggle(task.id) : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8 + row.depth * 24.0, 2, 8, 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (row.hasChildren)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: row.collapsed ? 'Expand sub-tasks' : 'Collapse sub-tasks',
              icon: Icon(row.collapsed ? Icons.chevron_right : Icons.expand_more, size: 20),
              onPressed: () => repo.setTaskCollapsed(task.id, !row.collapsed),
            )
          else
            const SizedBox(width: 8),
          Semantics(
            label: done ? 'Reopen task' : 'Complete task, priority ${task.priority}',
            button: true,
            child: InkResponse(
              onTap: () => toggleTask(context, task),
              radius: 26,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? pColor : pColor.withValues(alpha: task.priority == 4 ? 0 : 0.12),
                    border: Border.all(color: pColor, width: 2),
                  ),
                  child: done
                      ? const Icon(Icons.check, size: 15, color: Colors.white)
                      : (task.priority < 4
                          ? Center(child: Text('${task.priority}', style: TextStyle(fontSize: 11, color: pColor, fontWeight: FontWeight.w700)))
                          : null),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  task.title,
                  style: text.bodyLarge?.copyWith(
                    decoration: done ? TextDecoration.lineThrough : null,
                    color: done ? cs.outline : null,
                  ),
                ),
                if (showDetails && task.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(task.description.split('\n').first,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: cs.outline)),
                  ),
                if (meta.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 12, runSpacing: 2, children: meta)),
              ]),
            ),
          ),
          if (dragHandle && !selecting)
            Draggable<String>(
              data: task.id,
              feedback: _feedback(),
              onDragStarted: () => TaskDrag.active.value = true,
              onDragEnd: (_) => TaskDrag.active.value = false,
              child: Semantics(
                label: 'Drag to move or reorder',
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 18, 10), // clear of the phone's edge-swipe "back" zone
                  child: Icon(Icons.drag_indicator, size: 22, color: cs.outline),
                ),
              ),
            ),
        ]),
      ),
    ));
    if (!draggable || selecting) return tile;
    return LongPressDraggable<String>(
      data: task.id,
      feedback: _feedback(),
      onDragStarted: () => TaskDrag.active.value = true,
      onDragEnd: (_) => TaskDrag.active.value = false,
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }

  Widget _feedback() => Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Padding(padding: const EdgeInsets.all(12), child: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis)),
        ),
      );

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Widget _meta(BuildContext context, IconData icon, String label, {Color? color, double iconSize = 13}) {
    final c = color ?? Theme.of(context).colorScheme.outline;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: iconSize, color: c),
      const SizedBox(width: 4),
      Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c)),
    ]);
  }
}

void openTask(BuildContext context, String taskId) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TaskDetailPage(taskId: taskId)));
}

/// One entry in a scrolling task screen: a heading, a task, or free-form content.
sealed class ListEntry {
  const ListEntry();
}

class HeaderEntry extends ListEntry {
  const HeaderEntry(this.title, {this.count, this.trailing, this.onTap, this.color, this.zone, this.dropBefore});
  final String title;
  final int? count;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? color;

  /// What a task dropped on this heading joins (a section, a day...); it goes to the top, before [dropBefore].
  final Object? zone;
  final String? dropBefore;
}

class TaskEntry extends ListEntry {
  const TaskEntry(this.row, {this.showProject = true, this.showDetails = true, this.zone});
  final TreeRow row;
  final bool showProject;
  final bool showDetails;

  /// The group this row belongs to; set to let tasks be dropped before it.
  final Object? zone;
}

/// The end of a group: a task dropped here goes last in [zone].
class SlotEntry extends ListEntry {
  const SlotEntry(this.zone);
  final Object zone;
}

/// Called when a task is dropped in a list: [zone] is what the drop target stood for, and the task goes
/// before [beforeTaskId] (or last when that is null).
typedef TaskDropHandler = Future<void> Function(String taskId, Object zone, String? beforeTaskId);

class WidgetEntry extends ListEntry {
  const WidgetEntry(this.child);
  final Widget child;
}

class EntryList extends StatefulWidget {
  const EntryList({
    super.key,
    required this.entries,
    this.emptyTitle = 'Nothing here',
    this.emptyBody = 'Tap + to add a task.',
    this.draggable = false,
    this.onDropTask,
  });
  final List<ListEntry> entries;

  /// Make task rows long-press draggable (Upcoming) instead of selectable.
  final bool draggable;

  /// When set, rows that carry a zone get a drag handle and headings, rows and group ends accept drops.
  final TaskDropHandler? onDropTask;
  final String emptyTitle;
  final String emptyBody;

  @override
  State<EntryList> createState() => _EntryListState();
}

class _EntryListState extends State<EntryList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _dropLine(BuildContext context) => Container(height: 3, margin: const EdgeInsets.symmetric(horizontal: 12), color: Theme.of(context).colorScheme.primary);

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final onDrop = widget.onDropTask;
    final hasTasks = entries.any((e) => e is TaskEntry);
    if (!hasTasks && entries.every((e) => e is! WidgetEntry && e is! HeaderEntry)) {
      return _Empty(title: widget.emptyTitle, body: widget.emptyBody);
    }
    return DragEdgeScroll(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: entries.length + (hasTasks ? 0 : 1),
        itemBuilder: (context, i) {
          if (i >= entries.length) return _Empty(title: widget.emptyTitle, body: widget.emptyBody);
          final e = entries[i];
          switch (e) {
            case HeaderEntry():
              final cs = Theme.of(context).colorScheme;
              final header = Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                child: Column(children: [
                  InkWell(
                    onTap: e.onTap,
                    child: Row(children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text.rich(TextSpan(children: [
                            TextSpan(text: e.title, style: TextStyle(fontWeight: FontWeight.w700, color: e.color)),
                            if (e.count != null) TextSpan(text: '  ${e.count}', style: TextStyle(color: cs.outline)),
                          ])),
                        ),
                      ),
                      ?e.trailing,
                    ]),
                  ),
                  const Divider(height: 1),
                ]),
              );
              if (onDrop == null || e.zone == null) return header;
              return DragTarget<String>(
                onAcceptWithDetails: (d) => onDrop(d.data, e.zone!, e.dropBefore),
                builder: (context, candidates, _) => Container(
                  color: candidates.isNotEmpty ? cs.primaryContainer.withValues(alpha: 0.4) : null,
                  child: header,
                ),
              );
            case TaskEntry():
              final canDrop = onDrop != null && e.zone != null && e.row.depth == 0;
              final tile = TaskTile(row: e.row, showProject: e.showProject, showDetails: e.showDetails, draggable: widget.draggable, dragHandle: canDrop);
              if (!canDrop) return tile;
              return DragTarget<String>(
                onWillAcceptWithDetails: (d) => d.data != e.row.task.id,
                onAcceptWithDetails: (d) => onDrop(d.data, e.zone!, e.row.task.id),
                builder: (context, candidates, _) => Column(children: [if (candidates.isNotEmpty) _dropLine(context), tile]),
              );
            case SlotEntry():
              if (onDrop == null) return const SizedBox.shrink();
              return DragTarget<String>(
                onAcceptWithDetails: (d) => onDrop(d.data, e.zone, null),
                builder: (context, candidates, _) => SizedBox(
                  height: 28,
                  child: candidates.isNotEmpty ? Align(alignment: Alignment.topCenter, child: _dropLine(context)) : null,
                ),
              );
            case WidgetEntry():
              return e.child;
          }
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_circle_outline, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(body, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ]),
        ),
      );
}
