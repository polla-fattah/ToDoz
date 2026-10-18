import 'dart:async';

import 'package:flutter/material.dart';

import '../core/backup.dart' show inboxId;
import '../data/database.dart';
import '../data/repository.dart';

/// Live copies of the small tables (projects, sections, labels, label links)
/// that every screen needs to show names and colors. One subscription each,
/// shared by the whole app.
class Catalog extends ChangeNotifier {
  Catalog(this.repo) {
    _subs = [
      repo.watchProjects().listen((v) => _set(() => projects = v)),
      repo.watchAllSections().listen((v) => _set(() => sections = v)),
      repo.watchLabels().listen((v) => _set(() => labels = v)),
      repo.watchLabelLinks().listen((v) => _set(() => links = v)),
      repo.watchSubtaskCounts().listen((v) => _set(() => subtaskCounts = v)),
      repo.watchSetting('themeMode').listen((v) => _set(() => themeMode = switch (v) {
            'dark' => ThemeMode.dark,
            'light' => ThemeMode.light,
            _ => ThemeMode.system,
          })),
      repo.watchSetting('dailyGoal').listen((v) => _set(() => dailyGoal = (int.tryParse(v ?? '') ?? 5).clamp(1, 100))),
    ];
  }

  final Repo repo;
  late final List<StreamSubscription<Object?>> _subs;
  bool _disposed = false;

  List<Project> projects = const [];
  List<Section> sections = const [];
  List<Label> labels = const [];
  List<TaskLabel> links = const [];
  Map<String, (int, int)> subtaskCounts = const {};
  ThemeMode themeMode = ThemeMode.system;
  int dailyGoal = 5;

  void _set(void Function() f) {
    if (_disposed) return;
    f();
    notifyListeners();
  }

  Project? project(String id) {
    for (final p in projects) {
      if (p.id == id) return p;
    }
    return null;
  }

  Project get inbox => project(inboxId) ?? projects.first;

  Section? section(String? id) {
    if (id == null) return null;
    for (final s in sections) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<Section> sectionsOf(String projectId) =>
      sections.where((s) => s.projectId == projectId && !s.isArchived).toList();

  Label? label(String id) {
    for (final l in labels) {
      if (l.id == id) return l;
    }
    return null;
  }

  List<Label> labelsFor(String taskId) => [
        for (final l in links.where((l) => l.taskId == taskId))
          if (label(l.labelId) != null) label(l.labelId)!,
      ];

  List<Project> childrenOf(String? parentId) =>
      projects.where((p) => p.parentId == parentId && p.id != inboxId).toList();

  /// Projects in tree order with their indent level, skipping the Inbox.
  List<(Project, int)> projectTree() {
    final out = <(Project, int)>[];
    void walk(String? parent, int depth) {
      for (final p in childrenOf(parent)) {
        out.add((p, depth));
        walk(p.id, depth + 1);
      }
    }

    walk(null, 0);
    return out;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

/// Gives widgets the repository and catalog without a state-management package.
class AppScope extends InheritedNotifier<Catalog> {
  const AppScope({super.key, required Catalog catalog, required super.child}) : super(notifier: catalog);

  static Catalog of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static Repo repoOf(BuildContext context) => of(context).repo;
}
