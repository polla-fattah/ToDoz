/// A person's tasks, projects and the rest, read from the synced fields and
/// changed by writing fields back (REST API, webhooks, calendar link).
///
/// The app's database is the model; the server only stores its fields. This
/// file knows how those fields spell a task (dates as `YYYY-MM-DD`, times in
/// whole seconds since 1970, labels as `task|label` link rows) so outside
/// callers can work with plain objects.
library;

import 'dart:math';

import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/quick_add.dart';
import 'package:taskflow_core/recurrence.dart';
import 'package:taskflow_core/reminder.dart';
import 'package:taskflow_core/sync.dart';

import 'store.dart';

/// A request the person made that cannot be done; [message] says why.
class ModelError implements Exception {
  ModelError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

const inboxId = 'inbox';
const maxTaskDepth = 4;

typedef Rows = Map<String, Map<String, Object?>>;

String _iso(Object? seconds) => seconds is int ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toIso8601String() : '';

/// A read-only view of one person's data at one moment, with the writes that
/// keep it consistent.
class UserModel {
  UserModel(this.store, this.userId, {this.source = 'api'}) : _data = store.snapshot(userId);

  final Store store;
  final String userId;
  final String source;
  Map<String, Rows> _data;

  Rows table(String name) => _data.putIfAbsent(name, () => {});

  void reload() => _data = store.snapshot(userId);

  DateTime get now => store.now;
  int get _nowSec => now.millisecondsSinceEpoch ~/ 1000;

  static final _rand = Random.secure();

