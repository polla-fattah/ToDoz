import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/view_options.dart';
import '../data/database.dart';
import 'catalog.dart';
import 'common.dart';
import 'project_dialogs.dart';
import 'quick_add_sheet.dart';
import 'task_tree.dart';
import 'task_widgets.dart';

TreeRow _flat(Task t) => TreeRow(t, 0, hasChildren: false, collapsed: false);

/// Shows a set of tasks as a list, a board or a calendar, grouped and sorted
/// as [options] say (FR-V3, FR-V4, FR-V5, FR-V6). Used by project and filter
/// screens; it never loads data itself.
class TaskCollection extends StatelessWidget {
  const TaskCollection({
    super.key,
    required this.tasks,
    required this.options,
    required this.defaultGroup,
    this.projectId,
    this.emptyTitle = 'Nothing here',
    this.emptyBody = 'Tap + to add a task.',
  });

  final List<Task> tasks;
  final ViewOptions options;
  final Grouping defaultGroup;

  /// Set for a project view: enables sections (collapse, add, menus).
  final String? projectId;
  final String emptyTitle;
  final String emptyBody;

  Grouping get group => options.group ?? defaultGroup;

  List<Task> get visible => options.showSubtasks ? tasks : tasks.where((t) => t.parentId == null).toList();

  List<TaskGroup<Task>> groups(BuildContext context, {required bool columns}) {
    final catalog = AppScope.of(context);
    var lookups = catalog.lookups;
    if (projectId != null) {
      lookups = GroupLookups(
        projects: lookups.projects,
        labels: lookups.labels,
        sections: [for (final s in catalog.sectionsOf(projectId!)) (id: s.id, projectId: projectId!, name: s.name)],
      );
    }
    final showEmpty = columns
        ? (group == Grouping.section || group == Grouping.label)
        : (group == Grouping.section && projectId != null);
    return groupAndSort<Task>(
      visible,
      facts: catalog.facts,
      group: group,
      sort: options.sort,
      now: catalog.repo.now,
      lookups: lookups,
      showEmptyColumns: showEmpty,
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (options.layout) {
      case ViewLayout.list:
        return _ListLayout(owner: this, groups: groups(context, columns: false));
      case ViewLayout.board:
        return _BoardLayout(owner: this, groups: groups(context, columns: true));
      case ViewLayout.calendar:
        return CalendarLayout(tasks: visible, showDetails: options.showDetails);
    }
  }
}

// -----------------------------------------------------------------------------
// List
// -----------------------------------------------------------------------------

class _ListLayout extends StatelessWidget {
  const _ListLayout({required this.owner, required this.groups});
  final TaskCollection owner;
  final List<TaskGroup<Task>> groups;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final entries = <ListEntry>[];
    final isSectioned = owner.projectId != null && owner.group == Grouping.section;

    for (final g in groups) {
      final section = g.key.kind == Grouping.section ? catalog.section(g.key.value) : null;
      final hideHeader = g.key.kind == Grouping.none || (isSectioned && g.key.value == null);
      var collapsed = false;
      if (!hideHeader) {
        collapsed = section?.isCollapsed ?? false;
        entries.add(HeaderEntry(
          g.title,
          count: g.items.length,
          onTap: section == null ? null : () => repo.updateSection(section.id, isCollapsed: !section.isCollapsed),
          color: g.key == const GroupKey(Grouping.date, 'overdue') ? Theme.of(context).colorScheme.error : null,
          trailing: section == null
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  PopupMenuButton<String>(
                    onSelected: (v) => sectionMenu(context, section, v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'add', child: Text('Add task')),
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'archive', child: Text('Archive')),
                      PopupMenuItem(value: 'delete', child: Text('Delete section')),
                    ],
                  ),
                  Icon(section.isCollapsed ? Icons.chevron_right : Icons.expand_more),
                  const SizedBox(width: 4),
                ]),
        ));
      }
      if (collapsed) continue;
      final rows = owner.options.sort == SortBy.manual || owner.options.showSubtasks ? flattenTasks(g.items) : [for (final t in g.items) _flat(t)];
      for (final r in rows) {
        entries.add(TaskEntry(r, showProject: owner.group != Grouping.project && owner.projectId == null, showDetails: owner.options.showDetails));
      }
    }
    if (isSectioned) {
      entries.add(WidgetEntry(Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        child: TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add section'),
          onPressed: () async {
            final name = await promptText(context, 'New section', hint: 'Section name', action: 'Add');
            if (name != null && name.trim().isNotEmpty && context.mounted) {
              await guarded(context, () async {
                await repo.createSection(owner.projectId!, name);
              });
            }
          },
        ),
      )));
    }
    return EntryList(entries: entries, emptyTitle: owner.emptyTitle, emptyBody: owner.emptyBody);
  }
}

