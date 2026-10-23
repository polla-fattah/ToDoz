/// A remote MCP server (Model Context Protocol over Streamable HTTP) at `/mcp`, so assistants that run in the
/// cloud (Claude, ChatGPT, Gemini) can add, list and complete the owner's tasks. It uses the same personal API
/// tokens as the REST API: `Authorization: Bearer tf_...` or, for apps that cannot send a header, the token in
/// the address (`/mcp/tf_...`). A read-only token can look but not change anything.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'model.dart';
import 'rest.dart' show RestAuth, RestRefusal;
import 'store.dart';

/// What the MCP routes need from the surrounding server.
class McpContext {
  McpContext({required this.store, required this.authenticate, this.maxBodyBytes = 256 * 1024});

  final Store store;

  /// Checks the API token (from the header, or [urlToken] from the address) and the rate limit; throws [RestRefusal].
  final RestAuth Function(Request, String? urlToken) authenticate;
  final int maxBodyBytes;
}

const supportedProtocols = ['2025-06-18', '2025-03-26', '2024-11-05'];
const maxListedTasks = 100;

const _instructions = 'ToDoz is the owner\'s task manager. Use add_task with a Quick Add line (dates like "tomorrow 5pm" or '
    '"every monday", p1 to p4 for priority, #Project, %label). The server does not know the owner\'s time zone: when you know '
    'their current local date and time, pass it as local_now (like 2026-10-23T14:30) so "today" and "tomorrow" mean theirs.';

/// A failure the assistant should see as a tool error (not a protocol error).
class _ToolFailure implements Exception {
  _ToolFailure(this.message);
  final String message;
}

class _Tool {
  _Tool(this.name, this.title, this.description, this.properties, {this.required = const [], this.writes = false});
  final String name;
  final String title;
  final String description;
  final Map<String, Object?> properties;
  final List<String> required;
  final bool writes;

  Map<String, Object?> toJson() => {
        'name': name,
        'title': title,
        'description': description,
        'inputSchema': {'type': 'object', 'properties': properties, if (required.isNotEmpty) 'required': required},
        'annotations': {'title': title, 'readOnlyHint': !writes, 'destructiveHint': false, 'openWorldHint': false},
      };
}

const _projectProp = {
  'type': 'string',
  'description': 'Project name or id (see list_projects). Leave out for the Inbox. A #Project written in the text takes priority.',
};
const _nowProp = {
  'type': 'string',
  'description': 'The owner\'s current local date and time like 2026-10-23T14:30, if you know it, so "tomorrow" means theirs.',
};

final _tools = <_Tool>[
  _Tool(
    'add_task',
    'Add a task',
    'Add a task to ToDoz from a Quick Add line. The line is understood the way the ToDoz apps understand it: dates and times '
        '("tomorrow 5pm", "every monday"), priority (p1 is most urgent, p4 least), #Project, %label, and /Section. '
        'Example: "Submit revisions tomorrow 4pm p1 #Research %writing". Returns the task that was created.',
    {
      'text': {'type': 'string', 'description': 'The Quick Add line, e.g. "Buy milk tomorrow 5pm p2 #Home".'},
      'project': _projectProp,
      'local_now': _nowProp,
    },
    required: ['text'],
    writes: true,
  ),
  _Tool(
    'parse_preview',
    'Preview a Quick Add line',
    'Show what a Quick Add line would become (title, due date and time, priority, labels, project) without saving anything. '
        'Use it to check a date or project before add_task when unsure.',
    {
      'text': {'type': 'string', 'description': 'The Quick Add line to interpret.'},
      'project': _projectProp,
      'local_now': _nowProp,
    },
    required: ['text'],
  ),
  _Tool('list_projects', 'List projects', 'List the ToDoz projects with their ids (the Inbox is included). Use the ids or names with add_task and list_tasks.', {}),
  _Tool(
    'list_tasks',
    'List tasks',
    'List open tasks, optionally only those in one project, due on one date, or carrying one label.',
    {
      'project_id': {'type': 'string', 'description': 'Only tasks in this project (an id from list_projects; a project name also works).'},
      'due_date': {'type': 'string', 'description': 'Only tasks due on this date, as YYYY-MM-DD.'},
      'label': {'type': 'string', 'description': 'Only tasks with this label (without the % or @).'},
    },
  ),
  _Tool(
    'complete_task',
    'Complete a task',
    'Mark a task as done. Repeating tasks move on to their next date. Get the task id from list_tasks.',
    {
      'task_id': {'type': 'string', 'description': 'The id of the task, from list_tasks or add_task.'},
      'with_subtasks': {'type': 'boolean', 'description': 'Also complete the task\'s subtasks.'},
    },
    required: ['task_id'],
    writes: true,
  ),
];

