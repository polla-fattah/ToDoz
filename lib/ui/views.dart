import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import '../core/backup.dart' show inboxId;
import '../core/date_parser.dart';
import '../core/filter.dart';
import '../core/reminder.dart' show isOverdue;
import '../core/view_options.dart';
import '../data/database.dart';
import '../data/repository.dart';
import 'catalog.dart';
import 'collection.dart';
import 'common.dart';
import 'filter_editor.dart';
import 'project_dialogs.dart';
import 'quick_add_sheet.dart';
import 'selection.dart';
import 'task_tree.dart';
import 'task_widgets.dart';

/// Page frame shared by every task screen: title, optional actions, the
/// add button that opens Quick Add with this screen's defaults, and
/// multi-selection (long-press a task, FR-T7).
class Screen extends StatefulWidget {
  const Screen({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.addProjectId,
    this.addSectionId,
    this.addDue,
    this.showAdd = true,
    this.automaticallyImplyLeading = true,
    this.subtitle,
    this.selectable = true,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;
  final String? addProjectId;
  final String? addSectionId;
  final String? addDue;
  final bool showAdd;
  final bool automaticallyImplyLeading;
  final bool selectable;

  @override
  State<Screen> createState() => _ScreenState();
}

class _ScreenState extends State<Screen> {
  final Selection _selection = Selection();

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionScope(
        selection: _selection,
        child: ListenableBuilder(
          listenable: _selection,
          builder: (context, _) {
            final selecting = widget.selectable && _selection.active;
            return PopScope(
              canPop: !selecting,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _selection.clear();
              },
              child: Scaffold(
                appBar: selecting
                    ? AppBar(
                        leading: IconButton(tooltip: 'Cancel selection', icon: const Icon(Icons.close), onPressed: _selection.clear),
                        title: Text('${_selection.ids.length} selected'),
                        actions: selectionActions(context, _selection),
                      )
                    : AppBar(
                        automaticallyImplyLeading: widget.automaticallyImplyLeading,
                        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(widget.title),
                          if (widget.subtitle != null) Text(widget.subtitle!, style: Theme.of(context).textTheme.bodySmall),
                        ]),
                        actions: [
                          if (!widget.automaticallyImplyLeading && widget.showAdd)
                            IconButton(
                              tooltip: 'Search',
                              icon: const Icon(Icons.search),
                              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
                            ),
                          ...widget.actions,
                        ],
                      ),
                body: widget.body,
                floatingActionButton: widget.showAdd && !selecting
                    ? FloatingActionButton(
                        heroTag: null, // every tab has its own button; shared hero tags clash on navigation
                        tooltip: 'Add task',
                        onPressed: () => showQuickAdd(
                          context,
                          defaultProjectId: widget.addProjectId ?? inboxId,
                          defaultSectionId: widget.addSectionId,
                          defaultDue: widget.addDue,
                        ),
                        child: const Icon(Icons.add),
                      )
                    : null,
              ),
            );
          },
        ),
      );
}

TreeRow flatRow(Task t) => TreeRow(t, 0, hasChildren: false, collapsed: false);

// -----------------------------------------------------------------------------
// Project and Inbox
// -----------------------------------------------------------------------------

