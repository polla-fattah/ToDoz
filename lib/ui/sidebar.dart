import 'package:flutter/material.dart';

import 'package:taskflow_core/backup.dart' show inboxId;
import 'browse_screen.dart';
import 'calendar_view.dart';
import 'catalog.dart';
import 'common.dart';
import 'filter_editor.dart';
import 'help_screen.dart';
import 'project_dialogs.dart';
import 'settings_screen.dart';
import 'views.dart';

/// Opens a destination in the content area: [key] identifies it so the
/// sidebar can highlight it.
typedef Navigate = void Function(String key, WidgetBuilder builder);

/// The permanent navigation on tablet and desktop widths (FR-V12): Inbox,
/// Today, Upcoming, favorites, the project tree, labels and filters.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.selectedKey, required this.onNavigate});
  final String selectedKey;
  final Navigate onNavigate;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;

    // Dropping a dragged task on a project moves it there (to the project itself, out of any section).
    Future<void> moveHere(String taskId, String projectId, String projectName) async {
      final repo = catalog.repo;
      final before = await repo.getTask(taskId);
      if (before == null || before.projectId == projectId) return;
      if (!context.mounted) return;
      try {
        await repo.moveTask(taskId, projectId: projectId);
      } on Exception catch (e) {
        if (context.mounted) showMessage(context, e.toString());
        return;
      }
      if (context.mounted) {
        showUndo(
          context,
          'Moved to $projectName',
          () => repo.moveTask(taskId, projectId: before.projectId, sectionId: before.sectionId, parentId: before.parentId),
        );
      }
    }

    Widget item(String key, IconData icon, String label, WidgetBuilder builder,
        {Color? color, Widget? trailing, double indent = 0, String? dropProjectId}) {
      Widget tile(bool hovering) => ListTile(
            dense: true,
            selected: selectedKey == key,
            selectedTileColor: cs.primaryContainer.withValues(alpha: 0.5),
            tileColor: hovering ? cs.primaryContainer : null,
            contentPadding: EdgeInsets.only(left: 16 + indent, right: 8),
            leading: Icon(icon, size: 20, color: color),
            title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: trailing,
            onTap: () => onNavigate(key, builder),
          );
      if (dropProjectId == null) return tile(false);
      return DragTarget<String>(
        onAcceptWithDetails: (d) => moveHere(d.data, dropProjectId, label),
        builder: (context, candidates, _) => tile(candidates.isNotEmpty),
      );
    }

    Widget heading(String text, {VoidCallback? onAdd, String? addTip}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 4, 0),
          child: Row(children: [
            Expanded(child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.outline))),
            if (onAdd != null) IconButton(visualDensity: VisualDensity.compact, tooltip: addTip, icon: const Icon(Icons.add, size: 18), onPressed: onAdd),
          ]),
        );

    final favProjects = catalog.projects.where((p) => p.isFavorite && p.id != inboxId).toList();
    final favLabels = catalog.labels.where((l) => l.isFavorite).toList();
    final favFilters = catalog.filters.where((f) => f.isFavorite).toList();

    return Material(
      color: cs.surfaceContainerLow,
      child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        const SizedBox(height: 8),
        item('inbox', Icons.inbox_outlined, 'Inbox', (_) => const ProjectScreen(projectId: inboxId, isTab: true), dropProjectId: inboxId),
        item('today', Icons.today_outlined, 'Today', (_) => const TodayScreen()),
        item('upcoming', Icons.calendar_month_outlined, 'Upcoming', (_) => const UpcomingScreen()),
        item('calendar', Icons.calendar_view_week_outlined, 'Calendar', (_) => const CalendarScreen()),
        item('search', Icons.search, 'Search', (_) => const SearchScreen()),
        if (favProjects.isNotEmpty || favLabels.isNotEmpty || favFilters.isNotEmpty) ...[
          heading('Favorites'),
          for (final p in favProjects) item('p:${p.id}', Icons.circle, p.name, (_) => ProjectScreen(projectId: p.id), color: Color(p.color), dropProjectId: p.id),
          for (final l in favLabels) item('l:${l.id}', Icons.sell_outlined, l.name, (_) => LabelScreen(labelId: l.id), color: Color(l.color)),
          for (final f in favFilters) item('f:${f.id}', Icons.filter_alt_outlined, f.name, (_) => FilterScreen(filterId: f.id), color: Color(f.color)),
        ],
        heading('Projects', addTip: 'New project', onAdd: () async {
          final id = await showProjectEditor(context);
          if (id != null) onNavigate('p:$id', (_) => ProjectScreen(projectId: id));
        }),
        for (final (p, depth) in catalog.projectTree())
          item('p:${p.id}', Icons.circle, p.name, (_) => ProjectScreen(projectId: p.id), color: Color(p.color), indent: depth * 16.0, dropProjectId: p.id),
        heading('Filters', addTip: 'New filter', onAdd: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FilterEditorPage()))),
        for (final f in catalog.filters)
          item('f:${f.id}', Icons.filter_alt_outlined, f.name, (_) => FilterScreen(filterId: f.id), color: Color(f.color)),
        heading('Labels'),
        for (final l in catalog.labels) item('l:${l.id}', Icons.sell_outlined, l.name, (_) => LabelScreen(labelId: l.id), color: Color(l.color)),
        const Divider(),
        item('completed', Icons.check_circle_outline, 'Completed', (_) => const CompletedScreen()),
        item('trash', Icons.delete_outline, 'Trash', (_) => const TrashScreen()),
        item('browse', Icons.grid_view_outlined, 'Browse', (_) => const BrowseScreen()),
        item('help', Icons.help_outline, 'Help', (_) => const HelpScreen()),
        item('settings', Icons.settings_outlined, 'Settings', (_) => const SettingsScreen()),
      ]),
    );
  }
}