// -----------------------------------------------------------------------------
// Board
// -----------------------------------------------------------------------------

class _BoardLayout extends StatelessWidget {
  const _BoardLayout({required this.owner, required this.groups});
  final TaskCollection owner;
  final List<TaskGroup<Task>> groups;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final canAddSection = owner.projectId != null && owner.group == Grouping.section;
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      children: [
        for (final g in groups)
          _BoardColumn(
            group: g,
            manual: owner.options.sort == SortBy.manual,
            projectId: owner.projectId,
            showDetails: owner.options.showDetails,
            onDrop: (taskId, index) {
              final ids = g.items.map((t) => t.id).where((id) => id != taskId).toList();
              ids.insert((index ?? ids.length).clamp(0, ids.length), taskId);
              return repo.moveToGroup(taskId, g.key, orderedIdsInGroup: owner.options.sort == SortBy.manual ? ids : null);
            },
          ),
        if (canAddSection)
          SizedBox(
            width: 200,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add section'),
                onPressed: () async {
                  final name = await promptText(context, 'New section', hint: 'Section name', action: 'Add');
                  if (name != null && name.trim().isNotEmpty && context.mounted) {
                    await guarded(context, () async {
                      await repo.createSection(owner.projectId!, name);
                    });
                  }
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _BoardColumn extends StatelessWidget {
  const _BoardColumn({
    required this.group,
    required this.manual,
    required this.projectId,
    required this.showDetails,
    required this.onDrop,
  });

  final TaskGroup<Task> group;
  final bool manual;
  final String? projectId;
  final bool showDetails;

  /// Called with the dragged task id and the slot index it was dropped on (null = the end).
  final Future<void> Function(String taskId, int? index) onDrop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canDrop = group.key.acceptsDrops;
    return SizedBox(
      width: 290,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: DragTarget<String>(
          onWillAcceptWithDetails: (_) => canDrop,
          onAcceptWithDetails: (d) => onDrop(d.data, null),
          builder: (context, candidates, _) => Container(
            decoration: BoxDecoration(
              color: candidates.isNotEmpty ? cs.primaryContainer.withValues(alpha: 0.4) : cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Row(children: [
                  Expanded(child: Text(group.title.isEmpty ? 'Tasks' : group.title, style: const TextStyle(fontWeight: FontWeight.w700))),
                  Text('${group.items.length}', style: TextStyle(color: cs.outline)),
                ]),
              ),
              Expanded(
                child: ListView(padding: const EdgeInsets.fromLTRB(6, 0, 6, 6), children: [
                  for (var i = 0; i < group.items.length; i++) ...[
                    if (manual && canDrop) _Slot(onDrop: (id) => onDrop(id, i)),
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      clipBehavior: Clip.antiAlias,
                      child: TaskTile(row: _flat(group.items[i]), showProject: projectId == null, draggable: true, showDetails: showDetails),
                    ),
                  ],
                  if (manual && canDrop && group.items.isNotEmpty) _Slot(onDrop: (id) => onDrop(id, group.items.length)),
                  if (group.items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(canDrop ? 'Drop a task here' : 'Nothing overdue', style: TextStyle(color: cs.outline)),
                    ),
                ]),
              ),
              if (projectId != null && canDrop)
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add task'),
                  onPressed: () => showQuickAdd(
                    context,
                    defaultProjectId: projectId!,
                    defaultSectionId: group.key.kind == Grouping.section ? group.key.value : null,
                    defaultDue: group.key.kind == Grouping.date && group.key.value != 'overdue' ? group.key.value : null,
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A thin drop zone between cards that shows a line while a card hovers over it.
class _Slot extends StatelessWidget {
  const _Slot({required this.onDrop});
  final Future<void> Function(String taskId) onDrop;

  @override
  Widget build(BuildContext context) => DragTarget<String>(
        onAcceptWithDetails: (d) => onDrop(d.data),
        builder: (context, candidates, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: candidates.isNotEmpty ? 28 : 8,
          alignment: Alignment.center,
          child: candidates.isNotEmpty
              ? Container(height: 3, margin: const EdgeInsets.symmetric(horizontal: 4), color: Theme.of(context).colorScheme.primary)
              : null,
        ),
      );
}

// -----------------------------------------------------------------------------
// Calendar
// -----------------------------------------------------------------------------

enum CalendarMode { month, week }

/// A month grid or a week list. Drag a task onto a day to reschedule it (FR-V5).
class CalendarLayout extends StatefulWidget {
  const CalendarLayout({super.key, required this.tasks, this.showDetails = true});
  final List<Task> tasks;
  final bool showDetails;

  @override
  State<CalendarLayout> createState() => _CalendarLayoutState();
}

class _CalendarLayoutState extends State<CalendarLayout> {
  CalendarMode _mode = CalendarMode.month;
  late DateTime _selected = dateOnly(AppScope.repoOf(context).now);
  late DateTime _month = DateTime(_selected.year, _selected.month);

  static const _monthNames = ['', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  static const _dayNames = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  Map<String, List<Task>> get _byDay {
    final m = <String, List<Task>>{};
    for (final t in widget.tasks) {
      if (t.dueDate != null && t.completedAt == null) m.putIfAbsent(t.dueDate!, () => []).add(t);
    }
    for (final list in m.values) {
      list.sort((a, b) => (a.dueTime ?? '99:99').compareTo(b.dueTime ?? '99:99'));
    }
    return m;
  }

  DateTime _weekStart(DateTime d, int weekStart) => d.subtract(Duration(days: (d.weekday - weekStart + 7) % 7));

  Future<void> _drop(String taskId, DateTime day) async {
    await guarded(context, () => AppScope.repoOf(context).updateTask(taskId, dueDate: Value(formatDate(day))));
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final today = dateOnly(catalog.repo.now);
    final byDay = _byDay;
    final narrow = MediaQuery.of(context).size.width < 600;
    final unscheduled = widget.tasks.where((t) => t.dueDate == null && t.completedAt == null).toList();

    void shift(int dir) => setState(() {
          if (_mode == CalendarMode.month) {
            _month = DateTime(_month.year, _month.month + dir);
            _selected = DateTime(_month.year, _month.month, 1);
          } else {
            _selected = _selected.add(Duration(days: 7 * dir));
            _month = DateTime(_selected.year, _selected.month);
          }
        });

    final title = _mode == CalendarMode.month
        ? '${_monthNames[_month.month]} ${_month.year}'
        : '${dueLabel(formatDate(_weekStart(_selected, catalog.weekStart)), catalog.repo.now)} week';

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
        child: Row(children: [
          IconButton(tooltip: 'Previous', icon: const Icon(Icons.chevron_left), onPressed: () => shift(-1)),
          Expanded(child: Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
          IconButton(tooltip: 'Next', icon: const Icon(Icons.chevron_right), onPressed: () => shift(1)),
          TextButton(
            onPressed: () => setState(() {
              _selected = today;
              _month = DateTime(today.year, today.month);
            }),
            child: const Text('Today'),
          ),
          SegmentedButton<CalendarMode>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [ButtonSegment(value: CalendarMode.month, label: Text('Month')), ButtonSegment(value: CalendarMode.week, label: Text('Week'))],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
        ]),
      ),
      if (_mode == CalendarMode.month) ...[
        _weekdayHeader(catalog.weekStart, cs),
        _monthGrid(context, catalog, byDay, today, narrow),
        const Divider(height: 1),
        Expanded(child: _agenda(context, byDay[formatDate(_selected)] ?? const [], unscheduled)),
      ] else
        Expanded(child: _weekList(context, catalog, byDay, today, unscheduled)),
    ]);
  }

  Widget _weekdayHeader(int weekStart, ColorScheme cs) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Center(child: Text(_dayNames[(weekStart - 1 + i) % 7 + 1], style: TextStyle(color: cs.outline, fontSize: 12))),
            ),
        ]),
      );

  Widget _monthGrid(BuildContext context, Catalog catalog, Map<String, List<Task>> byDay, DateTime today, bool narrow) {
    final cs = Theme.of(context).colorScheme;
    final first = _weekStart(_month, catalog.weekStart);
    final cellHeight = narrow ? 52.0 : 92.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(children: [
        for (var week = 0; week < 6; week++)
          SizedBox(
            height: cellHeight,
            child: Row(children: [
              for (var dow = 0; dow < 7; dow++)
                Expanded(child: _dayCell(context, first.add(Duration(days: week * 7 + dow)), byDay, today, narrow, cs)),
            ]),
          ),
      ]),
    );
  }

  Widget _dayCell(BuildContext context, DateTime day, Map<String, List<Task>> byDay, DateTime today, bool narrow, ColorScheme cs) {
    final inMonth = day.month == _month.month;
    final isToday = day == today;
    final isSelected = day == _selected;
    final tasks = byDay[formatDate(day)] ?? const <Task>[];
    final shown = narrow ? 0 : 2;
    return DragTarget<String>(
      onAcceptWithDetails: (d) => _drop(d.data, day),
      builder: (context, candidates, _) => InkWell(
        onTap: () => setState(() => _selected = day),
        child: Container(
          margin: const EdgeInsets.all(1),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: candidates.isNotEmpty ? cs.primaryContainer : (isSelected ? cs.primaryContainer.withValues(alpha: 0.4) : null),
            border: Border.all(color: isToday ? cs.primary : cs.outlineVariant.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${day.day}',
                style: TextStyle(fontSize: 12, fontWeight: isToday ? FontWeight.w800 : FontWeight.w500, color: inMonth ? null : cs.outline.withValues(alpha: 0.5))),
            if (narrow && tasks.isNotEmpty)
              Wrap(spacing: 2, runSpacing: 2, children: [
                for (final t in tasks.take(4)) Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: priorityColor(t.priority, cs))),
              ]),
            if (!narrow)
              for (final t in tasks.take(shown))
                _CalendarChip(task: t),
            if (!narrow && tasks.length > shown)
              Text('+${tasks.length - shown} more', style: TextStyle(fontSize: 10, color: cs.outline)),
          ]),
        ),
      ),
    );
  }

  Widget _agenda(BuildContext context, List<Task> tasks, List<Task> unscheduled) {
    final catalog = AppScope.of(context);
    final now = catalog.repo.now;
    return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(dayHeading(formatDate(_selected), now), style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      if (tasks.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Text('No tasks this day. Drag one here to schedule it.')),
      for (final t in tasks) TaskTile(row: _flat(t), draggable: true, showDetails: widget.showDetails),
      if (unscheduled.isNotEmpty) _unscheduledTray(context, unscheduled),
    ]);
  }

  Widget _unscheduledTray(BuildContext context, List<Task> unscheduled) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('No date (${unscheduled.length}) · drag onto a day', style: TextStyle(color: cs.outline, fontSize: 12)),
      ),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final t in unscheduled.take(30))
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: LongPressDraggable<String>(
                data: t.id,
                feedback: Material(elevation: 6, child: Padding(padding: const EdgeInsets.all(10), child: Text(t.title))),
                child: ActionChip(label: Text(t.title, overflow: TextOverflow.ellipsis), onPressed: () => openTask(context, t.id)),
              ),
            ),
        ]),
      ),
    ]);
  }

  Widget _weekList(BuildContext context, Catalog catalog, Map<String, List<Task>> byDay, DateTime today, List<Task> unscheduled) {
    final cs = Theme.of(context).colorScheme;
    final start = _weekStart(_selected, catalog.weekStart);
    final now = catalog.repo.now;
    return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
      for (var i = 0; i < 7; i++)
        Builder(builder: (context) {
          final day = start.add(Duration(days: i));
          final tasks = byDay[formatDate(day)] ?? const <Task>[];
          return DragTarget<String>(
            onAcceptWithDetails: (d) => _drop(d.data, day),
            builder: (context, candidates, _) => Container(
              color: candidates.isNotEmpty ? cs.primaryContainer.withValues(alpha: 0.5) : null,
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(dayHeading(formatDate(day), now),
                      style: TextStyle(fontWeight: FontWeight.w700, color: day == today ? cs.primary : null)),
                ),
                if (tasks.isEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Free', style: TextStyle(color: cs.outline))),
                for (final t in tasks) TaskTile(row: _flat(t), draggable: true, showDetails: widget.showDetails),
              ]),
            ),
          );
        }),
      if (unscheduled.isNotEmpty) _unscheduledTray(context, unscheduled),
    ]);
  }
}