class ProjectScreen extends StatelessWidget {
  const ProjectScreen({super.key, required this.projectId, this.isTab = false});
  final String projectId;
  final bool isTab;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final project = catalog.project(projectId);
    final isInbox = projectId == inboxId;
    final options = catalog.projectViewOptions(projectId);
    final defaultGroup = isInbox ? Grouping.none : Grouping.section;
    return Screen(
      title: project?.name ?? 'Project',
      automaticallyImplyLeading: !isTab,
      addProjectId: projectId,
      actions: [
        viewOptionsButton(
          context, options, (o) => repo.setProjectViewOptions(projectId, o),
          isProject: true, defaultGroup: defaultGroup,
        ),
        if (!isInbox && project != null)
          IconButton(
            tooltip: project.isFavorite ? 'Remove from favorites' : 'Add to favorites',
            icon: Icon(project.isFavorite ? Icons.favorite : Icons.favorite_border),
            onPressed: () => repo.updateProject(projectId, isFavorite: !project.isFavorite),
          ),
        if (!isInbox)
          PopupMenuButton<String>(
            onSelected: (v) => projectMenu(context, projectId, v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit project')),
              PopupMenuItem(value: 'section', child: Text('Add section')),
              PopupMenuItem(value: 'notes', child: Text('Project notes')),
              PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
              PopupMenuItem(value: 'archive', child: Text('Archive')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
      ],
      body: Live<List<Task>>(
        id: '$projectId|${options.showCompleted}',
        create: () => repo.watchProjectTasks(projectId, includeCompleted: options.showCompleted),
        builder: (context, data) => TaskCollection(
          tasks: data ?? const <Task>[],
          options: options,
          defaultGroup: defaultGroup,
          projectId: projectId,
          emptyTitle: isInbox ? 'Inbox is empty' : 'No tasks yet',
          emptyBody: isInbox ? 'Anything you add without a project lands here.' : 'Tap + to add the first task.',
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Saved filter (FR-F1)
// -----------------------------------------------------------------------------

class FilterScreen extends StatelessWidget {
  const FilterScreen({super.key, required this.filterId});
  final String filterId;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final filter = catalog.filter(filterId);
    if (filter == null) {
      return Screen(title: 'Filter', showAdd: false, body: const Center(child: Text('This filter no longer exists.')));
    }
    final options = ViewOptions.decode(filter.viewOptions);
    final defaultGroup = options.layout == ViewLayout.board ? Grouping.priority : Grouping.none;

    CompiledFilter? compiled;
    String? error;
    try {
      compiled = parseFilter(filter.query, catalog.filterEnv);
    } on FilterException catch (e) {
      error = e.message;
    }

    return Screen(
      title: filter.name,
      subtitle: filter.query,
      actions: [
        viewOptionsButton(
          context, options, (o) => repo.updateFilter(filterId, viewOptions: o),
          isProject: false, defaultGroup: defaultGroup,
        ),
        IconButton(
          tooltip: filter.isFavorite ? 'Remove from favorites' : 'Add to favorites',
          icon: Icon(filter.isFavorite ? Icons.favorite : Icons.favorite_border),
          onPressed: () => repo.updateFilter(filterId, isFavorite: !filter.isFavorite),
        ),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'edit') {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FilterEditorPage(filterId: filterId)));
            } else if (v == 'delete') {
              await repo.deleteFilter(filterId);
              if (context.mounted) {
                Navigator.of(context).pop();
                showUndo(context, 'Filter deleted', () => repo.restoreFilter(filterId));
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit filter')),
            PopupMenuItem(value: 'delete', child: Text('Delete filter')),
          ],
        ),
      ],
      body: error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.error_outline, size: 40, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 8),
                  Text(error, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FilterEditorPage(filterId: filterId))),
                    child: const Text('Edit the filter'),
                  ),
                ]),
              ),
            )
          : Live<List<Task>>(
              create: repo.watchAllOpen,
              builder: (context, data) {
                final all = data ?? const <Task>[];
                final c = compiled!;
                if (c.isSingle) {
                  final hits = all.where((t) => c.branches.first.matches(catalog.filterTask(t))).toList();
                  return TaskCollection(
                    tasks: hits,
                    options: options,
                    defaultGroup: defaultGroup,
                    emptyTitle: 'Nothing matches',
                    emptyBody: 'No open task fits "${filter.query}".',
                  );
                }
                // Several comma-separated lists: each gets its own heading.
                final entries = <ListEntry>[];
                for (final b in c.branches) {
                  final hits = all.where((t) => b.matches(catalog.filterTask(t))).toList();
                  entries.add(HeaderEntry(b.text, count: hits.length));
                  for (final r in flattenTasks(hits)) {
                    entries.add(TaskEntry(r));
                  }
                }
                return EntryList(entries: entries, emptyTitle: 'Nothing matches', emptyBody: 'No open task fits this filter.');
              },
            ),
    );
  }
}

// -----------------------------------------------------------------------------
// Today
// -----------------------------------------------------------------------------

