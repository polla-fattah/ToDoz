import 'package:flutter/material.dart';

import '../core/backup.dart' show inboxId;
import '../core/date_parser.dart';
import '../core/reminder.dart' show isOverdue;
import '../data/database.dart';
import '../data/repository.dart';
import 'catalog.dart';
import 'common.dart';
import 'project_dialogs.dart';
import 'quick_add_sheet.dart';
import 'task_tree.dart';
import 'task_widgets.dart';

/// Page frame shared by every task screen: title, optional actions, and the
/// add button that opens Quick Add with this screen's defaults.
class Screen extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: automaticallyImplyLeading,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title),
            if (subtitle != null) Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ]),
          actions: [
            if (!automaticallyImplyLeading && showAdd)
              IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen())),
              ),
            ...actions,
          ],
        ),
        body: body,
        floatingActionButton: showAdd
            ? FloatingActionButton(
                heroTag: null, // every tab has its own button; shared hero tags clash on navigation
                tooltip: 'Add task',
                onPressed: () => showQuickAdd(
                  context,
                  defaultProjectId: addProjectId ?? inboxId,
                  defaultSectionId: addSectionId,
                  defaultDue: addDue,
                ),
                child: const Icon(Icons.add),
              )
            : null,
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
    return Screen(
      title: project?.name ?? 'Project',
      automaticallyImplyLeading: !isTab,
      addProjectId: projectId,
      actions: [
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
        id: projectId,
        create: () => repo.watchProjectTasks(projectId),
        builder: (context, tasksData) => Live<List<Section>>(
          id: projectId,
          create: () => repo.watchSections(projectId),
          builder: (context, secData) {
            final tasks = tasksData ?? const <Task>[];
            final sections = secData ?? const <Section>[];
            final sectionIds = {for (final s in sections) s.id};
            final entries = <ListEntry>[];

            final loose = tasks.where((t) => t.sectionId == null || !sectionIds.contains(t.sectionId)).toList();
            for (final r in flattenTasks(loose)) {
              entries.add(TaskEntry(r, showProject: false));
            }
            for (final s in sections) {
              final inSection = tasks.where((t) => t.sectionId == s.id).toList();
              entries.add(HeaderEntry(
                s.name,
                count: inSection.length,
                onTap: () => repo.updateSection(s.id, isCollapsed: !s.isCollapsed),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  PopupMenuButton<String>(
                    onSelected: (v) => sectionMenu(context, s, v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'add', child: Text('Add task')),
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'archive', child: Text('Archive')),
                      PopupMenuItem(value: 'delete', child: Text('Delete section')),
                    ],
                  ),
                  Icon(s.isCollapsed ? Icons.chevron_right : Icons.expand_more),
                  const SizedBox(width: 4),
                ]),
              ));
              if (!s.isCollapsed) {
                for (final r in flattenTasks(inSection)) {
                  entries.add(TaskEntry(r, showProject: false));
                }
              }
            }
            if (!isInbox) {
              entries.add(WidgetEntry(Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add section'),
                  onPressed: () async {
                    final name = await promptText(context, 'New section', hint: 'Section name', action: 'Add');
                    if (name != null && name.trim().isNotEmpty && context.mounted) {
                      await guarded(context, () async {
                        await repo.createSection(projectId, name);
                      });
                    }
                  },
                ),
              )));
            }
            return EntryList(
              entries: entries,
              emptyTitle: isInbox ? 'Inbox is empty' : 'No tasks yet',
              emptyBody: isInbox ? 'Anything you add without a project lands here.' : 'Tap + to add the first task.',
            );
          },
        ),
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

class UpcomingScreen extends StatelessWidget {
  const UpcomingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.repoOf(context);
    final now = repo.now;
    final today = formatDate(dateOnly(now));
    return Screen(
      title: 'Upcoming',
      automaticallyImplyLeading: false,
      body: Live<List<Task>>(
        create: repo.watchScheduled,
        builder: (context, data) {
          final tasks = data ?? const <Task>[];
          bool late(Task t) => isOverdue(dueDate: t.dueDate, dueTime: t.dueTime, now: repo.now);
          final overdue = tasks.where(late).toList();
          final entries = <ListEntry>[
            if (overdue.isNotEmpty) overdueEntry(context, overdue, today),
            for (final t in overdue) TaskEntry(flatRow(t)),
          ];
          final byDay = <String, List<Task>>{};
          for (final t in tasks.where((t) => !late(t))) {
            byDay.putIfAbsent(t.dueDate!, () => []).add(t);
          }
          for (final e in byDay.entries) {
            entries.add(HeaderEntry(dayHeading(e.key, now), count: e.value.length));
            for (final t in e.value) {
              entries.add(TaskEntry(flatRow(t)));
            }
          }
          return EntryList(
            entries: entries,
            emptyTitle: 'Nothing scheduled',
            emptyBody: 'Tasks with a due date show up here, grouped by day.',
          );
        },
      ),
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

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Search tasks, descriptions, labels', border: InputBorder.none),
          onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
        ),
      ),
      body: Live<List<Task>>(
        create: repo.watchAllOpen,
        builder: (context, data) {
          if (_q.isEmpty) return const EntryList(entries: [], emptyTitle: 'Search', emptyBody: 'Type to search your open tasks.');
          final hits = (data ?? const <Task>[]).where((t) {
            final labels = catalog.labelsFor(t.id).map((l) => l.name.toLowerCase()).join(' ');
            return '${t.title} ${t.description} $labels'.toLowerCase().contains(_q);
          });
          return EntryList(
            entries: [for (final t in hits) TaskEntry(flatRow(t))],
            emptyTitle: 'No matches',
            emptyBody: 'Try another word.',
          );
        },
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