Map<String, Object?> _summary(Map<String, Object?> t) => {
      'id': t['id'],
      'title': t['title'],
      'project_id': t['project_id'],
      'priority': t['priority'],
      if (t['due'] != null) 'due': t['due'],
      if (t['deadline'] != null) 'deadline': t['deadline'],
      if ((t['labels'] as List?)?.isNotEmpty ?? false) 'labels': t['labels'],
      if ((t['description'] as String?)?.isNotEmpty ?? false) 'description': t['description'],
      if (t['section_id'] != null) 'section_id': t['section_id'],
      if (t['parent_id'] != null) 'parent_id': t['parent_id'],
      if (t['is_completed'] == true) 'is_completed': true,
    };

String? _text(Map<String, Object?> args, String name, {bool required = false, int max = 2000}) {
  final v = args[name];
  if (v == null || (v is String && v.trim().isEmpty)) {
    if (required) throw _ToolFailure('$name is required');
    return null;
  }
  if (v is! String) throw _ToolFailure('$name must be text');
  if (v.length > max) throw _ToolFailure('$name is too long');
  return v.trim();
}

/// The owner's local "now" as the Quick Add parser wants it, or null to use the server's clock.
DateTime? _localNow(Map<String, Object?> args) {
  final raw = _text(args, 'local_now', max: 40);
  if (raw == null) return null;
  final d = DateTime.tryParse(raw);
  if (d == null) throw _ToolFailure('local_now must look like 2026-10-23T14:30');
  return DateTime(d.year, d.month, d.day, d.hour, d.minute);
}

/// A project given by id or name, as an id; null for the Inbox.
String? _project(UserModel m, String? ref) {
  if (ref == null) return null;
  final all = m.projects();
  for (final p in all) {
    if (p['id'] == ref) return ref;
  }
  final named = [
    for (final p in all)
      if (p['is_archived'] != true && (p['name'] as String? ?? '').toLowerCase() == ref.toLowerCase()) p['id'] as String,
  ];
  if (named.length == 1) return named.single;
  if (named.length > 1) throw _ToolFailure('More than one project is called "$ref". Use list_projects and pass the project id.');
  final names = [for (final p in all) if (p['is_archived'] != true) p['name']].join(', ');
  throw _ToolFailure('No project called "$ref". Projects: $names.');
}

Object? _callTool(UserModel m, String name, Map<String, Object?> args) {
  try {
    switch (name) {
      case 'add_task':
        final text = _text(args, 'text', required: true)!;
        final project = _project(m, _text(args, 'project'));
        final task = m.taskFromText(text, projectId: project ?? inboxId, today: _localNow(args));
        return {'created': _summary(task)};
      case 'parse_preview':
        final text = _text(args, 'text', required: true)!;
        final project = _project(m, _text(args, 'project'));
        final preview = Map<String, Object?>.of(m.quickAddPreview(text, projectId: project ?? inboxId, today: _localNow(args)))..remove('tokens');
        return preview;
      case 'list_projects':
        return {
          'projects': [
            for (final p in m.projects())
              if (p['is_archived'] != true) {'id': p['id'], 'name': p['name'], if (p['is_inbox'] == true) 'is_inbox': true, if (p['parent_id'] != null) 'parent_id': p['parent_id']},
          ],
        };
      case 'list_tasks':
        final due = _text(args, 'due_date', max: 10);
        if (due != null && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(due)) throw _ToolFailure('due_date must look like 2026-10-23');
        final tasks = m.tasks(projectId: _project(m, _text(args, 'project_id')), dueDate: due, label: _text(args, 'label', max: 100));
        return {
          'count': tasks.length,
          if (tasks.length > maxListedTasks) 'note': 'Showing the first $maxListedTasks; narrow it with project_id, due_date or label.',
          'tasks': [for (final t in tasks.take(maxListedTasks)) _summary(t)],
        };
      case 'complete_task':
        final id = _text(args, 'task_id', required: true, max: 100)!;
        final done = m.closeTask(id, withSubtasks: args['with_subtasks'] == true);
        return {'completed': _summary(done)};
    }
  } on ModelError catch (e) {
    throw _ToolFailure(e.message);
  }
  throw _ToolFailure('No such tool: $name');
}

Map<String, Object?> _error(Object? id, int code, String message) => {'jsonrpc': '2.0', 'id': id, 'error': {'code': code, 'message': message}};