HeaderEntry overdueEntry(BuildContext context, List<Task> overdue, String today) {
  final repo = AppScope.repoOf(context);
  return HeaderEntry(
    'Overdue',
    count: overdue.length,
    color: Theme.of(context).colorScheme.error,
    trailing: TextButton(
      child: const Text('Reschedule'),
      onPressed: () async {
        final now = repo.now;
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Reschedule overdue tasks'),
            children: [
              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'today'), child: const Text('To today')),
              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'tomorrow'), child: const Text('To tomorrow')),
              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'pick'), child: const Text('Pick a date…')),
            ],
          ),
        );
        if (choice == null || !context.mounted) return;
        String? target;
        if (choice == 'today') target = formatDate(dateOnly(now));
        if (choice == 'tomorrow') target = formatDate(dateOnly(now).add(const Duration(days: 1)));
        if (choice == 'pick') {
          final d = await showDatePicker(
            context: context,
            initialDate: dateOnly(now),
            firstDate: dateOnly(now),
            lastDate: DateTime(now.year + 10),
          );
          if (d != null) target = formatDate(d);
        }
        if (target == null) return;
        final ids = overdue.map((t) => t.id).toList();
        final before = {for (final t in overdue) t.id: t.dueDate};
        await repo.rescheduleTasks(ids, target);
        if (context.mounted) {
          showUndo(context, 'Rescheduled ${ids.length} task${ids.length == 1 ? '' : 's'}', () => repo.setDueDates(before));
        }
      },
    ),
  );
}

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final now = repo.now;
    final today = formatDate(dateOnly(now));
    const wd = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const mo = ['', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return Screen(
      title: 'Today',
      subtitle: '${wd[now.weekday]}, ${now.day} ${mo[now.month]}',
      automaticallyImplyLeading: false,
      addDue: today,
      body: Live<List<Task>>(
        id: today,
        create: () => repo.watchToday(today),
        builder: (context, data) {
          final tasks = data ?? const <Task>[];
          // FR-D6: a task due today with a time is overdue once that time has passed.
          bool late(Task t) => isOverdue(dueDate: t.dueDate, dueTime: t.dueTime, now: repo.now);
          final overdue = tasks.where(late).toList();
          final due = tasks.where((t) => !late(t) && t.dueDate == today).toList();
          final entries = <ListEntry>[
            WidgetEntry(_GoalCard(goal: catalog.dailyGoal)),
            if (overdue.isNotEmpty) overdueEntry(context, overdue, today),
            for (final t in overdue) TaskEntry(flatRow(t)),
            if (due.isNotEmpty || overdue.isNotEmpty) HeaderEntry('Today', count: due.length),
            for (final t in due) TaskEntry(flatRow(t)),
          ];
          return EntryList(
            entries: entries,
            emptyTitle: 'A little breathing room',
            emptyBody: 'Nothing is due today. Tap + to add a task.',
          );
        },
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal});
  final int goal;

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.repoOf(context);
    return Live<int>(
      id: formatDate(dateOnly(repo.now)),
      create: () => repo.watchCompletedOn(repo.now),
      builder: (context, data) {
        final done = data ?? 0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LinearProgressIndicator(value: (done / goal).clamp(0, 1).toDouble(), minHeight: 5, borderRadius: BorderRadius.circular(8)),
            const SizedBox(height: 6),
            Text('$done of $goal tasks completed today${done >= goal ? ' · Goal achieved ✓' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ]),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Upcoming
// -----------------------------------------------------------------------------

/// Upcoming: a week strip to jump between days and to drop tasks on (FR-V2),
/// over a list of days. Long-press a task and drag it onto a day to reschedule.
class UpcomingScreen extends StatefulWidget {
  const UpcomingScreen({super.key});

  @override
  State<UpcomingScreen> createState() => _UpcomingScreenState();
}

class _UpcomingScreenState extends State<UpcomingScreen> {
  DateTime? _from; // the first day shown; defaults to today

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final now = repo.now;
    final today = dateOnly(now);
    final from = _from ?? today;
    return Screen(
      title: 'Upcoming',
      automaticallyImplyLeading: false,
      selectable: false,
      actions: [
        IconButton(
          tooltip: 'Pick a month or day',
          icon: const Icon(Icons.calendar_month_outlined),
          onPressed: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: from,
              firstDate: DateTime(now.year - 1),
              lastDate: DateTime(now.year + 10),
            );
            if (d != null) setState(() => _from = d);
          },
        ),
      ],
      body: Live<List<Task>>(
        create: repo.watchScheduled,
        builder: (context, data) {
          final tasks = data ?? const <Task>[];
          bool late(Task t) => isOverdue(dueDate: t.dueDate, dueTime: t.dueTime, now: repo.now);
          final iso = formatDate(from);
          final todayIso = formatDate(today);
          final overdue = from == today ? tasks.where(late).toList() : const <Task>[];
          final counts = <String, int>{};
          for (final t in tasks) {
            if (!late(t)) counts[t.dueDate!] = (counts[t.dueDate!] ?? 0) + 1;
          }
          final entries = <ListEntry>[
            if (overdue.isNotEmpty) overdueEntry(context, overdue, todayIso),
            for (final t in overdue) TaskEntry(flatRow(t)),
          ];
          final byDay = <String, List<Task>>{};
          for (final t in tasks.where((t) => !late(t) && t.dueDate!.compareTo(iso) >= 0)) {
            byDay.putIfAbsent(t.dueDate!, () => []).add(t);
          }
          for (final e in byDay.entries) {
            entries.add(HeaderEntry(dayHeading(e.key, now), count: e.value.length));
            for (final t in e.value) {
              entries.add(TaskEntry(flatRow(t)));
            }
          }
          return Column(children: [
            _WeekStrip(
              selected: from,
              today: today,
              weekStart: catalog.weekStart,
              counts: counts,
              onSelect: (d) => setState(() => _from = d),
              onDrop: (taskId, day) => guarded(context, () => repo.updateTask(taskId, dueDate: Value(formatDate(day)))),
            ),
            const Divider(height: 1),
            Expanded(
              child: EntryList(
                entries: entries,
                draggable: true,
                emptyTitle: 'Nothing scheduled',
                emptyBody: 'Tasks with a due date show up here, grouped by day.',
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.selected,
    required this.today,
    required this.weekStart,
    required this.counts,
    required this.onSelect,
    required this.onDrop,
  });

  final DateTime selected;
  final DateTime today;
  final int weekStart;
  final Map<String, int> counts;
  final ValueChanged<DateTime> onSelect;
  final void Function(String taskId, DateTime day) onDrop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final start = selected.subtract(Duration(days: (selected.weekday - weekStart + 7) % 7));
    const names = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Row(children: [
        IconButton(tooltip: 'Previous week', icon: const Icon(Icons.chevron_left), onPressed: () => onSelect(selected.subtract(const Duration(days: 7)))),
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Builder(builder: (context) {
              final day = start.add(Duration(days: i));
              final isSel = day == selected;
              final isToday = day == today;
              final n = counts[formatDate(day)] ?? 0;
              return DragTarget<String>(
                onAcceptWithDetails: (d) => onDrop(d.data, day),
                builder: (context, candidates, _) => InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onSelect(day),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: candidates.isNotEmpty ? cs.primaryContainer : (isSel ? cs.primary : null),
                      borderRadius: BorderRadius.circular(10),
                      border: isToday && !isSel ? Border.all(color: cs.primary) : null,
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(names[day.weekday], style: TextStyle(fontSize: 11, color: isSel ? cs.onPrimary : cs.outline)),
                      Text('${day.day}', style: TextStyle(fontWeight: FontWeight.w700, color: isSel ? cs.onPrimary : null)),
                      SizedBox(
                        height: 8,
                        child: n > 0 ? Icon(Icons.circle, size: 5, color: isSel ? cs.onPrimary : cs.primary) : null,
                      ),
                    ]),
                  ),
                ),
              );
            }),
          ),
        IconButton(tooltip: 'Next week', icon: const Icon(Icons.chevron_right), onPressed: () => onSelect(selected.add(const Duration(days: 7)))),
      ]),
    );
  }
}

