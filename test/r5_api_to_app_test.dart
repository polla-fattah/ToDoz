import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/sync_service.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';

/// What a script does through the REST API must show up in the real app database,
/// and what the app does must show up in the API: the two spell data the same way.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Store server;
  late HttpServer httpServer;
  late String base;
  late String apiToken;
  late Account alice;

  setUp(() async {
    server = Store.open(':memory:');
    alice = server.createUser('Alice');
    apiToken = server.createApiToken(alice.id, 'script').token;
    httpServer = await io.serve(buildApi(server, config: const ApiConfig(syncPerMinute: 100000, apiPerMinute: 100000)), InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${httpServer.port}';
  });
  tearDown(() async {
    await httpServer.close(force: true);
    server.close();
  });

  Future<Map<String, dynamic>> api(String method, String path, {Object? body}) async {
    final r = await http.Response.fromStream(await http.Client().send(http.Request(method, Uri.parse('$base$path'))
      ..headers.addAll({'authorization': 'Bearer $apiToken', 'content-type': 'application/json'})
      ..body = body == null ? '' : jsonEncode(body)));
    expect(r.statusCode, anyOf(200, 201, 204), reason: '$method $path → ${r.body}');
    return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<({SyncService svc, Repo repo})> app() async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.ensureSyncMeta();
    await db.ensureInbox();
    final repo = Repo(db);
    final svc = SyncService(repo, MemoryTokenStore(), interval: const Duration(hours: 1), debounce: const Duration(hours: 1));
    addTearDown(svc.dispose);
    await svc.pair(base, server.createInvite(alice.id), 'Phone');
    return (svc: svc, repo: repo);
  }

  test('a task made by a script arrives in the app complete: project, section, labels, time, priority, comment', () async {
    final phone = await app();
    final project = (await api('POST', '/api/v1/projects', body: {'name': 'Work'}))['id'] as String;
    final section = (await api('POST', '/api/v1/sections', body: {'project_id': project, 'name': 'Soon'}))['id'] as String;
    final task = await api('POST', '/api/v1/tasks', body: {
      'title': 'Ship it',
      'description': 'with notes',
      'project_id': project,
      'section_id': section,
      'priority': 1,
      'due_date': '2026-10-20',
      'due_time': '09:30',
      'deadline': '2026-10-31',
      'duration_minutes': 60,
      'labels': ['release', 'urgent'],
    });
    await api('POST', '/api/v1/comments', body: {'task_id': task['id'], 'content': 'Remember the changelog'});
    await phone.svc.syncNow();
    expect(phone.svc.state, SyncState.idle, reason: phone.svc.lastError);

    final t = (await phone.repo.getTask(task['id'] as String))!;
    expect((t.title, t.description, t.projectId, t.sectionId, t.priority), ('Ship it', 'with notes', project, section, 1));
    expect((t.dueDate, t.dueTime, t.deadline, t.durationMinutes), ('2026-10-20', '09:30', '2026-10-31', 60));
    expect(t.createdAt.year, greaterThan(2025), reason: 'timestamps are in the unit the app reads');
    final names = [for (final l in await phone.repo.watchLabels().first) l.name]..sort();
    expect(names, ['release', 'urgent']);
    expect((await phone.repo.watchLabelLinks().first).where((l) => l.taskId == t.id).length, 2);
    expect((await phone.repo.watchComments(t.id).first).single.body, 'Remember the changelog');
    expect((await phone.repo.watchProjectTasks(project).first).single.id, t.id, reason: 'shows in the project list');
    expect((await phone.repo.watchProjects().first).map((p) => p.name), contains('Work'));
    expect((await phone.repo.watchSections(project).first).single.name, 'Soon');
  });

  test('completing from a script shows in the app as done, with a completion for the goal and Karma', () async {
    final phone = await app();
    final once = (await api('POST', '/api/v1/tasks', body: {'title': 'once', 'due_date': '2026-10-14'}))['id'] as String;
    final repeating = (await api('POST', '/api/v1/tasks', body: {'title': 'weekly', 'due_date': '2026-10-14', 'recurrence': 'every week'}))['id'] as String;
    await phone.svc.syncNow();
    await api('POST', '/api/v1/tasks/$once/close');
    await api('POST', '/api/v1/tasks/$repeating/close');
    await phone.svc.syncNow();

    expect((await phone.repo.getTask(once))!.completedAt, isNotNull);
    final weekly = (await phone.repo.getTask(repeating))!;
    expect(weekly.completedAt, isNull);
    expect(weekly.dueDate, isNot('2026-10-14'), reason: 'moved to its next date');
    final done = await phone.completionRows();
    expect(done.length, 2);
  });

  test('an edit in the app shows in the API at once after a sync', () async {
    final phone = await app();
    final id = await phone.repo.addTask(title: 'From the phone', priority: 2, dueDate: '2026-10-25');
    await phone.repo.updateTask(id, title: 'Renamed on the phone');
    await phone.svc.syncNow();
    final seen = await api('GET', '/api/v1/tasks/$id');
    expect((seen['title'], seen['priority']), ('Renamed on the phone', 2));
    expect((seen['due'] as Map)['date'], '2026-10-25');
    await phone.repo.deleteTask(id);
    await phone.svc.syncNow();
    final list = await api('GET', '/api/v1/tasks');
    expect(list['tasks'], isEmpty);
  });

  test('deleting from a script removes the task from the app list', () async {
    final phone = await app();
    final id = (await api('POST', '/api/v1/tasks', body: {'title': 'temp'}))['id'] as String;
    await phone.svc.syncNow();
    expect(await phone.repo.watchAllOpen().first, hasLength(1));
    await api('DELETE', '/api/v1/tasks/$id');
    await phone.svc.syncNow();
    expect(await phone.repo.watchAllOpen().first, isEmpty);
    expect((await phone.repo.watchTrashedTasks().first).single.id, id, reason: 'it is in the trash, like any deleted task');
  });
}

extension on ({SyncService svc, Repo repo}) {
  Future<List<Completion>> completionRows() => repo.db.select(repo.db.completions).get();
}