/// Answers one JSON-RPC message; null for a notification or a response (nothing is sent back).
Map<String, Object?>? _handle(Object? message, McpContext c, RestAuth auth) {
  if (message is! Map) return _error(null, -32600, 'Send a JSON-RPC request object');
  final method = message['method'];
  final hasId = message.containsKey('id');
  final id = message['id'];
  if (method == null && hasId) return null; // a response to something we never asked
  if (method is! String || message['jsonrpc'] != '2.0') return _error(hasId ? id : null, -32600, 'Not a JSON-RPC 2.0 request');
  if (!hasId) return null; // a notification, such as notifications/initialized

  final params = message['params'] is Map ? (message['params'] as Map).cast<String, Object?>() : const <String, Object?>{};
  Map<String, Object?> ok(Object? result) => {'jsonrpc': '2.0', 'id': id, 'result': result};

  switch (method) {
    case 'initialize':
      final asked = params['protocolVersion'];
      return ok({
        'protocolVersion': supportedProtocols.contains(asked) ? asked : supportedProtocols.first,
        'capabilities': {'tools': {'listChanged': false}},
        'serverInfo': {'name': 'todoz', 'title': 'ToDoz', 'version': '1.0.0'},
        'instructions': _instructions,
      });
    case 'ping':
      return ok(const {});
    case 'tools/list':
      return ok({'tools': [for (final t in _tools) if (!(t.writes && auth.readOnly)) t.toJson()]});
    case 'tools/call':
      final name = params['name'];
      if (name is! String) return _error(id, -32602, 'Give the tool name');
      final tool = _tools.where((t) => t.name == name).firstOrNull;
      if (tool == null) return _error(id, -32602, 'Unknown tool: $name');
      final args = params['arguments'] is Map ? (params['arguments'] as Map).cast<String, Object?>() : const <String, Object?>{};
      String text;
      var failed = false;
      try {
        if (tool.writes && auth.readOnly) {
          throw _ToolFailure('This API token is read-only, so it can look at tasks but not add or change them. Make a token without "read only" in the ToDoz app under Settings > Calendar and integrations > API access.');
        }
        text = jsonEncode(_callTool(UserModel(c.store, auth.userId, source: 'mcp:${auth.tokenId}'), name, args));
      } on _ToolFailure catch (e) {
        text = e.message;
        failed = true;
      }
      return ok({
        'content': [
          {'type': 'text', 'text': text},
        ],
        if (failed) 'isError': true,
      });
  }
  return _error(id, -32601, 'Method not found: $method');
}

Response _rpc(int status, Object? body, {Map<String, String> headers = const {}}) =>
    Response(status, body: body == null ? null : jsonEncode(body), headers: {if (body != null) 'content-type': 'application/json; charset=utf-8', ...headers});

void registerMcp(Router router, McpContext c) {
  Future<Response> post(Request r, String? urlToken) async {
    final RestAuth auth;
    try {
      auth = c.authenticate(r, urlToken);
    } on RestRefusal catch (e) {
      return _rpc(e.status, _error(null, -32001, e.message), headers: e.headers);
    }
    final declared = r.contentLength;
    if (declared != null && declared > c.maxBodyBytes) return _rpc(413, _error(null, -32600, 'The request is too large'));
    final bytes = <int>[];
    await for (final part in r.read()) {
      bytes.addAll(part);
      if (bytes.length > c.maxBodyBytes) return _rpc(413, _error(null, -32600, 'The request is too large'));
    }
    final Object? message;
    try {
      message = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return _rpc(400, _error(null, -32700, 'The body is not valid JSON'));
    }
    if (message is List) {
      if (message.isEmpty || message.length > 20) return _rpc(400, _error(null, -32600, 'Send between 1 and 20 messages'));
      final replies = [for (final m in message) _handle(m, c, auth)].whereType<Map<String, Object?>>().toList();
      return replies.isEmpty ? Response(202) : _rpc(200, replies);
    }
    final reply = _handle(message, c, auth);
    return reply == null ? Response(202) : _rpc(200, reply);
  }

  // This server never starts a stream of its own, so GET and DELETE are refused, which the protocol allows.
  Response notAllowed() => _rpc(405, _error(null, -32000, 'Use POST'), headers: {'allow': 'POST'});

  router.post('/mcp', (Request r) => post(r, null));
  router.post('/mcp/<token>', (Request r, String token) => post(r, token));
  router.get('/mcp', (Request r) => notAllowed());
  router.get('/mcp/<token>', (Request r, String token) => notAllowed());
  router.delete('/mcp', (Request r) => notAllowed());
  router.delete('/mcp/<token>', (Request r, String token) => notAllowed());
}
