/// The REST API for the owner's own scripts (FR-I4): `/api/v1/...`, with a
/// personal API token. It reads and writes the same data the apps sync, so
/// whatever a script does appears on every device at its next sync.
library;

import 'dart:async';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'model.dart';
import 'store.dart';

/// What the REST routes need from the surrounding server.
class RestContext {
  RestContext({
    required this.store,
    required this.readJson,
    required this.json,
    required this.error,
    required this.authenticate,
    this.onEdited,
  });

  final Store store;
  final Future<Object?> Function(Request) readJson;
  final Response Function(int status, Object? body) json;
  final Response Function(int status, String code, String message) error;

  /// Checks the API token and the rate limit; throws a [Response] ... see [RestAuth].
  final RestAuth Function(Request) authenticate;

  /// Called after a script changed data (the webhook sender hooks in here).
  final void Function(String userId, List<FieldEdit> edits)? onEdited;
}

class RestAuth {
  RestAuth(this.userId, this.tokenId, this.readOnly);
  final String userId;
  final String tokenId;
  final bool readOnly;
}

/// Thrown by [RestContext.authenticate] to answer with an error.
class RestRefusal implements Exception {
  RestRefusal(this.status, this.code, this.message, {this.headers = const {}});
  final int status;
  final String code;
  final String message;
  final Map<String, String> headers;
}

void registerRest(Router router, RestContext c) {
  Future<Response> run(Request r, {required bool write, required FutureOr<Object?> Function(UserModel m, Map<String, Object?> body) f, int okStatus = 200}) async {
    try {
      final auth = c.authenticate(r);
      if (write && auth.readOnly) return c.error(403, 'read_only', 'This token can only read');
      Map<String, Object?> body = const {};
      if (r.method == 'POST' || r.method == 'PUT') {
        final hasBody = (r.contentLength ?? 0) > 0 || r.headers['transfer-encoding'] != null;
        if (hasBody) {
          final parsed = await c.readJson(r);
          if (parsed is! Map) return c.error(400, 'bad_request', 'Send a JSON object');
          body = parsed.cast<String, Object?>();
        }
      }
      final model = UserModel(c.store, auth.userId, source: 'api:${auth.tokenId}');
      final result = await f(model, body);
      if (result == null) return Response(204);
      return c.json(okStatus, result);
    } on RestRefusal catch (e) {
      return c.error(e.status, e.code, e.message).change(headers: e.headers);
    } on ModelError catch (e) {
      return c.error(e.status, e.status == 404 ? 'not_found' : 'bad_request', e.message);
    }
  }

  String? q(Request r, String name) {
    final v = r.url.queryParameters[name];
    return v == null || v.isEmpty ? null : v;
  }

  // --- tasks ---------------------------------------------------------------------

  router.get('/api/v1/tasks', (Request r) => run(r, write: false, f: (m, _) => {
        'tasks': m.tasks(
          projectId: q(r, 'project_id'),
          sectionId: q(r, 'section_id'),
          parentId: q(r, 'parent_id'),
          label: q(r, 'label'),
          dueDate: q(r, 'due_date'),
          includeCompleted: q(r, 'include_completed') == 'true',
        ),
      }));

  router.post('/api/v1/tasks', (Request r) => run(r, write: true, okStatus: 201, f: (m, b) => m.createTask(b)));

  router.get('/api/v1/tasks/<id>', (Request r, String id) => run(r, write: false, f: (m, _) {
        if (!m.taskExists(id)) throw ModelError(404, 'No such task');
        return m.taskView(id);
      }));

  router.post('/api/v1/tasks/<id>', (Request r, String id) => run(r, write: true, f: (m, b) => m.updateTask(id, b)));

  router.delete('/api/v1/tasks/<id>', (Request r, String id) => run(r, write: true, f: (m, _) {
        m.deleteTask(id);
        return null;
      }));

  router.post('/api/v1/tasks/<id>/close', (Request r, String id) => run(r, write: true, f: (m, b) => m.closeTask(id, withSubtasks: b['with_subtasks'] == true)));

  router.post('/api/v1/tasks/<id>/reopen', (Request r, String id) => run(r, write: true, f: (m, _) => m.reopenTask(id)));

  // --- projects, sections, labels ----------------------------------------------------

  router.get('/api/v1/projects', (Request r) => run(r, write: false, f: (m, _) => {'projects': m.projects()}));
  router.post('/api/v1/projects', (Request r) => run(r, write: true, okStatus: 201, f: (m, b) => m.createProject(b)));
  router.get('/api/v1/projects/<id>', (Request r, String id) => run(r, write: false, f: (m, _) {
        if (!m.projectExists(id)) throw ModelError(404, 'No such project');
        return m.projectView(id);
      }));
  router.post('/api/v1/projects/<id>', (Request r, String id) => run(r, write: true, f: (m, b) => m.updateProject(id, b)));
  router.delete('/api/v1/projects/<id>', (Request r, String id) => run(r, write: true, f: (m, _) {
        m.deleteProject(id, deleteTasks: q(r, 'delete_tasks') == 'true');
        return null;
      }));

  router.get('/api/v1/sections', (Request r) => run(r, write: false, f: (m, _) => {'sections': m.sections(projectId: q(r, 'project_id'))}));
  router.post('/api/v1/sections', (Request r) => run(r, write: true, okStatus: 201, f: (m, b) => m.createSection(b)));
  router.delete('/api/v1/sections/<id>', (Request r, String id) => run(r, write: true, f: (m, _) {
        m.deleteSection(id);
        return null;
      }));

  router.get('/api/v1/labels', (Request r) => run(r, write: false, f: (m, _) => {'labels': m.labels()}));
  router.post('/api/v1/labels', (Request r) => run(r, write: true, okStatus: 201, f: (m, b) => m.createLabel(b)));
  router.delete('/api/v1/labels/<id>', (Request r, String id) => run(r, write: true, f: (m, _) {
        m.deleteLabel(id);
        return null;
      }));

  // --- comments, filters, reminders, completed items ------------------------------------

  router.get('/api/v1/comments', (Request r) => run(r, write: false, f: (m, _) {
        final task = q(r, 'task_id');
        if (task == null) throw ModelError(400, 'Give task_id');
        if (!m.taskExists(task)) throw ModelError(404, 'No such task');
        return {'comments': m.comments(task)};
      }));
  router.post('/api/v1/comments', (Request r) => run(r, write: true, okStatus: 201, f: (m, b) => m.createComment(b)));
  router.delete('/api/v1/comments/<id>', (Request r, String id) => run(r, write: true, f: (m, _) {
        m.deleteComment(id);
        return null;
      }));

  router.get('/api/v1/filters', (Request r) => run(r, write: false, f: (m, _) => {'filters': m.filters()}));

  router.get('/api/v1/reminders', (Request r) => run(r, write: false, f: (m, _) {
        final task = q(r, 'task_id');
        if (task == null) throw ModelError(400, 'Give task_id');
        if (!m.taskExists(task)) throw ModelError(404, 'No such task');
        return {'reminders': m.reminders(task)};
      }));

  router.get('/api/v1/completed', (Request r) => run(r, write: false, f: (m, _) {
        DateTime? date(String name) {
          final v = q(r, name);
          if (v == null) return null;
          final d = DateTime.tryParse(v);
          if (d == null) throw ModelError(400, '$name must be an ISO date or time');
          return d.isUtc ? d : DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second);
        }

        final limit = (int.tryParse(q(r, 'limit') ?? '') ?? 200).clamp(1, 1000);
        return {'items': m.completed(since: date('since'), until: date('until'), limit: limit)};
      }));
}