// -----------------------------------------------------------------------------
// Label, Completed, Trash, Search
// -----------------------------------------------------------------------------

class LabelScreen extends StatelessWidget {
  const LabelScreen({super.key, required this.labelId});
  final String labelId;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final label = catalog.label(labelId);
    return Screen(
      title: '%${label?.name ?? ''}',
      actions: [
        PopupMenuButton<String>(
          onSelected: (v) => labelMenu(context, labelId, v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'merge', child: Text('Merge into…')),
            PopupMenuItem(value: 'delete', child: Text('Delete label')),
          ],
        ),
      ],
      body: Live<List<Task>>(
        id: labelId,
        create: () => repo.watchLabelTasks(labelId),
        builder: (context, data) => EntryList(
          entries: [for (final t in data ?? const <Task>[]) TaskEntry(flatRow(t))],
          emptyTitle: 'No tasks with this label',
          emptyBody: 'Add the label to a task and it appears here.',
        ),
      ),
    );
  }
}

class CompletedScreen extends StatelessWidget {
  const CompletedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.repoOf(context);
    return Screen(
      title: 'Completed',
      showAdd: false,
      body: Live<List<Task>>(
        create: repo.watchCompleted,
        builder: (context, data) {
          final entries = <ListEntry>[];
          String? last;
          for (final t in data ?? const <Task>[]) {
            final day = formatDate(dateOnly(t.completedAt!.toLocal()));
            if (day != last) {
              entries.add(HeaderEntry(dayHeading(day, repo.now)));
              last = day;
            }
            entries.add(TaskEntry(flatRow(t)));
          }
          return EntryList(entries: entries, emptyTitle: 'Nothing completed yet', emptyBody: 'Finished tasks are kept here.');
        },
      ),
    );
  }
}

