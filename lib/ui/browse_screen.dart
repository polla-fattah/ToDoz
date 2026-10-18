import 'package:flutter/material.dart';

import '../data/database.dart';
import 'catalog.dart';
import 'common.dart';
import 'project_dialogs.dart';
import 'settings_screen.dart';
import 'views.dart';

class BrowseScreen extends StatelessWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final favProjects = catalog.projects.where((p) => p.isFavorite).toList();
    final favLabels = catalog.labels.where((l) => l.isFavorite).toList();
    final tree = catalog.projectTree();

    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

    return Screen(
      title: 'Browse',
      automaticallyImplyLeading: false,
      showAdd: false,
      actions: [
        IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => push(const SettingsScreen())),
      ],
      body: ListView(padding: const EdgeInsets.only(bottom: 48), children: [
        ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('Completed'), onTap: () => push(const CompletedScreen())),
        ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Trash'), onTap: () => push(const TrashScreen())),
        if (favProjects.isNotEmpty || favLabels.isNotEmpty) ...[
          const _Section('Favorites'),
          for (final p in favProjects)
            ListTile(
              leading: Icon(Icons.circle, size: 14, color: Color(p.color)),
              title: Text(p.name),
              onTap: () => push(ProjectScreen(projectId: p.id)),
            ),
          for (final l in favLabels)
            ListTile(
              leading: Icon(Icons.sell, size: 16, color: Color(l.color)),
              title: Text(l.name),
              onTap: () => push(LabelScreen(labelId: l.id)),
            ),
        ],
        _Section(
          'Projects',
          trailing: IconButton(
            tooltip: 'New project',
            icon: const Icon(Icons.add),
            onPressed: () async {
              final id = await showProjectEditor(context);
              if (id != null && context.mounted) push(ProjectScreen(projectId: id));
            },
          ),
        ),
        if (tree.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Projects group related tasks. Tap + to create one.'),
          ),
        for (final (p, depth) in tree)
          ListTile(
            contentPadding: EdgeInsets.only(left: 16 + depth * 24.0, right: 8),
            leading: Icon(Icons.circle, size: 14, color: Color(p.color)),
            title: Text(p.name),
            trailing: IconButton(
              tooltip: p.isFavorite ? 'Remove from favorites' : 'Add to favorites',
              icon: Icon(p.isFavorite ? Icons.favorite : Icons.favorite_border, size: 20),
              onPressed: () => repo.updateProject(p.id, isFavorite: !p.isFavorite),
            ),
            onTap: () => push(ProjectScreen(projectId: p.id)),
          ),
        _Section(
          'Labels',
          trailing: IconButton(
            tooltip: 'New label',
            icon: const Icon(Icons.add),
            onPressed: () async {
              final name = await promptText(context, 'New label', hint: 'Label name', action: 'Add');
              if (name != null && name.trim().isNotEmpty && context.mounted) {
                await guarded(context, () async {
                  await repo.createLabel(name);
                });
              }
            },
          ),
        ),
        if (catalog.labels.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Labels group tasks across projects. Type %label in Quick Add or tap + here.'),
          ),
        for (final l in catalog.labels)
          ListTile(
            leading: Icon(Icons.sell, size: 16, color: Color(l.color)),
            title: Text(l.name),
            trailing: IconButton(
              tooltip: l.isFavorite ? 'Remove from favorites' : 'Add to favorites',
              icon: Icon(l.isFavorite ? Icons.favorite : Icons.favorite_border, size: 20),
              onPressed: () => repo.updateLabel(l.id, isFavorite: !l.isFavorite),
            ),
            onTap: () => push(LabelScreen(labelId: l.id)),
          ),
        if (catalog.projects.any((p) => p.isArchived))
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Archived projects'),
            onTap: () => push(const ArchivedProjectsScreen()),
          ),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
        child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
          ?trailing,
        ]),
      );
}

class ArchivedProjectsScreen extends StatelessWidget {
  const ArchivedProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.repoOf(context);
    return Screen(
      title: 'Archived projects',
      showAdd: false,
      body: Live<List<Project>>(
        create: () => repo.watchProjects(includeArchived: true),
        builder: (context, data) {
          final archived = (data ?? const <Project>[]).where((p) => p.isArchived).toList();
          if (archived.isEmpty) return const Center(child: Text('No archived projects.'));
          return ListView(children: [
            for (final p in archived)
              ListTile(
                leading: Icon(Icons.circle, size: 14, color: Color(p.color)),
                title: Text(p.name),
                trailing: TextButton(onPressed: () => repo.updateProject(p.id, isArchived: false), child: const Text('Unarchive')),
              ),
          ]);
        },
      ),
    );
  }
}
