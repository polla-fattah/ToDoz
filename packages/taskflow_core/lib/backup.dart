/// Plain data records for backups and the 1.0 import (FR-X1, A5).
///
/// These are independent of the database so a backup can be validated before
/// any existing data is touched.
library;

import 'dart:convert';

import 'date_parser.dart';
import 'location.dart';
import 'reminder.dart';

const inboxId = 'inbox';

class ProjectRec {
  ProjectRec({
    required this.id,
    required this.name,
    required this.color,
    this.parentId,
    this.isFavorite = false,
    this.isArchived = false,
    this.sortOrder = 0,
    this.viewOptions,
  });
  final String id;
  final String name;
  final int color; // 0xAARRGGBB
  final String? parentId;
  final bool isFavorite;
  final bool isArchived;
  final int sortOrder;
  final String? viewOptions; // JSON, see ViewOptions

  bool get isInbox => id == inboxId;

  Map<String, Object?> toJson() => {
        'id': id, 'name': name, 'color': color, 'parentId': parentId,
        'isFavorite': isFavorite, 'isArchived': isArchived, 'sortOrder': sortOrder,
        'viewOptions': viewOptions,
      };
}

class SectionRec {
  SectionRec({
    required this.id,
    required this.projectId,
    required this.name,
    this.sortOrder = 0,
    this.isCollapsed = false,
    this.isArchived = false,
  });
  final String id;
  final String projectId;
  final String name;
  final int sortOrder;
  final bool isCollapsed;
  final bool isArchived;

  Map<String, Object?> toJson() => {
        'id': id, 'projectId': projectId, 'name': name, 'sortOrder': sortOrder,
        'isCollapsed': isCollapsed, 'isArchived': isArchived,
      };
}

class LabelRec {
  LabelRec({
    required this.id,
    required this.name,
    required this.color,
    this.isFavorite = false,
    this.sortOrder = 0,
  });
  final String id;
  final String name;
  final int color;
  final bool isFavorite;
  final int sortOrder;

  Map<String, Object?> toJson() => {
        'id': id, 'name': name, 'color': color,
        'isFavorite': isFavorite, 'sortOrder': sortOrder,
      };
}