class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    return Screen(
      title: 'Trash',
      showAdd: false,
      body: Live<List<Task>>(
        create: repo.watchTrashedTasks,
        builder: (context, tasksData) => Live<List<Project>>(
          create: repo.watchTrashedProjects,
          builder: (context, projData) {
            final tasks = tasksData ?? const <Task>[];
            final projects = (projData ?? const <Project>[]).where((p) => p.id != inboxId).toList();
            if (tasks.isEmpty && projects.isEmpty) {
              return const EntryList(entries: [], emptyTitle: 'Trash is empty', emptyBody: 'Deleted items stay here for 30 days.');
            }
            return ListView(padding: const EdgeInsets.only(bottom: 48), children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Items are removed for good 30 days after they were deleted.'),
              ),
              for (final p in projects)
                ListTile(
                  leading: Icon(Icons.folder, color: Color(p.color)),
                  title: Text(p.name),
                  subtitle: const Text('Project'),
                  trailing: TextButton(onPressed: () => repo.restoreProject(p.id), child: const Text('Restore')),
                ),
              for (final t in tasks)
                ListTile(
                  leading: const Icon(Icons.check_box_outline_blank),
                  title: Text(t.title),
                  subtitle: Text('Deleted ${formatDate(t.deletedAt!.toLocal())}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    TextButton(onPressed: () => repo.restoreTasks([t.id]), child: const Text('Restore')),
                    IconButton(
                      tooltip: 'Delete forever',
                      icon: const Icon(Icons.delete_forever_outlined),
                      onPressed: () async {
                        if (await confirm(context, 'Delete forever?', 'This cannot be undone.', action: 'Delete forever')) {
                          await repo.deleteTaskForever(t.id);
                        }
                      },
                    ),
                  ]),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String _q = '';
  bool _includeCompleted = false;
  List<String> _recent = const [];
  Future<Set<String>> _commentHits = Future.value(const {});
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadRecent);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final raw = await AppScope.repoOf(context).getSetting('recentSearches');
    if (raw == null || !mounted) return;
    try {
      setState(() => _recent = (jsonDecode(raw) as List).cast<String>());
    } catch (_) {}
  }

  Future<void> _remember(String q) async {
    final text = q.trim();
    if (text.isEmpty) return;
    final next = [text, ..._recent.where((r) => r != text)].take(8).toList();
    setState(() => _recent = next);
    await AppScope.repoOf(context).setSetting('recentSearches', jsonEncode(next));
  }

  void _setQuery(String q) {
    setState(() {
      _q = q.trim();
      _commentHits = _q.isEmpty ? Future.value(const {}) : AppScope.repoOf(context).taskIdsWithCommentText(_q);
    });
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: 'Search, or type a filter like p1 & overdue', border: InputBorder.none),
          onChanged: _setQuery,
          onSubmitted: _remember,
        ),
        actions: [
          IconButton(
            tooltip: _includeCompleted ? 'Hide completed tasks' : 'Include completed tasks',
            icon: Icon(_includeCompleted ? Icons.check_circle : Icons.check_circle_outline),
            onPressed: () => setState(() => _includeCompleted = !_includeCompleted),
          ),
        ],
      ),
      body: _q.isEmpty
          ? ListView(children: [
              if (_recent.isNotEmpty) ...[
                const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('Recent searches', style: TextStyle(fontWeight: FontWeight.w700))),
                for (final r in _recent)
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(r),
                    onTap: () {
                      _controller.text = r;
                      _setQuery(r);
                    },
                  ),
              ],
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Search titles, descriptions, comments, projects, sections and labels. '
                  'Filters work here too: p1, #Work, %label, overdue, no date, search: words.',
                  style: TextStyle(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            ])
          : Live<List<Task>>(
              id: _includeCompleted,
              create: () => _includeCompleted ? repo.watchAllTasks() : repo.watchAllOpen(),
              builder: (context, data) => FutureBuilder<Set<String>>(
                future: _commentHits,
                builder: (context, snap) {
                  final all = data ?? const <Task>[];
                  final env = catalog.filterEnv;
                  final asFilter = looksLikeFilter(_q, env);
                  final List<Task> hits;
                  if (asFilter) {
                    final compiled = parseFilter(_q, env);
                    hits = all.where((t) => compiled.matches(catalog.filterTask(t))).toList();
                  } else {
                    final words = _q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
                    final commentIds = snap.data ?? const <String>{};
                    hits = all.where((t) {
                      final section = catalog.section(t.sectionId)?.name ?? '';
                      final text = '${t.title} ${t.description} ${catalog.labelsFor(t.id).map((l) => l.name).join(' ')} '
                              '${catalog.project(t.projectId)?.name ?? ''} $section'
                          .toLowerCase();
                      return words.every(text.contains) || commentIds.contains(t.id);
                    }).toList();
                  }
                  return EntryList(
                    entries: [
                      if (asFilter) WidgetEntry(Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text('Showing a filter: ${hits.length} match${hits.length == 1 ? '' : 'es'}', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                      )),
                      for (final t in hits) TaskEntry(flatRow(t)),
                    ],
                    emptyTitle: 'No matches',
                    emptyBody: 'Try another word, or include completed tasks.',
                  );
                },
              ),
            ),
    );
  }
}

