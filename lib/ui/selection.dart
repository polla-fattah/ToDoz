import 'package:flutter/material.dart';

import '../core/backup.dart' show inboxId;
import '../core/date_parser.dart';
import 'catalog.dart';
import 'common.dart';

/// The tasks picked by long-pressing (FR-T7). Screens that support it provide
/// one through [SelectionScope]; tiles read it to show and toggle selection.
class Selection extends ChangeNotifier {
  final Set<String> ids = {};

  bool get active => ids.isNotEmpty;

  bool contains(String id) => ids.contains(id);

  void toggle(String id) {
    if (!ids.add(id)) ids.remove(id);
    notifyListeners();
  }

  void clear() {
    if (ids.isEmpty) return;
    ids.clear();
    notifyListeners();
  }
}

class SelectionScope extends InheritedNotifier<Selection> {
  const SelectionScope({super.key, required Selection selection, required super.child}) : super(notifier: selection);

  /// The selection of the nearest screen, or null where selecting is not offered.
  static Selection? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SelectionScope>()?.notifier;
}

/// The actions shown while tasks are selected.
List<Widget> selectionActions(BuildContext context, Selection selection) {
  final catalog = AppScope.of(context);
  final repo = catalog.repo;
  List<String> picked() => selection.ids.toList();

  Future<void> run(Future<void> Function() f) async {
    await guarded(context, f);
  }

  return [
    IconButton(
      tooltip: 'Complete',
      icon: const Icon(Icons.check_circle_outline),
      onPressed: () async {
        final ids = picked();
        final outcomes = await repo.bulkComplete(ids);
        selection.clear();
        if (context.mounted) {
          showUndo(context, '${ids.length} task${ids.length == 1 ? '' : 's'} completed', () => repo.bulkUndoComplete(outcomes));
        }
      },
    ),
    IconButton(
      tooltip: 'Reschedule',
      icon: const Icon(Icons.event_outlined),
      onPressed: () async {
        final now = repo.now;
        final d = await showDatePicker(
          context: context,
          initialDate: dateOnly(now),
          firstDate: DateTime(now.year - 1),
          lastDate: DateTime(now.year + 10),
        );
        if (d == null || !context.mounted) return;
        final ids = picked();
        final before = {for (final id in ids) id: (await repo.getTask(id))?.dueDate};
        await run(() => repo.rescheduleTasks(ids, formatDate(d)));
        selection.clear();
        if (context.mounted) showUndo(context, 'Rescheduled ${ids.length}', () => repo.setDueDates(before));
      },
    ),
    PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (v) async {
        final ids = picked();
        switch (v) {
          case 'priority':
            final p = await pickFromList<int>(context, 'Priority', const [(1, 'Priority 1'), (2, 'Priority 2'), (3, 'Priority 3'), (4, 'No priority')]);
            if (p != null) {
              await run(() => repo.bulkSetPriority(ids, p));
              selection.clear();
            }
          case 'move':
            final items = <(String, String)>[
              (inboxId, 'Inbox'),
              for (final (p, depth) in catalog.projectTree()) (p.id, '${'    ' * depth}${p.name}'),
            ];
            final target = await pickFromList<String>(context, 'Move to project', items);
            if (target != null) {
              await run(() => repo.bulkMoveToProject(ids, target));
              selection.clear();
            }
          case 'label':
            if (catalog.labels.isEmpty) {
              showMessage(context, 'Create a label first (Browse, Labels).');
              return;
            }
            final l = await pickFromList<String>(context, 'Add label', [for (final l in catalog.labels) (l.id, l.name)]);
            if (l != null) {
              await run(() => repo.bulkAddLabel(ids, l));
              selection.clear();
            }
          case 'delete':
            final all = await repo.bulkDelete(ids);
            selection.clear();
            if (context.mounted) {
              showUndo(context, '${ids.length} task${ids.length == 1 ? '' : 's'} deleted', () => repo.restoreTasks(all));
            }
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'priority', child: Text('Change priority')),
        PopupMenuItem(value: 'move', child: Text('Move to project')),
        PopupMenuItem(value: 'label', child: Text('Add label')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    ),
  ];
}