class _CalendarChip extends StatelessWidget {
  const _CalendarChip({required this.task});
  final Task task;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = priorityColor(task.priority, cs);
    return LongPressDraggable<String>(
      data: task.id,
      feedback: Material(elevation: 6, child: Padding(padding: const EdgeInsets.all(8), child: Text(task.title))),
      child: GestureDetector(
        onTap: () => openTask(context, task.id),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.15), border: Border(left: BorderSide(color: c, width: 3))),
          child: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// View options
// -----------------------------------------------------------------------------

/// The tune button for an app bar: opens the layout, grouping and sorting sheet.
Widget viewOptionsButton(BuildContext context, ViewOptions options, ValueChanged<ViewOptions> onChanged, {required bool isProject, required Grouping defaultGroup}) {
  return IconButton(
    tooltip: 'View options',
    icon: const Icon(Icons.tune),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ViewOptionsSheet(initial: options, onChanged: onChanged, isProject: isProject, defaultGroup: defaultGroup),
    ),
  );
}

class _ViewOptionsSheet extends StatefulWidget {
  const _ViewOptionsSheet({required this.initial, required this.onChanged, required this.isProject, required this.defaultGroup});
  final ViewOptions initial;
  final ValueChanged<ViewOptions> onChanged;
  final bool isProject;
  final Grouping defaultGroup;

