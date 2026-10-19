import 'package:flutter/material.dart';

import 'package:taskflow_core/view_options.dart';
import '../data/database.dart';
import 'calendar_view.dart';
import 'catalog.dart';
import 'common.dart';
import 'drag_scroll.dart';
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
        return CalendarView(tasks: [for (final t in visible) if (t.dueDate != null && t.completedAt == null) t]);
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
    final manual = owner.options.sort == SortBy.manual;
    // The top-level tasks of each group in the order shown: what a drop is placed among.
    final order = <GroupKey, List<String>>{};

    for (final g in groups) {
      final section = g.key.kind == Grouping.section ? catalog.section(g.key.value) : null;
      final hideHeader = g.key.kind == Grouping.none || (isSectioned && g.key.value == null);
      final rows = manual || owner.options.showSubtasks ? flattenTasks(g.items) : [for (final t in g.items) _flat(t)];
      final top = [for (final r in rows) if (r.depth == 0) r.task.id];
      order[g.key] = top;
      final zone = g.key.acceptsDrops ? g.key : null;
      var collapsed = false;
      if (!hideHeader) {
        collapsed = section?.isCollapsed ?? false;
        entries.add(HeaderEntry(
          g.title,
          count: g.items.length,
          zone: zone,
          dropBefore: top.isEmpty ? null : top.first,
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
      for (final r in rows) {
        entries.add(TaskEntry(r, showProject: owner.group != Grouping.project && owner.projectId == null, showDetails: owner.options.showDetails, zone: zone));
      }
      if (zone != null) entries.add(SlotEntry(zone));
    }

    // Dropping a task: it takes the value of the group it lands in (its section, day, priority...) and,
    // when the list is in manual order, its place among that group's tasks.
    Future<void> drop(String taskId, Object zone, String? beforeId) async {
      final key = zone as GroupKey;
      final already = groups.any((g) => g.key == key && g.items.any((t) => t.id == taskId));
      if (already && !manual) {
        showMessage(context, 'This list is sorted automatically. Choose Manual in View options to put tasks in your own order.');
        return;
      }
      final ids = [...?order[key]]..remove(taskId);
      final at = beforeId == null ? ids.length : ids.indexOf(beforeId);
      ids.insert(at < 0 ? ids.length : at, taskId);
      await guarded(context, () => repo.moveToGroup(taskId, key, orderedIdsInGroup: manual ? ids : null));
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
    return EntryList(entries: entries, emptyTitle: owner.emptyTitle, emptyBody: owner.emptyBody, onDropTask: drop);
  }
}

// -----------------------------------------------------------------------------
// Board
// -----------------------------------------------------------------------------

class _BoardLayout extends StatefulWidget {
  const _BoardLayout({required this.owner, required this.groups});
  final TaskCollection owner;
  final List<TaskGroup<Task>> groups;

  @override
  State<_BoardLayout> createState() => _BoardLayoutState();
}

class _BoardLayoutState extends State<_BoardLayout> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  TaskCollection get owner => widget.owner;
  List<TaskGroup<Task>> get groups => widget.groups;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final canAddSection = owner.projectId != null && owner.group == Grouping.section;
    // Columns are wider than a phone: drag a card to the screen edge to bring the next column into view.
    return DragEdgeScroll(
      controller: _scroll,
      axis: Axis.horizontal,
      child: ListView(
      controller: _scroll,
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
    ));
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
