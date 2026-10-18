import '../data/database.dart';

/// A task and how deep it sits in the list being shown.
class TreeRow {
  const TreeRow(this.task, this.depth, {required this.hasChildren, required this.collapsed});
  final Task task;
  final int depth;
  final bool hasChildren;
  final bool collapsed;
}

/// Orders a flat task list as a tree: each task followed by its sub-tasks,
/// indented by depth. A task whose parent is not in [tasks] (completed,
/// filtered out, or in another view) is shown at the top level instead of
/// vanishing. Sub-tasks of a collapsed task are hidden. Siblings keep the
/// order they had in [tasks].
List<TreeRow> flattenTasks(List<Task> tasks) {
  final ids = {for (final t in tasks) t.id};
  final children = <String, List<Task>>{};
  final roots = <Task>[];
  for (final t in tasks) {
    final p = t.parentId;
    if (p != null && ids.contains(p)) {
      children.putIfAbsent(p, () => []).add(t);
    } else {
      roots.add(t);
    }
  }
  final out = <TreeRow>[];
  final seen = <String>{};
  void walk(Task t, int depth) {
    if (!seen.add(t.id)) return; // guards against a parent loop in bad data
    final kids = children[t.id] ?? const [];
    out.add(TreeRow(t, depth, hasChildren: kids.isNotEmpty, collapsed: t.isCollapsed));
    if (t.isCollapsed) return;
    for (final k in kids) {
      walk(k, depth + 1);
    }
  }

  for (final r in roots) {
    walk(r, 0);
  }
  return out;
}