  static String newId() {
    String h(int n) => n.toRadixString(16).padLeft(2, '0');
    final b = List<int>.generate(16, (_) => _rand.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final s = b.map(h).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  bool _live(Map<String, Object?>? r) => r != null && r['deleted_at'] == null;

  // ---------------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------------

  Map<String, Object?>? _row(String table, String id) => this.table(table)[id];

  List<String> labelNamesOf(String taskId) {
    final out = <String>[];
    for (final key in table('task_labels').keys) {
      if (key.startsWith('$taskId|')) {
        final l = _row('labels', key.substring(taskId.length + 1));
        if (_live(l)) out.add(l!['name'] as String);
      }
    }
    return out..sort();
  }

  Map<String, Object?> taskView(String id) {
    final t = _row('tasks', id)!;
    final due = t['due_date'] as String?;
    return {
      'id': id,
      'title': t['title'],
      'content': t['title'],
      'description': t['description'] ?? '',
      'project_id': t['project_id'],
      'section_id': t['section_id'],
      'parent_id': t['parent_id'],
      'priority': t['priority'] ?? 4,
      'labels': labelNamesOf(id),
      'due': due == null ? null : {'date': due, 'time': t['due_time'], 'recurrence': t['recurrence']},
      'deadline': t['deadline'],
      'duration_minutes': t['duration_minutes'],
      'is_completed': t['completed_at'] != null,
      'completed_at': t['completed_at'] == null ? null : _iso(t['completed_at']),
      'created_at': _iso(t['created_at']),
      'updated_at': _iso(t['updated_at']),
      'order': t['sort_order'] ?? 0,
    };
  }

  /// Open tasks (and completed ones with [includeCompleted]) that are not in the trash.
  List<Map<String, Object?>> tasks({String? projectId, String? sectionId, String? parentId, String? label, bool includeCompleted = false, String? dueDate}) {
    final out = <Map<String, Object?>>[];
    final ids = table('tasks').keys.toList()..sort((a, b) => ((table('tasks')[a]!['sort_order'] as int?) ?? 0).compareTo((table('tasks')[b]!['sort_order'] as int?) ?? 0));
    for (final id in ids) {
      final t = table('tasks')[id]!;
      if (!_live(t)) continue;
      if (!includeCompleted && t['completed_at'] != null) continue;
      if (projectId != null && t['project_id'] != projectId) continue;
      if (sectionId != null && t['section_id'] != sectionId) continue;
      if (parentId != null && t['parent_id'] != parentId) continue;
      if (dueDate != null && t['due_date'] != dueDate) continue;
      if (label != null && !labelNamesOf(id).map((l) => l.toLowerCase()).contains(label.toLowerCase())) continue;
      out.add(taskView(id));
    }
    return out;
  }

  bool taskExists(String id) => _live(_row('tasks', id));
  bool projectExists(String id) => id == inboxId || _live(_row('projects', id));

  Map<String, Object?> projectView(String id) {
    final p = _row('projects', id) ?? const {};
    return {
      'id': id,
      'name': id == inboxId ? 'Inbox' : p['name'],
      'color': p['color'],
      'parent_id': p['parent_id'],
      'is_favorite': p['is_favorite'] == 1,
      'is_archived': p['is_archived'] == 1,
      'is_inbox': id == inboxId,
      'order': p['sort_order'] ?? 0,
    };
  }

  List<Map<String, Object?>> projects() => [
        for (final id in table('projects').keys)
          if (_live(table('projects')[id])) projectView(id),
        if (table('projects')[inboxId] == null) projectView(inboxId),
      ];

  List<Map<String, Object?>> sections({String? projectId}) => [
        for (final e in table('sections').entries)
          if (_live(e.value) && (projectId == null || e.value['project_id'] == projectId))
            {'id': e.key, 'project_id': e.value['project_id'], 'name': e.value['name'], 'order': e.value['sort_order'] ?? 0, 'is_archived': e.value['is_archived'] == 1},
      ];

  List<Map<String, Object?>> labels() => [
        for (final e in table('labels').entries)
          if (_live(e.value)) {'id': e.key, 'name': e.value['name'], 'color': e.value['color'], 'is_favorite': e.value['is_favorite'] == 1},
      ];

  List<Map<String, Object?>> comments(String taskId) => [
        for (final e in table('comments').entries)
          if (_live(e.value) && e.value['task_id'] == taskId)
            {'id': e.key, 'task_id': taskId, 'content': e.value['body'], 'posted_at': _iso(e.value['created_at'])},
      ]..sort((a, b) => (a['posted_at'] as String).compareTo(b['posted_at'] as String));

  List<Map<String, Object?>> filters() => [
        for (final e in table('filters').entries)
          if (_live(e.value)) {'id': e.key, 'name': e.value['name'], 'query': e.value['query'], 'color': e.value['color'], 'is_favorite': e.value['is_favorite'] == 1},
      ];

  List<Map<String, Object?>> reminders(String taskId) => [
        for (final e in table('reminders').entries)
          if (_live(e.value) && e.value['task_id'] == taskId) {'id': e.key, 'task_id': taskId, 'spec': e.value['spec']},
      ];

  /// Completions, newest first, optionally only those on or after [since].
  List<Map<String, Object?>> completed({DateTime? since, DateTime? until, int limit = 200}) {
    final out = <Map<String, Object?>>[];
    for (final e in table('completions').entries) {
      final at = e.value['completed_at'] as int?;
      if (at == null) continue;
      final when = DateTime.fromMillisecondsSinceEpoch(at * 1000, isUtc: true);
      if (since != null && when.isBefore(since)) continue;
      if (until != null && !when.isBefore(until)) continue;
      final task = _row('tasks', e.value['task_id'] as String);
      out.add({
        'id': e.key,
        'task_id': e.value['task_id'],
        'title': task?['title'],
        'project_id': task?['project_id'],
        'completed_at': when.toIso8601String(),
        'due_date': e.value['due_date'],
        'due_time': e.value['due_time'],
      });
    }
    out.sort((a, b) => (b['completed_at'] as String).compareTo(a['completed_at'] as String));
    return out.take(limit).toList();
  }

  // ---------------------------------------------------------------------------
  // Checking what a caller sent
  // ---------------------------------------------------------------------------

  String _title(Object? v) {
    if (v is! String || v.trim().isEmpty) throw ModelError(400, 'A task needs a title');
    if (v.trim().length > 500) throw ModelError(400, 'Titles are limited to 500 characters');
    return v.trim();
  }

  String _name(Object? v, String what) {
    if (v is! String || v.trim().isEmpty) throw ModelError(400, 'A $what needs a name');
    if (v.trim().length > 200) throw ModelError(400, 'A $what name is limited to 200 characters');
    return v.trim();
  }

  void _checkWhen({String? date, String? time, String? recurrence, String? deadline}) {
    if (date != null && parseIsoDate(date) == null) throw ModelError(400, 'due_date must be YYYY-MM-DD');
    if (deadline != null && parseIsoDate(deadline) == null) throw ModelError(400, 'deadline must be YYYY-MM-DD');
    if (time != null) {
      if (parseClock(time) == null) throw ModelError(400, 'due_time must be HH:MM');
      if (date == null) throw ModelError(400, 'A time needs a due_date');
    }
    if (recurrence != null) {
      if (date == null) throw ModelError(400, 'A repeat needs a due_date');
      try {
        parseRecurrence(recurrence, now);
      } on RecurrenceException catch (e) {
        throw ModelError(400, 'Cannot read that repeat: ${e.message}');
      }
    }
  }

  int _taskDepth(String? parentId) {
    var depth = 0;
    var cursor = parentId;
    final seen = <String>{};
    while (cursor != null && seen.add(cursor)) {
      depth++;
      cursor = _row('tasks', cursor)?['parent_id'] as String?;
    }
    return depth;
  }

  int _nextOrder(String table, bool Function(Map<String, Object?>) inGroup) {
    var maxOrder = -1;
    for (final r in this.table(table).values) {
      if (_live(r) && inGroup(r)) {
        final o = r['sort_order'];
        if (o is int && o > maxOrder) maxOrder = o;
      }
    }
    return maxOrder + 1;
  }

  List<FieldEdit> _labelEdits(String taskId, List<String> names) {
    final edits = <FieldEdit>[];
    final wanted = <String>{};
    for (final raw in names) {
      final name = raw.trim().replaceFirst(RegExp(r'^[%@]'), '');
      if (name.isEmpty) continue;
      String? id;
      for (final e in table('labels').entries) {
        if (_live(e.value) && (e.value['name'] as String).toLowerCase() == name.toLowerCase()) id = e.key;
      }
      if (id == null) {
        id = newId();
        edits.addAll(_newLabel(id, name));
        // Later lookups in the same request see it.
        table('labels')[id] = {'name': name, 'deleted_at': null};
      }
      wanted.add(id);
    }
    final have = {
      for (final key in table('task_labels').keys)
        if (key.startsWith('$taskId|')) key.substring(taskId.length + 1),
    };
    for (final l in wanted.difference(have)) {
      edits.add(FieldEdit('task_labels', '$taskId|$l', presentColumn, true));
    }
    for (final l in have.difference(wanted)) {
      edits.add(FieldEdit('task_labels', '$taskId|$l', presentColumn, false));
    }
    return edits;
  }

  List<FieldEdit> _newLabel(String id, String name) => [
        FieldEdit('labels', id, presentColumn, true),
        FieldEdit('labels', id, 'name', name),
        FieldEdit('labels', id, 'color', 0xFF8D75B4),
        FieldEdit('labels', id, 'is_favorite', 0),
        FieldEdit('labels', id, 'sort_order', _nextOrder('labels', (_) => true)),
        FieldEdit('labels', id, 'created_at', _nowSec),
        FieldEdit('labels', id, 'updated_at', _nowSec),
      ];

  // ---------------------------------------------------------------------------
  // Tasks
  // ---------------------------------------------------------------------------

  /// Makes a task from [body] (title or content, description, project_id,
  /// section_id, parent_id, priority, labels, due_date, due_time, recurrence,
  /// deadline, duration_minutes). Returns the new task.
  Map<String, Object?> createTask(Map<String, Object?> body) {
    final title = _title(body['title'] ?? body['content']);
    var project = (body['project_id'] as String?) ?? inboxId;
    String? section = body['section_id'] as String?;
    final parent = body['parent_id'] as String?;
    if (parent != null) {
      final p = _row('tasks', parent);
      if (!_live(p)) throw ModelError(404, 'The parent task does not exist');
      if (_taskDepth(parent) + 1 > maxTaskDepth) throw ModelError(400, 'Sub-tasks go at most $maxTaskDepth levels deep');
      project = p!['project_id'] as String;
      section = p['section_id'] as String?;
    }
    if (!projectExists(project)) throw ModelError(404, 'The project does not exist');
    if (section != null && (!_live(_row('sections', section)) || _row('sections', section)!['project_id'] != project)) {
      throw ModelError(400, 'That section is not in that project');
    }
    final priority = body['priority'] ?? 4;
    if (priority is! int || priority < 1 || priority > 4) throw ModelError(400, 'priority must be 1 (urgent) to 4');
    final description = body['description'] ?? '';
    if (description is! String || description.length > 20000) throw ModelError(400, 'description must be text of at most 20000 characters');
    final date = body['due_date'] as String?, time = body['due_time'] as String?, rec = body['recurrence'] as String?, deadline = body['deadline'] as String?;
    _checkWhen(date: date, time: time, recurrence: rec, deadline: deadline);
    final dur = body['duration_minutes'];
    if (dur != null && (dur is! int || dur < 1 || dur > 14400)) throw ModelError(400, 'duration_minutes must be 1 to 14400');
    final labels = body['labels'];
    if (labels != null && (labels is! List || labels.any((l) => l is! String))) throw ModelError(400, 'labels must be a list of names');

    final id = newId();
    final stamp = _nowSec;
    final edits = <FieldEdit>[
      FieldEdit('tasks', id, presentColumn, true),
      FieldEdit('tasks', id, 'title', title),
      FieldEdit('tasks', id, 'description', description),
      FieldEdit('tasks', id, 'project_id', project),
      if (section != null) FieldEdit('tasks', id, 'section_id', section),
      if (parent != null) FieldEdit('tasks', id, 'parent_id', parent),
      FieldEdit('tasks', id, 'priority', priority),
      if (date != null) FieldEdit('tasks', id, 'due_date', date),
      if (time != null) FieldEdit('tasks', id, 'due_time', time),
      if (rec != null) FieldEdit('tasks', id, 'recurrence', rec),
      if (deadline != null) FieldEdit('tasks', id, 'deadline', deadline),
      if (dur != null) FieldEdit('tasks', id, 'duration_minutes', dur),
      FieldEdit('tasks', id, 'sort_order', _nextOrder('tasks', (r) => r['project_id'] == project && r['parent_id'] == parent)),
      FieldEdit('tasks', id, 'is_collapsed', 0),
      FieldEdit('tasks', id, 'created_at', stamp),
      FieldEdit('tasks', id, 'updated_at', stamp),
    ];
    table('tasks')[id] = {'title': title, 'project_id': project, 'deleted_at': null};
    if (labels is List) edits.addAll(_labelEdits(id, labels.cast<String>()));
    store.applyEdits(userId, source, edits);
    reload();
    return taskView(id);
  }

  /// Changes the fields present in [body] (same names as [createTask]; null clears a date, time, repeat, deadline or section).
  Map<String, Object?> updateTask(String id, Map<String, Object?> body) {
    final t = _row('tasks', id);
    if (!_live(t)) throw ModelError(404, 'No such task');
    final edits = <FieldEdit>[];
    void set(String col, Object? v) {
      if (t![col] != v) edits.add(FieldEdit('tasks', id, col, v));
    }

    if (body.containsKey('title') || body.containsKey('content')) set('title', _title(body['title'] ?? body['content']));
    if (body.containsKey('description')) {
      final d = body['description'];
      if (d is! String || d.length > 20000) throw ModelError(400, 'description must be text of at most 20000 characters');
      set('description', d);
    }
    if (body.containsKey('priority')) {
      final p = body['priority'];
      if (p is! int || p < 1 || p > 4) throw ModelError(400, 'priority must be 1 (urgent) to 4');
      set('priority', p);
    }
    final date = body.containsKey('due_date') ? body['due_date'] as String? : t!['due_date'] as String?;
    final time = body.containsKey('due_time') ? body['due_time'] as String? : (body.containsKey('due_date') && date == null ? null : t!['due_time'] as String?);
    final rec = body.containsKey('recurrence') ? body['recurrence'] as String? : (body.containsKey('due_date') && date == null ? null : t!['recurrence'] as String?);
    final deadline = body.containsKey('deadline') ? body['deadline'] as String? : t!['deadline'] as String?;
    if (body.containsKey('due_date') || body.containsKey('due_time') || body.containsKey('recurrence') || body.containsKey('deadline')) {
      _checkWhen(date: date, time: time, recurrence: rec, deadline: deadline);
      set('due_date', date);
      set('due_time', time);
      set('recurrence', rec);
      set('deadline', deadline);
    }
    if (body.containsKey('duration_minutes')) {
      final d = body['duration_minutes'];
      if (d != null && (d is! int || d < 1 || d > 14400)) throw ModelError(400, 'duration_minutes must be 1 to 14400');
      set('duration_minutes', d);
    }
    if (body.containsKey('project_id') || body.containsKey('section_id') || body.containsKey('parent_id')) {
      var project = body.containsKey('project_id') ? body['project_id'] as String? : t!['project_id'] as String;
      var section = body.containsKey('section_id') ? body['section_id'] as String? : (body.containsKey('project_id') ? null : t!['section_id'] as String?);
      var parent = body.containsKey('parent_id') ? body['parent_id'] as String? : (body.containsKey('project_id') ? null : t!['parent_id'] as String?);
      if (parent != null) {
        if (parent == id || _descendants(id).contains(parent)) throw ModelError(400, 'A task cannot go inside itself');
        final p = _row('tasks', parent);
        if (!_live(p)) throw ModelError(404, 'The parent task does not exist');
        project = p!['project_id'] as String;
        section = p['section_id'] as String?;
      }
      if (project == null || !projectExists(project)) throw ModelError(404, 'The project does not exist');
      if (section != null && (!_live(_row('sections', section)) || _row('sections', section)!['project_id'] != project)) {
        throw ModelError(400, 'That section is not in that project');
      }
      set('project_id', project);
      set('section_id', section);
      set('parent_id', parent);
      // Sub-tasks travel with their parent.
      for (final d in _descendants(id)) {
        final dr = _row('tasks', d)!;
        if (dr['project_id'] != project) edits.add(FieldEdit('tasks', d, 'project_id', project));
        if (dr['section_id'] != section) edits.add(FieldEdit('tasks', d, 'section_id', section));
      }
    }
    final labels = body['labels'];
    if (body.containsKey('labels')) {
      if (labels is! List || labels.any((l) => l is! String)) throw ModelError(400, 'labels must be a list of names');
      edits.addAll(_labelEdits(id, labels.cast<String>()));
    }
    if (edits.isNotEmpty) {
      edits.add(FieldEdit('tasks', id, 'updated_at', _nowSec));
      store.applyEdits(userId, source, edits);
      reload();
    }
    return taskView(id);
  }

  /// Puts the listed tasks in this order: their `order` becomes 0, 1, 2... in the sequence given (drag and drop in
  /// a list or board). Only the tasks named change; give the tasks of one section (or one parent) together.
  void reorderTasks(Object? ids) => _reorder('tasks', ids);

  /// The same for sections of a project.
  void reorderSections(Object? ids) => _reorder('sections', ids);

  void _reorder(String tableName, Object? ids) {
    if (ids is! List || ids.any((i) => i is! String) || ids.length > 1000) throw ModelError(400, 'Send {"ids": [...]}: at most 1000 ids, as text');
    final list = ids.cast<String>();
    if (list.toSet().length != list.length) throw ModelError(400, 'An id is listed twice');
    final stamp = _nowSec;
    final edits = <FieldEdit>[];
    for (var i = 0; i < list.length; i++) {
      final row = _row(tableName, list[i]);
      if (!_live(row)) throw ModelError(404, 'Not found: ${list[i]}');
      if ((row!['sort_order'] as int?) != i) {
        edits
          ..add(FieldEdit(tableName, list[i], 'sort_order', i))
          ..add(FieldEdit(tableName, list[i], 'updated_at', stamp));
      }
    }
    if (edits.isNotEmpty) {
      store.applyEdits(userId, source, edits);
      reload();
    }
  }

  Set<String> _descendants(String id) {
    final out = <String>{};
    final queue = [id];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      for (final e in table('tasks').entries) {
        if (_live(e.value) && e.value['parent_id'] == cur && out.add(e.key)) queue.add(e.key);
      }
    }
    return out;
  }

  /// Completes a task as the app does: a repeating task moves to its next date,
  /// anything else is marked done (with [withSubtasks] its open sub-tasks too).
  /// Every completion is logged.
  Map<String, Object?> closeTask(String id, {bool withSubtasks = false}) {
    final t = _row('tasks', id);
    if (!_live(t)) throw ModelError(404, 'No such task');
    if (t!['completed_at'] != null) return taskView(id);
    final stamp = _nowSec;
    final edits = <FieldEdit>[];
    final completion = newId();
    edits
      ..add(FieldEdit('completions', completion, presentColumn, true))
      ..add(FieldEdit('completions', completion, 'task_id', id))
      ..add(FieldEdit('completions', completion, 'completed_at', stamp))
      ..add(FieldEdit('completions', completion, 'due_date', t['due_date']))
      ..add(FieldEdit('completions', completion, 'due_time', t['due_time']));
    NextDue? next;
    final rec = t['recurrence'] as String?;
    final due = t['due_date'] as String?;
    if (rec != null && due != null) {
      try {
        next = nextDueAfterCompletion(recurrence: parseRecurrence(rec, now), dueDate: due, dueTime: t['due_time'] as String?, completedAt: now);
      } on RecurrenceException {
        next = null; // an unreadable repeat just completes the task
      }
    }
    if (next != null) {
      edits
        ..add(FieldEdit('tasks', id, 'due_date', next.date))
        ..add(FieldEdit('tasks', id, 'due_time', next.time))
        ..add(FieldEdit('tasks', id, 'updated_at', stamp));
      for (final d in _descendants(id)) {
        if (_row('tasks', d)!['completed_at'] != null) edits..add(FieldEdit('tasks', d, 'completed_at', null))..add(FieldEdit('tasks', d, 'updated_at', stamp));
      }
    } else {
      for (final target in [id, if (withSubtasks) ..._descendants(id)]) {
        if (_row('tasks', target)!['completed_at'] == null) {
          edits..add(FieldEdit('tasks', target, 'completed_at', stamp))..add(FieldEdit('tasks', target, 'updated_at', stamp));
        }
      }
    }
    store.applyEdits(userId, source, edits);
    reload();
    return taskView(id);
  }

  Map<String, Object?> reopenTask(String id) {
    final t = _row('tasks', id);
    if (!_live(t)) throw ModelError(404, 'No such task');
    if (t!['completed_at'] == null) return taskView(id);
    // Take the latest completion out of the history, as the app does.
    String? last;
    var lastAt = -1;
    for (final e in table('completions').entries) {
      final at = e.value['completed_at'] as int? ?? 0;
      if (e.value['task_id'] == id && at > lastAt) {
        last = e.key;
        lastAt = at;
      }
    }
    store.applyEdits(userId, source, [
      FieldEdit('tasks', id, 'completed_at', null),
      FieldEdit('tasks', id, 'updated_at', _nowSec),
      if (last != null) FieldEdit('completions', last, presentColumn, false),
    ]);
    reload();
    return taskView(id);
  }

  /// Moves a task and its sub-tasks to the trash (the app keeps them for 30 days).
  void deleteTask(String id) {
    if (!_live(_row('tasks', id))) throw ModelError(404, 'No such task');
    final stamp = _nowSec;
    final edits = <FieldEdit>[];
    for (final target in [id, ..._descendants(id)]) {
      edits..add(FieldEdit('tasks', target, 'deleted_at', stamp))..add(FieldEdit('tasks', target, 'updated_at', stamp));
    }
    store.applyEdits(userId, source, edits);
    reload();
  }

  // ---------------------------------------------------------------------------
  // Projects, sections, labels, comments
  // ---------------------------------------------------------------------------

  Map<String, Object?> createProject(Map<String, Object?> body) {
    final name = _name(body['name'], 'project');
    final parent = body['parent_id'] as String?;
    if (parent != null && !projectExists(parent)) throw ModelError(404, 'The parent project does not exist');
    var depth = 0;
    for (var c = parent; c != null && depth < 10; c = _row('projects', c)?['parent_id'] as String?) {
      depth++;
    }
    if (depth >= 3) throw ModelError(400, 'Projects go at most 3 levels deep');
    final color = body['color'] ?? 0xFF57927C;
    if (color is! int) throw ModelError(400, 'color must be a number such as 0xFF57927C');
    final id = newId();
    final stamp = _nowSec;
    store.applyEdits(userId, source, [
      FieldEdit('projects', id, presentColumn, true),
      FieldEdit('projects', id, 'name', name),
      FieldEdit('projects', id, 'color', color),
      if (parent != null) FieldEdit('projects', id, 'parent_id', parent),
      FieldEdit('projects', id, 'is_favorite', body['is_favorite'] == true ? 1 : 0),
      FieldEdit('projects', id, 'is_archived', 0),
      FieldEdit('projects', id, 'sort_order', _nextOrder('projects', (r) => r['parent_id'] == parent)),
      FieldEdit('projects', id, 'created_at', stamp),
      FieldEdit('projects', id, 'updated_at', stamp),
    ]);
    reload();
    return projectView(id);
  }

  Map<String, Object?> updateProject(String id, Map<String, Object?> body) {
    if (id == inboxId) throw ModelError(400, 'The Inbox cannot be changed');
    if (!_live(_row('projects', id))) throw ModelError(404, 'No such project');
    final p = _row('projects', id)!;
    final edits = <FieldEdit>[];
    if (body.containsKey('name')) edits.add(FieldEdit('projects', id, 'name', _name(body['name'], 'project')));
    if (body.containsKey('color')) {
      if (body['color'] is! int) throw ModelError(400, 'color must be a number');
      edits.add(FieldEdit('projects', id, 'color', body['color']));
    }
    if (body.containsKey('is_favorite')) edits.add(FieldEdit('projects', id, 'is_favorite', body['is_favorite'] == true ? 1 : 0));
    if (body.containsKey('is_archived')) edits.add(FieldEdit('projects', id, 'is_archived', body['is_archived'] == true ? 1 : 0));
    edits.removeWhere((e) => p[e.col] == e.value);
    if (edits.isNotEmpty) {
      edits.add(FieldEdit('projects', id, 'updated_at', _nowSec));
      store.applyEdits(userId, source, edits);
      reload();
    }
    return projectView(id);
  }

  /// Trashes a project; its tasks go to the Inbox unless [deleteTasks].
  void deleteProject(String id, {bool deleteTasks = false}) {
    if (id == inboxId) throw ModelError(400, 'The Inbox cannot be deleted');
    if (!_live(_row('projects', id))) throw ModelError(404, 'No such project');
    final stamp = _nowSec;
    final edits = <FieldEdit>[FieldEdit('projects', id, 'deleted_at', stamp), FieldEdit('projects', id, 'updated_at', stamp)];
    for (final e in table('tasks').entries) {
      if (!_live(e.value) || e.value['project_id'] != id) continue;
      if (deleteTasks) {
        edits..add(FieldEdit('tasks', e.key, 'deleted_at', stamp))..add(FieldEdit('tasks', e.key, 'updated_at', stamp));
      } else {
        edits
          ..add(FieldEdit('tasks', e.key, 'project_id', inboxId))
          ..add(FieldEdit('tasks', e.key, 'section_id', null))
          ..add(FieldEdit('tasks', e.key, 'updated_at', stamp));
      }
    }
    for (final e in table('sections').entries) {
      if (_live(e.value) && e.value['project_id'] == id) edits..add(FieldEdit('sections', e.key, 'deleted_at', stamp))..add(FieldEdit('sections', e.key, 'updated_at', stamp));
    }
    store.applyEdits(userId, source, edits);
    reload();
  }

  Map<String, Object?> createSection(Map<String, Object?> body) {
    final project = body['project_id'];
    if (project is! String || !projectExists(project)) throw ModelError(404, 'The project does not exist');
    final name = _name(body['name'], 'section');
    final id = newId();
    final stamp = _nowSec;
    store.applyEdits(userId, source, [
      FieldEdit('sections', id, presentColumn, true),
      FieldEdit('sections', id, 'project_id', project),
      FieldEdit('sections', id, 'name', name),
      FieldEdit('sections', id, 'sort_order', _nextOrder('sections', (r) => r['project_id'] == project)),
      FieldEdit('sections', id, 'is_collapsed', 0),
      FieldEdit('sections', id, 'is_archived', 0),
      FieldEdit('sections', id, 'created_at', stamp),
      FieldEdit('sections', id, 'updated_at', stamp),
    ]);
    reload();
    return sections(projectId: project).firstWhere((s) => s['id'] == id);
  }

  Map<String, Object?> updateSection(String id, Map<String, Object?> body) {
    final s = _row('sections', id);
    if (!_live(s)) throw ModelError(404, 'No such section');
    if (body.containsKey('name')) {
      final name = _name(body['name'], 'section');
      if (name != s!['name']) {
        store.applyEdits(userId, source, [FieldEdit('sections', id, 'name', name), FieldEdit('sections', id, 'updated_at', _nowSec)]);
        reload();
      }
    }
    return sections().firstWhere((x) => x['id'] == id);
  }

  void deleteSection(String id) {
    if (!_live(_row('sections', id))) throw ModelError(404, 'No such section');
    final stamp = _nowSec;
    final edits = <FieldEdit>[FieldEdit('sections', id, 'deleted_at', stamp), FieldEdit('sections', id, 'updated_at', stamp)];
    for (final e in table('tasks').entries) {
      if (_live(e.value) && e.value['section_id'] == id) edits..add(FieldEdit('tasks', e.key, 'section_id', null))..add(FieldEdit('tasks', e.key, 'updated_at', stamp));
    }
    store.applyEdits(userId, source, edits);
    reload();
  }

  Map<String, Object?> createLabel(Map<String, Object?> body) {
    final name = _name(body['name'], 'label').replaceFirst(RegExp(r'^[%@]'), '');
    for (final l in labels()) {
      if ((l['name'] as String).toLowerCase() == name.toLowerCase()) return l;
    }
    final id = newId();
    store.applyEdits(userId, source, _newLabel(id, name));
    reload();
    return labels().firstWhere((l) => l['id'] == id);
  }

  void deleteLabel(String id) {
    if (!_live(_row('labels', id))) throw ModelError(404, 'No such label');
    final edits = <FieldEdit>[FieldEdit('labels', id, presentColumn, false)];
    for (final key in table('task_labels').keys) {
      if (key.endsWith('|$id')) edits.add(FieldEdit('task_labels', key, presentColumn, false));
    }
    store.applyEdits(userId, source, edits);
    reload();
  }

  Map<String, Object?> createComment(Map<String, Object?> body) {
    final task = body['task_id'];
    if (task is! String || !taskExists(task)) throw ModelError(404, 'The task does not exist');
    final text = body['content'] ?? body['body'];
    if (text is! String || text.trim().isEmpty) throw ModelError(400, 'A comment cannot be empty');
    if (text.length > 20000) throw ModelError(400, 'Comments are limited to 20000 characters');
    final id = newId();
    final stamp = _nowSec;
    store.applyEdits(userId, source, [
      FieldEdit('comments', id, presentColumn, true),
      FieldEdit('comments', id, 'task_id', task),
      FieldEdit('comments', id, 'body', text.trim()),
      FieldEdit('comments', id, 'created_at', stamp),
      FieldEdit('comments', id, 'updated_at', stamp),
    ]);
    reload();
    return comments(task).firstWhere((c) => c['id'] == id);
  }

  void deleteComment(String id) {
    final c = _row('comments', id);
    if (!_live(c)) throw ModelError(404, 'No such comment');
    store.applyEdits(userId, source, [FieldEdit('comments', id, 'deleted_at', _nowSec), FieldEdit('comments', id, 'updated_at', _nowSec)]);
    reload();
  }

  // ---------------------------------------------------------------------------
  // Quick Add, for the incoming webhook
  // ---------------------------------------------------------------------------

  /// Where a parsed line puts the task: the project it names (else [defaultProject]) and, inside it, the section it
  /// names. `known` says whether a typed name matched something.
  ({String project, String? section, bool projectKnown, bool sectionKnown}) _place(QuickAddResult parsed, String defaultProject) {
    var project = defaultProject;
    var projectKnown = true;
    if (parsed.projectName != null) {
      projectKnown = false;
      final typed = normaliseName(parsed.projectName!);
      if (typed == normaliseName('Inbox')) {
        project = inboxId;
        projectKnown = true;
      }
      for (final e in table('projects').entries) {
        if (_live(e.value) && normaliseName(e.value['name'] as String) == typed) {
          project = e.key;
          projectKnown = true;
        }
      }
    }
    String? section;
    var sectionKnown = true;
    if (parsed.sectionName != null) {
      sectionKnown = false;
      final typed = normaliseName(parsed.sectionName!);
      for (final e in table('sections').entries) {
        if (_live(e.value) && e.value['project_id'] == project && normaliseName(e.value['name'] as String) == typed) {
          section = e.key;
          sectionKnown = true;
        }
      }
    }
    return (project: project, section: section, projectKnown: projectKnown, sectionKnown: sectionKnown);
  }

  /// What a Quick Add line means, without saving anything: for the live preview while typing. [tokens] give the
  /// position of each recognised word in [text] (kind, start, end) so it can be highlighted.
  Map<String, Object?> quickAddPreview(String text, {String projectId = inboxId, DateTime? today}) {
    final parsed = parseQuickAdd(text, today ?? now);
    final place = _place(parsed, projectId);
    String? name(String table, String? id) => id == null ? null : (id == inboxId ? 'Inbox' : this.table(table)[id]?['name'] as String?);
    return {
      'title': parsed.title.trim(),
      'priority': parsed.priority,
      'due': parsed.due == null ? null : {'date': formatDate(parsed.due!), 'time': parsed.dueTime == null ? null : formatTime(parsed.dueTime!), 'recurrence': parsed.recurrence?.text},
      'deadline': parsed.deadline == null ? null : formatDate(parsed.deadline!),
      'labels': parsed.labels,
      'project': {'id': place.project, 'name': name('projects', place.project), 'typed': parsed.projectName, 'known': place.projectKnown},
      'section': parsed.sectionName == null ? null : {'id': place.section, 'name': name('sections', place.section), 'typed': parsed.sectionName, 'known': place.sectionKnown},
      'repeat_error': parsed.repeatError,
      'tokens': [for (final t in parsed.tokens) {'kind': t.kind.name, 'start': t.start, 'end': t.end}],
    };
  }

  /// Makes a task from a Quick Add line (`Buy milk tomorrow p1 %errands`),
  /// in [projectId] unless the line names one. Dates are worked out as of
  /// [today], which the caller chooses (the server's own clock is UTC).
  Map<String, Object?> taskFromText(String text, {String projectId = inboxId, DateTime? today}) {
    final parsed = parseQuickAdd(text.trim(), today ?? now);
    if (parsed.title.isEmpty) throw ModelError(400, 'The text has no title');
    final place = _place(parsed, projectId);
    final body = <String, Object?>{
      'title': parsed.title,
      'project_id': place.project,
      if (place.section != null) 'section_id': place.section,
      if (parsed.priority != null) 'priority': parsed.priority,
      if (parsed.due != null) 'due_date': formatDate(parsed.due!),
      if (parsed.dueTime != null && parsed.due != null) 'due_time': formatTime(parsed.dueTime!),
      if (parsed.recurrence != null && parsed.due != null) 'recurrence': parsed.recurrence!.text,
      if (parsed.deadline != null) 'deadline': formatDate(parsed.deadline!),
      if (parsed.labels.isNotEmpty) 'labels': parsed.labels,
    };
    return createTask(body);
  }
}
