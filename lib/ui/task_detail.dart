import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import '../core/backup.dart' show inboxId;
import '../core/date_parser.dart';
import '../data/database.dart';
import '../data/repository.dart';
import 'catalog.dart';
import 'common.dart';
import 'task_tree.dart';
import 'task_widgets.dart';

class TaskDetailPage extends StatefulWidget {
  const TaskDetailPage({super.key, required this.taskId});
  final String taskId;

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _newSub = TextEditingController();
  final _newComment = TextEditingController();
  Timer? _debounce;
  bool _loaded = false;
  late Repo _repo; // kept here because dispose() may not look up inherited widgets

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repo = AppScope.repoOf(context);
  }

  @override
  void dispose() {
    _flush();
    _debounce?.cancel();
    _title.dispose();
    _description.dispose();
    _newSub.dispose();
    _newComment.dispose();
    super.dispose();
  }

  /// Saves the text fields. Called on a short delay while typing and when the page closes.
  void _flush() {
    if (!_loaded) return;
    final title = _title.text.trim();
    _repo.updateTask(
      widget.taskId,
      title: title.isEmpty ? null : title, // never save an empty title
      description: _description.text,
    );
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _flush);
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    return Live<Task?>(
      id: widget.taskId,
      create: () => repo.watchTask(widget.taskId),
      builder: (context, task) {
        if (!_loaded && task == null) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (task == null || task.deletedAt != null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('This task is no longer here.')));
        }
        if (!_loaded) {
          _title.text = task.title;
          _description.text = task.description;
          _loaded = true;
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(catalog.project(task.projectId)?.name ?? ''),
            actions: [
              IconButton(
                tooltip: task.completedAt == null ? 'Complete' : 'Reopen',
                icon: Icon(task.completedAt == null ? Icons.check_circle_outline : Icons.undo),
                onPressed: () => toggleTask(context, task),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => _menu(context, task, v),
                itemBuilder: (_) => [
                  if (task.parentId != null) const PopupMenuItem(value: 'promote', child: Text('Make top-level task')),
                  const PopupMenuItem(value: 'parent', child: Text('Make sub-task of…')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete task')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
            children: [
              TextField(
                controller: _title,
                maxLength: 500,
                maxLines: null,
                style: Theme.of(context).textTheme.titleLarge,
                decoration: const InputDecoration(border: InputBorder.none, counterText: '', hintText: 'Task name'),
                onChanged: (_) => _scheduleSave(),
              ),
              TextField(
                controller: _description,
                maxLines: null,
                minLines: 2,
                decoration: const InputDecoration(border: InputBorder.none, hintText: 'Description'),
                onChanged: (_) => _scheduleSave(),
              ),
              const Divider(),
              _fields(context, catalog, task),
              const Divider(),
              _subtasks(context, catalog, task),
              const Divider(),
              _comments(context, catalog, task),
            ],
          ),
        );
      },
    );
  }

  Widget _fields(BuildContext context, Catalog catalog, Task task) {
    final repo = catalog.repo;
    final cs = Theme.of(context).colorScheme;
    final now = repo.now;
    final labels = catalog.labelsFor(task.id);
    final sections = catalog.sectionsOf(task.projectId);
    final section = catalog.section(task.sectionId);
    final isSub = task.parentId != null;

    Widget row(IconData icon, String label, Widget child) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 36, child: Icon(icon, size: 20, color: cs.outline)),
            SizedBox(width: 78, child: Text(label, style: TextStyle(color: cs.outline))),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
          ]),
        );

    return Column(children: [
      row(
        Icons.event_outlined,
        'Due date',
        Wrap(spacing: 6, runSpacing: 4, children: [
          ActionChip(
            label: Text(task.dueDate == null ? 'No date' : dueLabel(task.dueDate!, now)),
            onPressed: () async {
              final current = task.dueDate == null ? null : parseIsoDate(task.dueDate!);
              final picked = await showDatePicker(
                context: context,
                initialDate: current ?? now,
                firstDate: DateTime(now.year - 2),
                lastDate: DateTime(now.year + 10),
              );
              if (picked != null) await repo.updateTask(task.id, dueDate: Value(formatDate(picked)));
            },
          ),
          ActionChip(label: const Text('Today'), onPressed: () => repo.updateTask(task.id, dueDate: Value(formatDate(now)))),
          ActionChip(
            label: const Text('Tomorrow'),
            onPressed: () => repo.updateTask(task.id, dueDate: Value(formatDate(dateOnly(now).add(const Duration(days: 1))))),
          ),
          if (task.dueDate != null)
            ActionChip(label: const Text('Clear'), onPressed: () => repo.updateTask(task.id, dueDate: const Value(null))),
        ]),
      ),
      row(
        Icons.flag_outlined,
        'Priority',
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [for (final p in [1, 2, 3, 4]) ButtonSegment(value: p, label: Text('P$p'))],
          selected: {task.priority},
          onSelectionChanged: (s) => repo.updateTask(task.id, priority: s.first),
        ),
      ),
      row(
        Icons.folder_outlined,
        'Project',
        isSub
            ? Text(catalog.project(task.projectId)?.name ?? '')
            : TextButton.icon(
                icon: Icon(Icons.circle, size: 12, color: catalog.colorOf(task.projectId)),
                label: Text(catalog.project(task.projectId)?.name ?? ''),
                onPressed: () async {
                  final items = <(String, String)>[
                    (inboxId, 'Inbox'),
                    for (final (p, depth) in catalog.projectTree()) (p.id, '${'    ' * depth}${p.name}'),
                  ];
                  final picked = await pickFromList<String>(context, 'Move to project', items, selected: task.projectId);
                  if (picked != null && picked != task.projectId && context.mounted) {
                    await guarded(context, () => repo.moveTask(task.id, projectId: picked));
                  }
                },
              ),
      ),
      if (!isSub && sections.isNotEmpty)
        row(
          Icons.view_agenda_outlined,
          'Section',
          TextButton(
            child: Text(section?.name ?? 'No section'),
            onPressed: () async {
              final items = <(String, String)>[('', 'No section'), for (final s in sections) (s.id, s.name)];
              final picked = await pickFromList<String>(context, 'Section', items, selected: task.sectionId ?? '');
              if (picked != null && context.mounted) {
                await guarded(context, () => repo.moveTask(task.id, projectId: task.projectId, sectionId: picked.isEmpty ? null : picked));
              }
            },
          ),
        ),
      row(
        Icons.sell_outlined,
        'Labels',
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final l in labels)
            InputChip(
              label: Text(l.name),
              avatar: Icon(Icons.sell, size: 14, color: Color(l.color)),
              onDeleted: () => repo.updateTask(task.id, labelIds: [for (final x in labels) if (x.id != l.id) x.id]),
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 16),
            label: const Text('Label'),
            onPressed: () => _pickLabels(context, catalog, task, labels),
          ),
        ]),
      ),
    ]);
  }

  Future<void> _pickLabels(BuildContext context, Catalog catalog, Task task, List<Label> current) async {
    final repo = catalog.repo;
    final chosen = {for (final l in current) l.id};
    final newName = TextEditingController();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Labels'),
          content: SizedBox(
            width: 320,
            child: ListView(shrinkWrap: true, children: [
              for (final l in catalog.labels)
                CheckboxListTile(
                  value: chosen.contains(l.id),
                  title: Text(l.name),
                  secondary: Icon(Icons.sell, color: Color(l.color), size: 18),
                  onChanged: (v) => setInner(() => v == true ? chosen.add(l.id) : chosen.remove(l.id)),
                ),
              TextField(
                controller: newName,
                decoration: const InputDecoration(hintText: 'New label'),
                onSubmitted: (v) async {
                  if (v.trim().isEmpty) return;
                  final id = await repo.createLabel(v);
                  chosen.add(id);
                  newName.clear();
                  if (ctx.mounted) Navigator.pop(ctx, chosen);
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, chosen), child: const Text('Done')),
          ],
        ),
      ),
    );
    if (result != null) await repo.updateTask(task.id, labelIds: result.toList());
  }

  Widget _subtasks(BuildContext context, Catalog catalog, Task task) {
    final repo = catalog.repo;
    return Live<List<Task>>(
      id: task.id,
      create: () => repo.watchChildren(task.id),
      builder: (context, data) {
        final kids = data ?? const <Task>[];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text('Sub-tasks${kids.isEmpty ? '' : '  ${kids.where((k) => k.completedAt != null).length}/${kids.length}'}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          for (final k in kids) TaskTile(row: TreeRow(k, 0, hasChildren: false, collapsed: false), showProject: false),
          Row(children: [
            const Icon(Icons.add, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _newSub,
                decoration: const InputDecoration(hintText: 'Add sub-task', border: InputBorder.none),
                onSubmitted: (v) async {
                  if (v.trim().isEmpty) return;
                  _newSub.clear();
                  await guarded(context, () async {
                    await repo.addTask(title: v, parentId: task.id);
                  });
                },
              ),
            ),
          ]),
        ]);
      },
    );
  }

  Widget _comments(BuildContext context, Catalog catalog, Task task) {
    final repo = catalog.repo;
    final cs = Theme.of(context).colorScheme;
    return Live<List<Comment>>(
      id: task.id,
      create: () => repo.watchComments(task.id),
      builder: (context, data) {
        final comments = data ?? const <Comment>[];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text('Comments${comments.isEmpty ? '' : '  ${comments.length}'}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          for (final c in comments)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text(c.body),
                subtitle: Text(_stamp(c.createdAt), style: TextStyle(fontSize: 11, color: cs.outline)),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      final t = await promptText(context, 'Edit comment', initial: c.body);
                      if (t != null && t.trim().isNotEmpty) await repo.editComment(c.id, t);
                    } else {
                      await repo.deleteComment(c.id);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ),
            ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _newComment,
                decoration: const InputDecoration(hintText: 'Write a comment'),
                onSubmitted: (v) => _addComment(repo, task.id),
              ),
            ),
            IconButton(icon: const Icon(Icons.send), tooltip: 'Add comment', onPressed: () => _addComment(repo, task.id)),
          ]),
        ]);
      },
    );
  }

  Future<void> _addComment(Repo repo, String taskId) async {
    final t = _newComment.text;
    if (t.trim().isEmpty) return;
    _newComment.clear();
    await repo.addComment(taskId, t);
  }

  String _stamp(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  Future<void> _menu(BuildContext context, Task task, String action) async {
    final repo = AppScope.repoOf(context);
    switch (action) {
      case 'delete':
        final ids = await repo.deleteTask(task.id);
        if (context.mounted) {
          final outer = Navigator.of(context);
          final messenger = ScaffoldMessenger.of(context);
          outer.pop();
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(SnackBar(
            content: const Text('Task deleted'),
            duration: const Duration(seconds: 8),
            action: SnackBarAction(label: 'Undo', onPressed: () => repo.restoreTasks(ids)),
          ));
        }
      case 'promote':
        await guarded(context, () => repo.promoteToTopLevel(task.id));
      case 'parent':
        final candidates = await repo.watchProjectTasks(task.projectId).first;
        if (!context.mounted) return;
        final items = <(String, String)>[
          for (final t in candidates)
            if (t.id != task.id) (t.id, t.title),
        ];
        if (items.isEmpty) {
          showMessage(context, 'There are no other tasks in this project.');
          return;
        }
        final picked = await pickFromList<String>(context, 'Make sub-task of', items);
        if (picked != null && context.mounted) {
          await guarded(context, () => repo.moveTask(task.id, projectId: task.projectId, parentId: picked));
        }
    }
  }
}
