import 'package:flutter/material.dart';

import 'package:taskflow_core/backup.dart' show inboxId;
import '../data/database.dart';
import 'catalog.dart';
import 'common.dart';
import 'import_screen.dart' show exportProjectToFile;
import 'share_screen.dart';
import 'quick_add_sheet.dart';
import 'views.dart' show ProjectNotesScreen;

/// Create or edit a project: name, colour and where it nests (FR-P1, FR-P2).
Future<String?> showProjectEditor(BuildContext context, {String? projectId, String? parentId}) async {
  final catalog = AppScope.of(context);
  final repo = catalog.repo;
  final existing = projectId == null ? null : catalog.project(projectId);
  final name = TextEditingController(text: existing?.name ?? '');
  var color = existing?.color ?? projectPalette[6];
  var parent = existing == null ? parentId : existing.parentId;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setInner) => AlertDialog(
        title: Text(existing == null ? 'New project' : 'Edit project'),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: name, autofocus: true, maxLength: 100, decoration: const InputDecoration(labelText: 'Name', counterText: '')),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in projectPalette)
                Semantics(
                  button: true,
                  selected: c == color,
                  label: 'Colour',
                  child: InkResponse(
                    onTap: () => setInner(() => color = c),
                    child: CircleAvatar(
                      radius: 14,
                      backgroundColor: Color(c),
                      child: c == color ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.subdirectory_arrow_right),
              label: Text(parent == null ? 'Top level' : 'Inside ${catalog.project(parent!)?.name ?? ''}'),
              onPressed: () async {
                final items = <(String, String)>[
                  ('', 'Top level'),
                  for (final (p, depth) in catalog.projectTree())
                    if (p.id != projectId) (p.id, '${'    ' * depth}${p.name}'),
                ];
                final picked = await pickFromList<String>(ctx, 'Nest inside', items, selected: parent ?? '');
                if (picked != null) setInner(() => parent = picked.isEmpty ? null : picked);
              },
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  final text = name.text; // the controller is not disposed: the closing animation still builds it
  if (result != true || !context.mounted) return null;
  String? id = projectId;
  await guarded(context, () async {
    if (existing == null) {
      id = await repo.createProject(name: text, color: color, parentId: parent);
    } else {
      await repo.updateProject(existing.id, name: text, color: color);
      if (parent != existing.parentId) await repo.moveProject(existing.id, parent);
    }
  });
  return id;
}

Future<void> projectMenu(BuildContext context, String projectId, String action) async {
  final catalog = AppScope.of(context);
  final repo = catalog.repo;
  switch (action) {
    case 'edit':
      await showProjectEditor(context, projectId: projectId);
    case 'section':
      final name = await promptText(context, 'New section', hint: 'Section name', action: 'Add');
      if (name != null && name.trim().isNotEmpty && context.mounted) {
        await guarded(context, () async {
          await repo.createSection(projectId, name);
        });
      }
    case 'notes':
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProjectNotesScreen(projectId: projectId)));
    case 'duplicate':
      await guarded(context, () async {
        await repo.duplicateProject(projectId);
        if (context.mounted) showMessage(context, 'Project duplicated');
      });
    case 'share':
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShareScreen(projectId: projectId)));
    case 'export':
      await exportProjectToFile(context, projectId, template: false);
    case 'template':
      final name = await promptText(context, 'Save as template', hint: 'Template name', initial: catalog.project(projectId)?.name ?? '', action: 'Save');
      if (name != null && name.trim().isNotEmpty && context.mounted) {
        await guarded(context, () async {
          await repo.saveTemplate(name, projectId);
          if (context.mounted) showMessage(context, 'Template saved. Dates were left out.');
        });
      }
    case 'archive':
      await repo.updateProject(projectId, isArchived: true);
      if (context.mounted) {
        Navigator.of(context).pop();
        showUndo(context, 'Project archived', () => repo.updateProject(projectId, isArchived: false));
      }
    case 'delete':
      final tasks = await repo.watchProjectTasks(projectId).first;
      if (!context.mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete project?'),
          content: Text(tasks.isEmpty
              ? 'The project goes to the trash for 30 days.'
              : 'What should happen to its ${tasks.length} open task${tasks.length == 1 ? '' : 's'}?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            if (tasks.isNotEmpty) TextButton(onPressed: () => Navigator.pop(ctx, 'inbox'), child: const Text('Move to Inbox')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: Text(tasks.isEmpty ? 'Delete' : 'Delete tasks too')),
          ],
        ),
      );
      if (choice == null || !context.mounted) return;
      final trashed = await repo.deleteProject(projectId, deleteTasks: choice == 'delete');
      if (context.mounted) {
        Navigator.of(context).pop();
        showUndo(context, 'Project deleted', () async {
          await repo.restoreProject(projectId);
          await repo.restoreTasks(trashed);
        });
      }
  }
}

Future<void> sectionMenu(BuildContext context, Section s, String action) async {
  final repo = AppScope.repoOf(context);
  switch (action) {
    case 'add':
      await showQuickAdd(context, defaultProjectId: s.projectId, defaultSectionId: s.id);
    case 'rename':
      final name = await promptText(context, 'Rename section', initial: s.name);
      if (name != null && name.trim().isNotEmpty) await repo.updateSection(s.id, name: name);
    case 'archive':
      await repo.updateSection(s.id, isArchived: true);
      if (context.mounted) showUndo(context, 'Section archived', () => repo.updateSection(s.id, isArchived: false));
    case 'delete':
      if (await confirm(context, 'Delete section?', 'Its tasks stay in the project, without a section.')) {
        await repo.deleteSection(s.id);
      }
  }
}

Future<void> labelMenu(BuildContext context, String labelId, String action) async {
  final catalog = AppScope.of(context);
  final repo = catalog.repo;
  final label = catalog.label(labelId);
  if (label == null) return;
  switch (action) {
    case 'rename':
      final name = await promptText(context, 'Rename label', initial: label.name);
      if (name != null && context.mounted) await guarded(context, () => repo.updateLabel(labelId, name: name));
    case 'merge':
      final items = <(String, String)>[
        for (final l in catalog.labels)
          if (l.id != labelId) (l.id, l.name),
      ];
      if (items.isEmpty) {
        showMessage(context, 'There is no other label to merge into.');
        return;
      }
      final target = await pickFromList<String>(context, 'Merge "${label.name}" into', items);
      if (target != null && context.mounted) {
        await repo.mergeLabels(labelId, target);
        if (context.mounted) Navigator.of(context).pop();
      }
    case 'delete':
      if (await confirm(context, 'Delete label?', 'It is removed from every task. The tasks themselves stay.')) {
        await repo.deleteLabel(labelId);
        if (context.mounted) Navigator.of(context).pop();
      }
  }
}

/// Convenience for places that need a project's display name or Inbox fallback.
String projectName(Catalog c, String id) => id == inboxId ? 'Inbox' : (c.project(id)?.name ?? 'Project');