// -----------------------------------------------------------------------------
// Project notes (FR-P10)
// -----------------------------------------------------------------------------

class ProjectNotesScreen extends StatefulWidget {
  const ProjectNotesScreen({super.key, required this.projectId});
  final String projectId;

  @override
  State<ProjectNotesScreen> createState() => _ProjectNotesScreenState();
}

class _ProjectNotesScreenState extends State<ProjectNotesScreen> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    return Screen(
      title: '${catalog.project(widget.projectId)?.name ?? 'Project'} notes',
      showAdd: false,
      body: Column(children: [
        Expanded(
          child: Live<List<ProjectComment>>(
            id: widget.projectId,
            create: () => repo.watchProjectComments(widget.projectId),
            builder: (context, data) {
              final notes = data ?? const <ProjectComment>[];
              if (notes.isEmpty) {
                return const EntryList(entries: [], emptyTitle: 'No notes yet', emptyBody: 'Notes about the whole project go here, apart from task comments.');
              }
              return ListView(padding: const EdgeInsets.all(8), children: [
                for (final n in notes)
                  Card(
                    child: ListTile(
                      title: Text(n.body),
                      subtitle: Text(formatDate(n.createdAt.toLocal())),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'edit') {
                            final t = await promptText(context, 'Edit note', initial: n.body);
                            if (t != null && t.trim().isNotEmpty) await repo.editProjectComment(n.id, t);
                          } else {
                            await repo.deleteProjectComment(n.id);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ),
                  ),
              ]);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _c,
                decoration: const InputDecoration(hintText: 'Write a note'),
                onSubmitted: (_) => _add(repo),
              ),
            ),
            IconButton(icon: const Icon(Icons.send), tooltip: 'Add note', onPressed: () => _add(repo)),
          ]),
        ),
      ]),
    );
  }

  Future<void> _add(Repo repo) async {
    final t = _c.text;
    if (t.trim().isEmpty) return;
    _c.clear();
    await repo.addProjectComment(widget.projectId, t);
  }
}
