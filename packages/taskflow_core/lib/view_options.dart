/// How a project or filter shows its tasks (FR-V3, FR-V6, FR-P11): layout,
/// grouping, sorting, and what to show. Pure Dart.
library;

import 'dart:convert';

import 'date_parser.dart';
import 'reminder.dart' show isOverdue;

enum ViewLayout { list, board, calendar }

enum Grouping { none, section, date, priority, label, project }

enum SortBy { manual, name, date, priority, added }

class ViewOptions {
  const ViewOptions({
    this.layout = ViewLayout.list,
    this.group,
    this.sort = SortBy.manual,
    this.showCompleted = false,
    this.showSubtasks = true,
    this.showDetails = true,
  });

  final ViewLayout layout;

  /// Null means "the view's own default" (sections for a project, none for a filter).
  final Grouping? group;
  final SortBy sort;
  final bool showCompleted;
  final bool showSubtasks;
  final bool showDetails;

  ViewOptions copyWith({
    ViewLayout? layout,
    Grouping? group,
    bool clearGroup = false,
    SortBy? sort,
    bool? showCompleted,
    bool? showSubtasks,
    bool? showDetails,
  }) =>
      ViewOptions(
        layout: layout ?? this.layout,
        group: clearGroup ? null : (group ?? this.group),
        sort: sort ?? this.sort,
        showCompleted: showCompleted ?? this.showCompleted,
        showSubtasks: showSubtasks ?? this.showSubtasks,
        showDetails: showDetails ?? this.showDetails,
      );

  String encode() => jsonEncode({
        'layout': layout.name,
        if (group != null) 'group': group!.name,
        'sort': sort.name,
        'showCompleted': showCompleted,
        'showSubtasks': showSubtasks,
        'showDetails': showDetails,
      });

  /// Reads stored options; anything missing or unreadable falls back to the default.
  static ViewOptions decode(String? json) {
    if (json == null || json.isEmpty) return const ViewOptions();
    try {
      final m = jsonDecode(json);
      if (m is! Map) return const ViewOptions();
      T pick<T extends Enum>(List<T> values, Object? v, T fallback) {
        for (final e in values) {
          if (e.name == v) return e;
        }
        return fallback;
      }

      final groupName = m['group'];
      return ViewOptions(
        layout: pick(ViewLayout.values, m['layout'], ViewLayout.list),
        group: groupName == null ? null : pick(Grouping.values, groupName, Grouping.none),
        sort: pick(SortBy.values, m['sort'], SortBy.manual),
        showCompleted: m['showCompleted'] == true,
        showSubtasks: m['showSubtasks'] != false,
        showDetails: m['showDetails'] != false,
      );
    } catch (_) {
      return const ViewOptions();
    }
  }

  @override
  bool operator ==(Object other) => other is ViewOptions && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}

/// What grouping and sorting need to know about a task.
class TaskFacts {
  const TaskFacts({
    required this.id,
    required this.title,
    required this.projectId,
    this.sectionId,
    this.priority = 4,
    this.dueDate,
    this.dueTime,
    this.labelIds = const [],
    required this.createdAt,
    this.sortOrder = 0,
  });
  final String id;
  final String title;
  final String projectId;
  final String? sectionId;
  final int priority;
  final String? dueDate;
  final String? dueTime;
  final List<String> labelIds;
  final DateTime createdAt;
  final int sortOrder;
}

/// Names and order of things a group can be made of.
class GroupLookups {
  const GroupLookups({this.projects = const [], this.sections = const [], this.labels = const []});

  /// In display order.
  final List<({String id, String name})> projects;
  final List<({String id, String projectId, String name})> sections;
  final List<({String id, String name})> labels;
}

/// Identifies a group so a dropped card can be given that group's value.
class GroupKey {
  const GroupKey(this.kind, [this.value]);
  final Grouping kind;

  /// Section id, ISO date (or `overdue`), priority digit, label id or project id;
  /// null means "none" (no section, no date, no label).
  final String? value;

  @override
  bool operator ==(Object other) => other is GroupKey && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  /// Overdue cannot be given as a value by dropping a card on it.
  bool get acceptsDrops => !(kind == Grouping.date && value == 'overdue');
}

class TaskGroup<T> {
  TaskGroup(this.key, this.title, this.items);
  final GroupKey key;
  final String title;
  final List<T> items;
}