  @override
  State<_ViewOptionsSheet> createState() => _ViewOptionsSheetState();
}

class _ViewOptionsSheetState extends State<_ViewOptionsSheet> {
  late ViewOptions o = widget.initial;

  void _set(ViewOptions next) {
    setState(() => o = next);
    widget.onChanged(next);
  }

  static const _groupNames = {
    Grouping.none: 'None', Grouping.section: 'Section', Grouping.date: 'Due date',
    Grouping.priority: 'Priority', Grouping.label: 'Label', Grouping.project: 'Project',
  };
  static const _sortNames = {
    SortBy.manual: 'Manual', SortBy.name: 'Name', SortBy.date: 'Due date', SortBy.priority: 'Priority', SortBy.added: 'Date added',
  };

  @override
  Widget build(BuildContext context) {
    final groups = widget.isProject
        ? [Grouping.section, Grouping.none, Grouping.date, Grouping.priority, Grouping.label]
        : [Grouping.none, Grouping.project, Grouping.section, Grouping.date, Grouping.priority, Grouping.label];
    final effective = o.group ?? widget.defaultGroup;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('View', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ViewLayout>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ViewLayout.list, icon: Icon(Icons.view_list_outlined), label: Text('List')),
              ButtonSegment(value: ViewLayout.board, icon: Icon(Icons.view_kanban_outlined), label: Text('Board')),
              ButtonSegment(value: ViewLayout.calendar, icon: Icon(Icons.calendar_month_outlined), label: Text('Calendar')),
            ],
            selected: {o.layout},
            onSelectionChanged: (s) => _set(o.copyWith(layout: s.first)),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<Grouping>(
            initialValue: effective,
            decoration: const InputDecoration(labelText: 'Group by'),
            items: [for (final g in groups) DropdownMenuItem(value: g, child: Text(_groupNames[g]!))],
            onChanged: (g) => g == null ? null : _set(o.copyWith(group: g)),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<SortBy>(
            initialValue: o.sort,
            decoration: const InputDecoration(labelText: 'Sort by'),
            items: [for (final s in SortBy.values) DropdownMenuItem(value: s, child: Text(_sortNames[s]!))],
            onChanged: (s) => s == null ? null : _set(o.copyWith(sort: s)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show completed tasks'),
            value: o.showCompleted,
            onChanged: (v) => _set(o.copyWith(showCompleted: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show sub-tasks'),
            value: o.showSubtasks,
            onChanged: (v) => _set(o.copyWith(showSubtasks: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show task details'),
            value: o.showDetails,
            onChanged: (v) => _set(o.copyWith(showDetails: v)),
          ),
        ]),
      ),
    );
  }
}