class TaskRec {
  TaskRec({
    required this.id,
    required this.title,
    required this.projectId,
    this.description = '',
    this.sectionId,
    this.parentId,
    this.priority = 4,
    this.dueDate,
    this.dueTime,
    this.recurrence,
    this.deadline,
    this.durationMinutes,
    this.completedAt,
    this.sortOrder = 0,
    this.isCollapsed = false,
    this.labelIds = const [],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
  final String id;
  final String title;
  final String description;
  final String projectId;
  final String? sectionId;
  final String? parentId;
  final int priority;
  final String? dueDate; // YYYY-MM-DD
  final String? dueTime; // HH:MM
  final String? recurrence; // the repeat phrase as typed
  final String? deadline; // YYYY-MM-DD
  final int? durationMinutes;
  final DateTime? completedAt;
  final int sortOrder;
  final bool isCollapsed;
  final List<String> labelIds;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id, 'title': title, 'description': description,
        'projectId': projectId, 'sectionId': sectionId, 'parentId': parentId,
        'priority': priority, 'dueDate': dueDate, 'dueTime': dueTime,
        'recurrence': recurrence, 'deadline': deadline, 'durationMinutes': durationMinutes,
        'completedAt': completedAt?.toUtc().toIso8601String(),
        'sortOrder': sortOrder, 'isCollapsed': isCollapsed,
        'labelIds': labelIds, 'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

class CommentRec {
  CommentRec({
    required this.id,
    required this.taskId,
    required this.body,
    required this.createdAt,
  });
  final String id;
  final String taskId;
  final String body;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id, 'taskId': taskId, 'body': body,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

class FilterRec {
  FilterRec({
    required this.id,
    required this.name,
    required this.query,
    required this.color,
    this.isFavorite = false,
    this.sortOrder = 0,
    this.viewOptions,
  });
  final String id;
  final String name;
  final String query;
  final int color;
  final bool isFavorite;
  final int sortOrder;
  final String? viewOptions;

  Map<String, Object?> toJson() => {
        'id': id, 'name': name, 'query': query, 'color': color, 'isFavorite': isFavorite,
        'sortOrder': sortOrder, 'viewOptions': viewOptions,
      };
}

class ReminderRec {
  ReminderRec({required this.id, required this.taskId, required this.spec});
  final String id;
  final String taskId;
  final String spec; // `14:00` or `30m`

  Map<String, Object?> toJson() => {'id': id, 'taskId': taskId, 'spec': spec};
}

class CompletionRec {
  CompletionRec({required this.id, required this.taskId, required this.completedAt, this.dueDate, this.dueTime});
  final String id;
  final String taskId;
  final DateTime completedAt;
  final String? dueDate;
  final String? dueTime;

  Map<String, Object?> toJson() => {
        'id': id, 'taskId': taskId, 'completedAt': completedAt.toUtc().toIso8601String(),
        'dueDate': dueDate, 'dueTime': dueTime,
      };
}

class ProjectCommentRec {
  ProjectCommentRec({required this.id, required this.projectId, required this.body, required this.createdAt});
  final String id;
  final String projectId;
  final String body;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id, 'projectId': projectId, 'body': body, 'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

/// Everything needed to rebuild the app's data, plus its settings.
class Bundle {
  Bundle({
    required this.projects,
    required this.sections,
    required this.labels,
    required this.tasks,
    required this.comments,
    this.reminders = const [],
    this.places = const [],
    this.locationReminders = const [],
    this.completions = const [],
    this.projectComments = const [],
    this.filters = const [],
    this.settings = const {},
    this.sourceVersion = 2,
  });

  /// Format of the file this came from: 1 for a TaskFlow 1.0 backup, else 2.
  final int sourceVersion;
  final List<ProjectRec> projects;
  final List<SectionRec> sections;
  final List<LabelRec> labels;
  final List<TaskRec> tasks;
  final List<CommentRec> comments;
  final List<ReminderRec> reminders;
  final List<PlaceRec> places;
  final List<LocationReminderRec> locationReminders;
  final List<CompletionRec> completions;
  final List<ProjectCommentRec> projectComments;
  final List<FilterRec> filters;
  final Map<String, String> settings;

  /// Backup format 2 (1.0 used `version: 1`).
  String toJsonString() => const JsonEncoder.withIndent(' ').convert({
        'format': 'taskflow-backup',
        'version': 2,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'settings': settings,
        'projects': projects.map((e) => e.toJson()).toList(),
        'sections': sections.map((e) => e.toJson()).toList(),
        'labels': labels.map((e) => e.toJson()).toList(),
        'tasks': tasks.map((e) => e.toJson()).toList(),
        'comments': comments.map((e) => e.toJson()).toList(),
        'reminders': reminders.map((e) => e.toJson()).toList(),
        'places': [for (final p in places) {'id': p.id, 'name': p.name, 'latitude': p.latitude, 'longitude': p.longitude, 'radiusMeters': p.radiusMeters}],
        'locationReminders': [for (final r in locationReminders) {'id': r.id, 'taskId': r.taskId, 'placeId': r.placeId, 'kind': r.trigger.name}],
        'completions': completions.map((e) => e.toJson()).toList(),
        'projectComments': projectComments.map((e) => e.toJson()).toList(),
        'filters': filters.map((e) => e.toJson()).toList(),
      });

  /// Parses a backup of either format (1.0 `version: 1` or 2.0 `version: 2`).
  /// Throws [FormatException] without side effects if it is invalid.
  static Bundle parse(String raw, {DateTime? now}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('Not valid JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Backup must be a JSON object');
    }
    final version = decoded['version'];
    if (version == 1) return _fromV1(decoded, now ?? DateTime.now());
    if (version == 2 && decoded['format'] == 'taskflow-backup') {
      return _fromV2(decoded);
    }
    throw const FormatException('Unknown backup version');
  }
}

// ---------------------------------------------------------------------------
// Version 2
// ---------------------------------------------------------------------------

Never _bad(String why) => throw FormatException(why);

T _as<T>(Object? v, String what) => v is T ? v : _bad('Invalid $what');

Bundle _fromV2(Map<String, Object?> j) {
  List<Map<String, Object?>> list(String key) =>
      _as<List>(j[key] ?? const [], key).map((e) => _as<Map<String, Object?>>(e, key)).toList();

  final projects = list('projects')
      .map((p) => ProjectRec(
            id: _as<String>(p['id'], 'project id'),
            name: _as<String>(p['name'], 'project name'),
            color: _as<int>(p['color'], 'project color'),
            parentId: p['parentId'] as String?,
            isFavorite: p['isFavorite'] == true,
            isArchived: p['isArchived'] == true,
            sortOrder: (p['sortOrder'] as int?) ?? 0,
            viewOptions: p['viewOptions'] as String?,
          ))
      .toList();
  if (!projects.any((p) => p.id == inboxId)) _bad('Backup has no Inbox');
  final sections = list('sections')
      .map((s) => SectionRec(
            id: _as<String>(s['id'], 'section id'),
            projectId: _as<String>(s['projectId'], 'section project'),
            name: _as<String>(s['name'], 'section name'),
            sortOrder: (s['sortOrder'] as int?) ?? 0,
            isCollapsed: s['isCollapsed'] == true,
            isArchived: s['isArchived'] == true,
          ))
      .toList();
  final labels = list('labels')
      .map((l) => LabelRec(
            id: _as<String>(l['id'], 'label id'),
            name: _as<String>(l['name'], 'label name'),
            color: _as<int>(l['color'], 'label color'),
            isFavorite: l['isFavorite'] == true,
            sortOrder: (l['sortOrder'] as int?) ?? 0,
          ))
      .toList();
  final tasks = list('tasks').map((t) {
    final due = t['dueDate'] as String?;
    if (due != null && parseIsoDate(due) == null) _bad('Invalid due date');
    final priority = _as<int>(t['priority'] ?? 4, 'priority');
    if (priority < 1 || priority > 4) _bad('Invalid priority');
    final dueTime = t['dueTime'] as String?;
    if (dueTime != null && parseClock(dueTime) == null) _bad('Invalid due time');
    final deadline = t['deadline'] as String?;
    if (deadline != null && parseIsoDate(deadline) == null) _bad('Invalid deadline');
    final duration = t['durationMinutes'] as int?;
    if (duration != null && (duration < 1 || duration > 14400)) _bad('Invalid duration');
    return TaskRec(
      id: _as<String>(t['id'], 'task id'),
      title: _as<String>(t['title'], 'task title'),
      description: (t['description'] as String?) ?? '',
      projectId: _as<String>(t['projectId'], 'task project'),
      sectionId: t['sectionId'] as String?,
      parentId: t['parentId'] as String?,
      priority: priority,
      dueDate: due,
      dueTime: dueTime,
      recurrence: t['recurrence'] as String?,
      deadline: deadline,
      durationMinutes: duration,
      completedAt: t['completedAt'] == null ? null : DateTime.parse(t['completedAt'] as String),
      sortOrder: (t['sortOrder'] as int?) ?? 0,
      isCollapsed: t['isCollapsed'] == true,
      labelIds: (t['labelIds'] as List? ?? const []).cast<String>(),
      createdAt: t['createdAt'] == null ? null : DateTime.parse(t['createdAt'] as String),
    );
  }).toList();
  final comments = list('comments')
      .map((c) => CommentRec(
            id: _as<String>(c['id'], 'comment id'),
            taskId: _as<String>(c['taskId'], 'comment task'),
            body: _as<String>(c['body'], 'comment body'),
            createdAt: DateTime.parse(_as<String>(c['createdAt'], 'comment time')),
          ))
      .toList();

  final reminders = list('reminders')
      .map((r) => ReminderRec(
            id: _as<String>(r['id'], 'reminder id'),
            taskId: _as<String>(r['taskId'], 'reminder task'),
            spec: _as<String>(r['spec'], 'reminder spec'),
          ))
      .toList();
  final places = list('places').map((p) {
    final lat = (p['latitude'] as num?)?.toDouble(), lon = (p['longitude'] as num?)?.toDouble();
    if (lat == null || lon == null || !validCoordinates(lat, lon)) _bad('Invalid place');
    return PlaceRec(
      id: _as<String>(p['id'], 'place id'),
      name: _as<String>(p['name'], 'place name'),
      latitude: lat,
      longitude: lon,
      radiusMeters: clampRadius((p['radiusMeters'] as int?) ?? defaultRadiusMeters),
    );
  }).toList();
  final locationReminders = list('locationReminders')
      .map((r) => LocationReminderRec(
            id: _as<String>(r['id'], 'location reminder id'),
            taskId: _as<String>(r['taskId'], 'location reminder task'),
            placeId: _as<String>(r['placeId'], 'location reminder place'),
            trigger: LocationTrigger.decode(r['kind'] as String?) ?? _bad('Invalid location reminder'),
          ))
      .toList();
  final completions = list('completions')
      .map((c) => CompletionRec(
            id: _as<String>(c['id'], 'completion id'),
            taskId: _as<String>(c['taskId'], 'completion task'),
            completedAt: DateTime.parse(_as<String>(c['completedAt'], 'completion time')),
            dueDate: c['dueDate'] as String?,
            dueTime: c['dueTime'] as String?,
          ))
      .toList();
  final projectComments = list('projectComments')
      .map((c) => ProjectCommentRec(
            id: _as<String>(c['id'], 'note id'),
            projectId: _as<String>(c['projectId'], 'note project'),
            body: _as<String>(c['body'], 'note body'),
            createdAt: DateTime.parse(_as<String>(c['createdAt'], 'note time')),
          ))
      .toList();

  final filters = list('filters')
      .map((f) => FilterRec(
            id: _as<String>(f['id'], 'filter id'),
            name: _as<String>(f['name'], 'filter name'),
            query: _as<String>(f['query'], 'filter query'),
            color: _as<int>(f['color'], 'filter color'),
            isFavorite: f['isFavorite'] == true,
            sortOrder: (f['sortOrder'] as int?) ?? 0,
            viewOptions: f['viewOptions'] as String?,
          ))
      .toList();

  _checkReferences(projects, sections, labels, tasks, comments);
  final taskIds = {for (final t in tasks) t.id};
  final projectIds = {for (final p in projects) p.id};
  for (final r in reminders) {
    if (!taskIds.contains(r.taskId)) _bad('Reminder task missing');
    if (ReminderSpec.decode(r.spec) == null) _bad('Invalid reminder');
  }
  final placeIds = {for (final p in places) p.id};
  for (final r in locationReminders) {
    if (!taskIds.contains(r.taskId)) _bad('Location reminder task missing');
    if (!placeIds.contains(r.placeId)) _bad('Location reminder place missing');
  }
  for (final c in completions) {
    if (!taskIds.contains(c.taskId)) _bad('Completion task missing');
  }
  for (final c in projectComments) {
    if (!projectIds.contains(c.projectId)) _bad('Note project missing');
  }
  final settings = (j['settings'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? <String, String>{};
  return Bundle(
    projects: projects, sections: sections, labels: labels,
    tasks: tasks, comments: comments, reminders: reminders, places: places, locationReminders: locationReminders, completions: completions,
    projectComments: projectComments, filters: filters, settings: settings,
  );
}

void _checkReferences(
  List<ProjectRec> projects,
  List<SectionRec> sections,
  List<LabelRec> labels,
  List<TaskRec> tasks,
  List<CommentRec> comments,
) {
  Set<String> ids(Iterable<String> xs, String what) {
    final s = <String>{};
    for (final x in xs) {
      if (!s.add(x)) _bad('Duplicate $what id');
    }
    return s;
  }

  final pids = ids(projects.map((p) => p.id), 'project');
  final sids = ids(sections.map((s) => s.id), 'section');
  final lids = ids(labels.map((l) => l.id), 'label');
  final tids = ids(tasks.map((t) => t.id), 'task');
  for (final p in projects) {
    if (p.parentId != null && !pids.contains(p.parentId)) _bad('Project parent missing');
  }
  for (final s in sections) {
    if (!pids.contains(s.projectId)) _bad('Section project missing');
  }
  for (final t in tasks) {
    if (!pids.contains(t.projectId)) _bad('Task project missing');
    if (t.sectionId != null && !sids.contains(t.sectionId)) _bad('Task section missing');
    if (t.parentId != null && !tids.contains(t.parentId)) _bad('Task parent missing');
    for (final l in t.labelIds) {
      if (!lids.contains(l)) _bad('Task label missing');
    }
  }
  for (final c in comments) {
    if (!tids.contains(c.taskId)) _bad('Comment task missing');
  }
}

// ---------------------------------------------------------------------------
// Version 1 (TaskFlow 1.0)
// ---------------------------------------------------------------------------

final _idPattern = RegExp(r'^[-a-zA-Z0-9_]+$');
final _hexColor = RegExp(r'^#[0-9a-fA-F]{6}$');

int _hexToArgb(String hex) => 0xFF000000 | int.parse(hex.substring(1), radix: 16);

int _stableInt(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}

/// Converts a 1.0 backup. Rules (documented in the SRS, A5):
///  * a project whose only section is "General" gets no sections, and its
///    tasks have no section (1.0 added "General" to every project);
///  * 1.0 checklist items become real sub-tasks;
///  * labels become label records, shared by name;
///  * 1.0 stored only a completion *date*, so the completion time is noon of
///    that day.
Bundle _fromV1(Map<String, Object?> j, DateTime now) {
  final rawProjects = _as<List>(j['projects'], 'projects');
  final rawTasks = _as<List>(j['tasks'], 'tasks');
  if (rawProjects.length > 500 || rawTasks.length > 50000) _bad('Backup too large');

  final projects = <ProjectRec>[];
  final sections = <SectionRec>[];
  final projectIdMap = <String, String>{}; // 1.0 id -> new id
  final sectionIdMap = <String, String?>{}; // "projectId|name" -> section id
  var order = 0;

  for (final rp in rawProjects) {
    final p = _as<Map<String, Object?>>(rp, 'project');
    final oldId = _as<String>(p['id'], 'project id');
    if (!_idPattern.hasMatch(oldId) || projectIdMap.containsKey(oldId)) _bad('Invalid project id');
    final name = _as<String>(p['name'], 'project name');
    final color = _as<String>(p['color'], 'project color');
    if (!_hexColor.hasMatch(color)) _bad('Invalid project color');
    final secs = _as<List>(p['sections'], 'sections');
    if (secs.isEmpty || !secs.every((s) => s is String)) _bad('Invalid sections');

    final newId = oldId == inboxId ? inboxId : 'p-${_stableInt(oldId)}-$order';
    projectIdMap[oldId] = newId;
    projects.add(ProjectRec(
      id: newId, name: name, color: _hexToArgb(color), sortOrder: order++,
    ));

    final names = secs.cast<String>();
    final isDefaultOnly = names.length == 1 && names.first == 'General';
    var sOrder = 0;
    for (final sName in names) {
      if (isDefaultOnly) {
        sectionIdMap['$oldId|$sName'] = null;
      } else {
        final sid = 's-$newId-$sOrder';
        sections.add(SectionRec(id: sid, projectId: newId, name: sName, sortOrder: sOrder));
        sectionIdMap['$oldId|$sName'] = sid;
        sOrder++;
      }
    }
  }
  if (!projectIdMap.containsKey(inboxId)) _bad('Backup has no Inbox');

  final labelByName = <String, LabelRec>{};
  LabelRec labelFor(String name) => labelByName.putIfAbsent(
        name,
        () => LabelRec(
          id: 'l-${labelByName.length}-${_stableInt(name)}',
          name: name,
          color: 0xFF8D75B4,
          sortOrder: labelByName.length,
        ),
      );

  final tasks = <TaskRec>[];
  final comments = <CommentRec>[];
  final seen = <String>{};
  var tOrder = 0;
  for (final rt in rawTasks) {
    final t = _as<Map<String, Object?>>(rt, 'task');
    final oldId = _as<String>(t['id'], 'task id');
    if (!_idPattern.hasMatch(oldId) || !seen.add(oldId)) _bad('Invalid task id');
    final title = _as<String>(t['title'], 'task title');
    final description = _as<String>(t['description'], 'task description');
    final oldProject = _as<String>(t['projectId'], 'task project');
    final projectId = projectIdMap[oldProject] ?? _bad('Task project missing');
    final sectionName = _as<String>(t['section'], 'task section');
    final priority = _as<int>(t['priority'], 'priority');
    if (priority < 1 || priority > 4) _bad('Invalid priority');
    final done = _as<bool>(t['completed'], 'completed');
    final due = _as<String>(t['due'], 'due');
    if (due.isNotEmpty && parseIsoDate(due) == null) _bad('Invalid due date');
    final labels = _as<List>(t['labels'], 'labels');
    if (!labels.every((l) => l is String)) _bad('Invalid labels');
    final subtasks = _as<List>(t['subtasks'], 'subtasks');
    final rawComments = _as<List>(t['comments'], 'comments');

    DateTime? completedAt;
    if (done) {
      final c = t['completedAt'];
      final day = (c is String && c.length >= 10) ? parseIsoDate(c.substring(0, 10)) : null;
      completedAt = day != null ? DateTime(day.year, day.month, day.day, 12) : now;
    }

    // Unknown or default-only section names leave the task without a section.
    final sectionId = sectionIdMap['$oldProject|$sectionName'];
    final labelIds = (labels.cast<String>()).where((l) => l.trim().isNotEmpty).map((l) => labelFor(l.trim().toLowerCase()).id).toSet().toList();
    final taskId = 't-$oldId';
    tasks.add(TaskRec(
      id: taskId,
      title: title,
      description: description,
      projectId: projectId,
      sectionId: sectionId,
      priority: priority,
      dueDate: due.isEmpty ? null : due,
      completedAt: completedAt,
      sortOrder: tOrder++,
      labelIds: labelIds,
    ));

    var subOrder = 0;
    for (final rs in subtasks) {
      final s = _as<Map<String, Object?>>(rs, 'subtask');
      final subTitle = _as<String>(s['title'], 'subtask title');
      final subDone = _as<bool>(s['done'], 'subtask done');
      tasks.add(TaskRec(
        id: '$taskId-sub$subOrder',
        title: subTitle,
        projectId: projectId,
        sectionId: sectionId,
        parentId: taskId,
        priority: 4,
        completedAt: subDone ? (completedAt ?? now) : null,
        sortOrder: subOrder++,
      ));
    }

    var cOrder = 0;
    for (final rc in rawComments) {
      final c = _as<Map<String, Object?>>(rc, 'comment');
      final text = _as<String>(c['text'], 'comment text');
      final at = DateTime.tryParse(_as<String>(c['at'], 'comment time')) ?? now;
      comments.add(CommentRec(id: '$taskId-c${cOrder++}', taskId: taskId, body: text, createdAt: at));
    }
  }

  final settings = <String, String>{
    'themeMode': j['dark'] == true ? 'dark' : 'light',
    'dailyGoal': '${((j['goal'] as num?)?.toInt() ?? 5).clamp(1, 100)}',
  };
  return Bundle(
    projects: projects,
    sections: sections,
    labels: labelByName.values.toList(),
    tasks: tasks,
    comments: comments,
    settings: settings,
    sourceVersion: 1,
  );
}