/// Groups [items] and orders each group by [sort].
List<TaskGroup<T>> groupAndSort<T>(
  List<T> items, {
  required TaskFacts Function(T) facts,
  required Grouping group,
  required SortBy sort,
  required DateTime now,
  GroupLookups lookups = const GroupLookups(),
  bool showEmptyColumns = false,
}) {
  int compare(T a, T b) {
    final x = facts(a), y = facts(b);
    int byDue() {
      if (x.dueDate == null && y.dueDate == null) return 0;
      if (x.dueDate == null) return 1;
      if (y.dueDate == null) return -1;
      final d = x.dueDate!.compareTo(y.dueDate!);
      if (d != 0) return d;
      if (x.dueTime == null && y.dueTime == null) return 0;
      if (x.dueTime == null) return 1;
      if (y.dueTime == null) return -1;
      return x.dueTime!.compareTo(y.dueTime!);
    }

    int result;
    switch (sort) {
      case SortBy.manual:
        result = x.sortOrder.compareTo(y.sortOrder);
      case SortBy.name:
        result = x.title.toLowerCase().compareTo(y.title.toLowerCase());
      case SortBy.date:
        result = byDue();
        if (result == 0) result = x.priority.compareTo(y.priority);
      case SortBy.priority:
        result = x.priority.compareTo(y.priority);
        if (result == 0) result = byDue();
      case SortBy.added:
        result = x.createdAt.compareTo(y.createdAt);
    }
    if (result != 0) return result;
    final c = x.createdAt.compareTo(y.createdAt);
    return c != 0 ? c : x.id.compareTo(y.id);
  }

  List<T> sorted(List<T> xs) => [...xs]..sort(compare);

  final groups = <GroupKey, TaskGroup<T>>{};
  final order = <GroupKey>[];
  TaskGroup<T> bucket(GroupKey key, String title) {
    final g = groups[key];
    if (g != null) return g;
    final created = TaskGroup<T>(key, title, []);
    groups[key] = created;
    order.add(key);
    return created;
  }

  String name(Iterable<({String id, String name})> xs, String id, String fallback) {
    for (final x in xs) {
      if (x.id == id) return x.name;
    }
    return fallback;
  }

  final today = formatDate(dateOnly(now));
  final tomorrow = formatDate(dateOnly(now).add(const Duration(days: 1)));

  switch (group) {
    case Grouping.none:
      bucket(const GroupKey(Grouping.none), '').items.addAll(items);
    case Grouping.section:
      // Tasks without a section come first, then each section in order.
      bucket(const GroupKey(Grouping.section), 'No section');
      final multiProject = items.map((i) => facts(i).projectId).toSet().length > 1;
      for (final s in lookups.sections) {
        final title = multiProject ? '${name(lookups.projects, s.projectId, '')} · ${s.name}' : s.name;
        if (showEmptyColumns || items.any((i) => facts(i).sectionId == s.id)) bucket(GroupKey(Grouping.section, s.id), title);
      }
      for (final i in items) {
        final f = facts(i);
        final key = GroupKey(Grouping.section, f.sectionId);
        (groups[key] ?? bucket(const GroupKey(Grouping.section), 'No section')).items.add(i);
      }
    case Grouping.date:
      for (final i in items) {
        final f = facts(i);
        if (f.dueDate == null) continue;
        final late = isOverdue(dueDate: f.dueDate, dueTime: f.dueTime, now: now);
        if (late) bucket(const GroupKey(Grouping.date, 'overdue'), 'Overdue').items.add(i);
      }
      final dated = <String>{
        for (final i in items)
          if (facts(i).dueDate != null && !isOverdue(dueDate: facts(i).dueDate, dueTime: facts(i).dueTime, now: now)) facts(i).dueDate!,
      }.toList()
        ..sort();
      for (final d in dated) {
        final title = d == today ? 'Today' : (d == tomorrow ? 'Tomorrow' : d);
        final g = bucket(GroupKey(Grouping.date, d), title);
        g.items.addAll(items.where((i) {
          final f = facts(i);
          return f.dueDate == d && !isOverdue(dueDate: f.dueDate, dueTime: f.dueTime, now: now);
        }));
      }
      final none = items.where((i) => facts(i).dueDate == null).toList();
      if (none.isNotEmpty || showEmptyColumns) bucket(const GroupKey(Grouping.date), 'No date').items.addAll(none);
    case Grouping.priority:
      for (var p = 1; p <= 4; p++) {
        final g = bucket(GroupKey(Grouping.priority, '$p'), p == 4 ? 'No priority' : 'Priority $p');
        g.items.addAll(items.where((i) => facts(i).priority == p));
      }
    case Grouping.label:
      for (final l in lookups.labels) {
        final matching = items.where((i) => facts(i).labelIds.contains(l.id)).toList();
        if (matching.isNotEmpty || showEmptyColumns) bucket(GroupKey(Grouping.label, l.id), l.name).items.addAll(matching);
      }
      final none = items.where((i) => facts(i).labelIds.isEmpty).toList();
      if (none.isNotEmpty || showEmptyColumns) bucket(const GroupKey(Grouping.label), 'No label').items.addAll(none);
    case Grouping.project:
      for (final p in lookups.projects) {
        final matching = items.where((i) => facts(i).projectId == p.id).toList();
        if (matching.isNotEmpty || showEmptyColumns) bucket(GroupKey(Grouping.project, p.id), p.name).items.addAll(matching);
      }
  }

  final result = [for (final k in order) groups[k]!];
  // Drop empty groups except the ones that act as drop targets or that were asked for.
  final keep = result.where((g) {
    if (g.items.isNotEmpty || showEmptyColumns) return true;
    if (group == Grouping.section && g.key.value == null) return false;
    return group == Grouping.priority; // priority columns always show for a board
  }).toList();
  for (final g in keep) {
    final sortedItems = sorted(g.items);
    g.items
      ..clear()
      ..addAll(sortedItems);
  }
  return keep;
}
