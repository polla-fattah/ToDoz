import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:taskflow_core/date_parser.dart' show formatTime;

import '../data/database.dart';
import 'catalog.dart';
import 'common.dart';

/// Everything done to tasks and projects, newest first, with Undo (FR-K6..K8).
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

const _kinds = <(String, String, Set<String>?)>[
  ('all', 'All', null),
  ('add', 'Added', {'add'}),
  ('edit', 'Edited', {'edit'}),
  ('done', 'Completed', {'complete', 'uncomplete'}),
  ('move', 'Moved', {'move'}),
  ('del', 'Deleted', {'delete', 'restore'}),
];

class _ActivityScreenState extends State<ActivityScreen> {
  String _kind = 'all';
  String? _projectId;
  int _limit = 200;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final events = _kinds.firstWhere((k) => k.$1 == _kind).$3;
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            for (final k in _kinds)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(k.$2), selected: _kind == k.$1, onSelected: (_) => setState(() => _kind = k.$1)),
              ),
            const SizedBox(width: 8),
            DropdownButton<String?>(
              value: _projectId,
              hint: const Text('All projects'),
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('All projects')),
                DropdownMenuItem(value: catalog.inbox.id, child: const Text('Inbox')),
                for (final (p, _) in catalog.projectTree()) DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (v) => setState(() => _projectId = v),
            ),
          ]),
        ),
        Expanded(
          child: Live<List<ActivityEntry>>(
            id: '$_kind/$_projectId/$_limit',
            create: () => repo.watchActivity(projectId: _projectId, events: events, limit: _limit),
            builder: (context, data) {
              if (data == null) return const SizedBox.shrink();
              if (data.isEmpty) {
                return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Nothing here yet. What you add, change, complete and delete is listed here.')));
              }
              DateTime? day;
              final rows = <Widget>[];
              for (final e in data) {
                final at = DateTime.fromMillisecondsSinceEpoch(e.atMs);
                final d = DateTime(at.year, at.month, at.day);
                if (day != d) {
                  day = d;
                  rows.add(Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(DateFormat('EEEE, d MMMM').format(d), style: Theme.of(context).textTheme.titleSmall),
                  ));
                }
                rows.add(_ActivityRow(entry: e, key: ValueKey(e.id)));
              }
              if (data.length >= _limit) {
                rows.add(Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton(onPressed: () => setState(() => _limit += 200), child: const Text('Show older')),
                ));
              }
              return ListView(children: rows);
            },
          ),
        ),
      ]),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({super.key, required this.entry});
  final ActivityEntry entry;

  (IconData, String) get _look => switch (entry.event) {
        'add' => (Icons.add_circle_outline, 'Added'),
        'complete' => (Icons.check_circle_outline, 'Completed'),
        'uncomplete' => (Icons.radio_button_unchecked, 'Reopened'),
        'delete' => (Icons.delete_outline, 'Deleted'),
        'restore' => (Icons.restore_from_trash_outlined, 'Restored'),
        'move' => (Icons.drive_file_move_outline, 'Moved'),
        _ => (Icons.edit_outlined, 'Edited'),
      };

  String _fieldName(String f) => switch (f) {
        'due_date' => 'due date',
        'due_time' => 'due time',
        'is_archived' => 'archived',
        'project_id' => 'project',
        'section_id' => 'section',
        'parent_id' => 'parent task',
        _ => f,
      };

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final (icon, verb) = _look;
    final at = DateTime.fromMillisecondsSinceEpoch(entry.atMs);
    final project = entry.projectId == null ? null : (catalog.project(entry.projectId!)?.name);

    String shown(String? v) {
      if (v == null || v.isEmpty) return 'none';
      if (entry.field == 'project_id') return catalog.project(v)?.name ?? 'a project';
      if (entry.field == 'section_id') return catalog.section(v)?.name ?? 'a section';
      if (entry.field == 'parent_id') return 'a task';
      return v.length > 60 ? '${v.substring(0, 57)}...' : v;
    }

    final detail = entry.field == null ? null : '${_fieldName(entry.field!)}: ${shown(entry.oldValue)} → ${shown(entry.newValue)}';
    return ListTile(
      leading: Icon(icon),
      title: Text('$verb ${entry.entityType == 'project' ? 'project ' : ''}“${entry.title}”', maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        formatTime(at.hour * 60 + at.minute, use24h: catalog.use24h),
        if (project != null && entry.entityType == 'task') project,
        ?detail,
      ].join(' · ')),
      trailing: FutureBuilder<bool>(
        future: repo.canUndo(entry),
        builder: (context, snap) => snap.data == true
            ? TextButton(
                onPressed: () => guarded(context, () async {
                  await repo.undoActivity(entry);
                  if (context.mounted) showMessage(context, 'Undone');
                }),
                child: const Text('Undo'),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
