/// SQL triggers that write the activity log (FR-K6..K8) whenever a task or
/// project is added, edited, completed, moved, deleted or restored.
///
/// They run in the database, so every code path that changes data is covered
/// without each one having to remember to log. They do nothing while
/// `sync_meta.log` is `0`, which the sync engine sets while it applies edits
/// that came from another device (those devices logged them already, and the
/// log rows arrive on their own).
library;

const _logOn = "(SELECT value FROM sync_meta WHERE key = 'log') = '1'";

const _nowMs = "(CAST(strftime('%s', 'now') AS INTEGER) * 1000 + CAST(substr(strftime('%f', 'now'), 4) AS INTEGER))";

/// A completion row for this task was written at the same moment as [stamp]
/// (a column of the task row being changed, both taken from the app's clock),
/// so the completion is already logged, and a repeating task's new due date is
/// part of it.
String _recentCompletion(String task, String stamp) =>
    "EXISTS (SELECT 1 FROM completions c WHERE c.task_id = $task AND abs(c.completed_at - $stamp) <= 2)";

String _insert(String event, String type, String id, String project, String title, {String field = 'NULL', String oldV = 'NULL', String newV = 'NULL'}) =>
    "INSERT INTO activity(id, event, entity_type, entity_id, project_id, title, field, old_value, new_value, at_ms, device) "
    "VALUES (lower(hex(randomblob(16))), '$event', '$type', $id, $project, $title, $field, $oldV, $newV, $_nowMs, "
    "(SELECT value FROM sync_meta WHERE key = 'device'));";

String _text(String expr) => "substr(CAST($expr AS TEXT), 1, 500)";

const _editedTaskColumns = ['title', 'description', 'priority', 'due_date', 'due_time', 'recurrence', 'deadline'];
const _movedTaskColumns = ['project_id', 'section_id', 'parent_id'];

/// Names of every trigger made by [activityTriggerStatements].
List<String> activityTriggerNames() => [
      'act_task_add',
      'act_task_complete',
      'act_task_uncomplete',
      'act_completion_add',
      'act_task_delete',
      'act_task_restore',
      for (final c in _editedTaskColumns) 'act_task_edit_$c',
      for (final c in _movedTaskColumns) 'act_task_move_$c',
      'act_project_add',
      'act_project_name',
      'act_project_archived',
      'act_project_delete',
      'act_project_restore',
    ];

List<String> activityTriggerStatements() {
  final out = <String>[];
  String task(String ev, String when, {String field = 'NULL', String oldV = 'NULL', String newV = 'NULL'}) =>
      _insert(ev, 'task', 'NEW.id', 'NEW.project_id', 'NEW.title', field: field, oldV: oldV, newV: newV);

  out.add('CREATE TRIGGER act_task_add AFTER INSERT ON tasks WHEN $_logOn BEGIN ${task('add', '')} END');
  out.add('''
CREATE TRIGGER act_task_complete AFTER UPDATE OF completed_at ON tasks
WHEN $_logOn AND OLD.completed_at IS NULL AND NEW.completed_at IS NOT NULL AND NOT ${_recentCompletion('NEW.id', 'NEW.completed_at')}
BEGIN ${task('complete', '')} END''');
  out.add('''
CREATE TRIGGER act_task_uncomplete AFTER UPDATE OF completed_at ON tasks
WHEN $_logOn AND OLD.completed_at IS NOT NULL AND NEW.completed_at IS NULL
BEGIN ${task('uncomplete', '')} END''');
  out.add('''
CREATE TRIGGER act_completion_add AFTER INSERT ON completions WHEN $_logOn
BEGIN ${_insert('complete', 'task', 'NEW.task_id', '(SELECT project_id FROM tasks WHERE id = NEW.task_id)', "COALESCE((SELECT title FROM tasks WHERE id = NEW.task_id), '')")} END''');
  out.add('''
CREATE TRIGGER act_task_delete AFTER UPDATE OF deleted_at ON tasks
WHEN $_logOn AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL
BEGIN ${task('delete', '')} END''');
  out.add('''
CREATE TRIGGER act_task_restore AFTER UPDATE OF deleted_at ON tasks
WHEN $_logOn AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL
BEGIN ${task('restore', '')} END''');
  for (final c in _editedTaskColumns) {
    final skipRepeat = (c == 'due_date' || c == 'due_time') ? ' AND NOT ${_recentCompletion('NEW.id', 'NEW.updated_at')}' : '';
    out.add('''
CREATE TRIGGER act_task_edit_$c AFTER UPDATE OF $c ON tasks
WHEN $_logOn AND NEW.$c IS NOT OLD.$c$skipRepeat
BEGIN ${task('edit', '', field: "'$c'", oldV: _text('OLD.$c'), newV: _text('NEW.$c'))} END''');
  }
  for (final c in _movedTaskColumns) {
    out.add('''
CREATE TRIGGER act_task_move_$c AFTER UPDATE OF $c ON tasks
WHEN $_logOn AND NEW.$c IS NOT OLD.$c
BEGIN ${task('move', '', field: "'$c'", oldV: 'OLD.$c', newV: 'NEW.$c')} END''');
  }

  String project(String ev, {String field = 'NULL', String oldV = 'NULL', String newV = 'NULL'}) =>
      _insert(ev, 'project', 'NEW.id', 'NEW.id', 'NEW.name', field: field, oldV: oldV, newV: newV);
  out.add('CREATE TRIGGER act_project_add AFTER INSERT ON projects WHEN $_logOn AND NEW.id <> \'inbox\' BEGIN ${project('add')} END');
  out.add('''
CREATE TRIGGER act_project_name AFTER UPDATE OF name ON projects
WHEN $_logOn AND NEW.name IS NOT OLD.name
BEGIN ${project('edit', field: "'name'", oldV: 'OLD.name', newV: 'NEW.name')} END''');
  out.add('''
CREATE TRIGGER act_project_archived AFTER UPDATE OF is_archived ON projects
WHEN $_logOn AND NEW.is_archived IS NOT OLD.is_archived
BEGIN ${project('edit', field: "'is_archived'", oldV: _text('OLD.is_archived'), newV: _text('NEW.is_archived'))} END''');
  out.add('''
CREATE TRIGGER act_project_delete AFTER UPDATE OF deleted_at ON projects
WHEN $_logOn AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL
BEGIN ${project('delete')} END''');
  out.add('''
CREATE TRIGGER act_project_restore AFTER UPDATE OF deleted_at ON projects
WHEN $_logOn AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL
BEGIN ${project('restore')} END''');
  return out;
}
