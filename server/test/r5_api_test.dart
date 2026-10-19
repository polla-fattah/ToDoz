import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:taskflow_core/sync.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/hooks.dart';
import 'package:taskflow_server/ical.dart';
import 'package:taskflow_server/model.dart';
import 'package:taskflow_server/store.dart';
import 'package:test/test.dart';

class Reply {
  Reply(this.status, this.headers, this.text);
  final int status;
  final Map<String, String> headers;
  final String text;
  dynamic get json => jsonDecode(text);
}

void main() {
  late Store store;
  late Handler api;
  late DateTime now;
  late Account alice;
  late Account bob;
  late WebhookDispatcher hooks;

  setUp(() {
    now = DateTime.utc(2026, 10, 14, 9);
    store = Store.open(':memory:', clock: () => now);
    hooks = WebhookDispatcher(store, allowPrivate: true, retryDelays: const [Duration.zero, Duration.zero]);
    store.onApplied = hooks.onChanges;
    api = buildApi(store, config: const ApiConfig(trustProxy: true, allowPrivateWebhooks: true, syncPerMinute: 100000, apiPerMinute: 100000), clock: () => now, log: (l) {
      if (l.contains('internal error')) print(l);
    });
    alice = store.createUser('Alice');
    bob = store.createUser('Bob');
  });
  tearDown(() => store.close());

  Future<Reply> call(String method, String path, {Object? body, String? rawBody, String? token, Map<String, String> headers = const {}, String contentType = 'application/json'}) async {
    final h = <String, String>{
      'x-forwarded-for': '1.2.3.4',
      if (token != null) 'authorization': 'Bearer $token',
      if (body != null || rawBody != null) 'content-type': contentType,
      ...headers,
    };
    final response = await api(Request(method, Uri.parse('http://localhost$path'), headers: h, body: rawBody ?? (body == null ? null : jsonEncode(body))));
    return Reply(response.statusCode, response.headers, await response.readAsString());
  }

  Future<String> device(Account a) async {
    final r = await call('POST', '/v1/pair', body: {'code': store.createInvite(a.id), 'deviceName': 'Phone'});
    return r.json['token'] as String;
  }

  Future<String> apiToken(Account a, {bool readOnly = false, String name = 'script'}) async {
    final d = await device(a);
    final r = await call('POST', '/v1/api-tokens', token: d, body: {'name': name, 'readOnly': readOnly});
    expect(r.status, 201, reason: r.text);
    return r.json['token'] as String;
  }

  group('API tokens', () {
    test('a script with a token can list projects; no token, a wrong token or a device token cannot', () async {
      final t = await apiToken(alice);
      expect(t, startsWith('tf_'));
      expect((await call('GET', '/api/v1/projects', token: t)).status, 200);
      expect((await call('GET', '/api/v1/projects')).status, 401);
      expect((await call('GET', '/api/v1/projects', token: 'tf_${'x' * 43}')).status, 401);
      expect((await call('GET', '/api/v1/projects', token: await device(alice))).status, 401, reason: 'a device token is not an API token');
    });

    test('only a hash is stored, and the token cannot be seen again', () async {
      final t = await apiToken(alice);
      expect(store.db.select('SELECT * FROM api_tokens').first.values.join(' '), isNot(contains(t)));
      final list = await call('GET', '/v1/api-tokens', token: await device(alice));
      expect(list.text, isNot(contains(t)));
      expect(list.json['tokens'], hasLength(1));
    });

    test('a read-only token can read but not change anything', () async {
      final t = await apiToken(alice, readOnly: true);
      expect((await call('GET', '/api/v1/tasks', token: t)).status, 200);
      final w = await call('POST', '/api/v1/tasks', token: t, body: {'title': 'x'});
      expect(w.status, 403);
      expect(store.fieldCount(alice.id), 0);
    });

    test('revoking a token cuts it off at once, and one person cannot revoke another\'s', () async {
      final d = await device(alice);
      final t = (await call('POST', '/v1/api-tokens', token: d, body: {'name': 'a'})).json;
      final other = await device(bob);
      expect((await call('DELETE', '/v1/api-tokens/${t['id']}', token: other)).status, 404);
      expect((await call('GET', '/api/v1/tasks', token: t['token'] as String)).status, 200);
      expect((await call('DELETE', '/v1/api-tokens/${t['id']}', token: d)).status, 204);
      expect((await call('GET', '/api/v1/tasks', token: t['token'] as String)).status, 401);
    });

    test('each person sees only their own data', () async {
      final a = await apiToken(alice);
      final b = await apiToken(bob);
      final created = (await call('POST', '/api/v1/tasks', token: a, body: {'title': 'Alice secret'})).json;
      expect((await call('GET', '/api/v1/tasks', token: b)).json['tasks'], isEmpty);
      expect((await call('GET', '/api/v1/tasks/${created['id']}', token: b)).status, 404);
      expect((await call('POST', '/api/v1/tasks/${created['id']}/close', token: b)).status, 404);
      expect((await call('DELETE', '/api/v1/tasks/${created['id']}', token: b)).status, 404);
      expect((await call('GET', '/api/v1/tasks/${created['id']}', token: a)).json['title'], 'Alice secret');
    });
  });

  group('tasks', () {
    late String t;
    setUp(() async => t = await apiToken(alice));

    Future<Map<String, dynamic>> create(Map<String, Object?> body) async {
      final r = await call('POST', '/api/v1/tasks', token: t, body: body);
      expect(r.status, 201, reason: r.text);
      return (r.json as Map).cast<String, dynamic>();
    }

    test('create with every field, read it back', () async {
      final p = (await call('POST', '/api/v1/projects', token: t, body: {'name': 'Work'})).json['id'];
      final s = (await call('POST', '/api/v1/sections', token: t, body: {'project_id': p, 'name': 'Later'})).json['id'];
      final task = await create({
        'content': 'Write report',
        'description': 'Q3 numbers',
        'project_id': p,
        'section_id': s,
        'priority': 2,
        'due_date': '2026-10-16',
        'due_time': '14:30',
        'deadline': '2026-10-31',
        'duration_minutes': 90,
        'labels': ['work', '@urgent'],
      });
      expect(task['title'], 'Write report');
      expect(task['content'], 'Write report');
      expect((task['due'] as Map)['date'], '2026-10-16');
      expect((task['due'] as Map)['time'], '14:30');
      expect(task['labels'], ['urgent', 'work']);
      expect((task['project_id'], task['section_id'], task['priority'], task['deadline'], task['duration_minutes']), (p, s, 2, '2026-10-31', 90));
      expect(task['created_at'], '2026-10-14T09:00:00.000Z');
      final list = (await call('GET', '/api/v1/tasks?project_id=$p', token: t)).json['tasks'] as List;
      expect(list.single['id'], task['id']);
      expect(((await call('GET', '/api/v1/labels', token: t)).json['labels'] as List).map((l) => l['name']), unorderedEquals(['work', 'urgent']));
    });

    test('defaults to the Inbox and priority 4', () async {
      final task = await create({'title': 'Plain'});
      expect((task['project_id'], task['priority'], task['due']), ('inbox', 4, null));
    });

    test('a task made here reaches a device through normal sync, field for field', () async {
      final d = await device(alice);
      final task = await create({'title': 'From a script', 'due_date': '2026-10-20', 'priority': 1});
      final r = await call('POST', '/v1/sync', token: d, body: const SyncRequest(cursor: 0, changes: []).toJson());
      final changes = [for (final c in r.json['changes'] as List) SyncChange.fromJson(c)].where((c) => c.row == task['id']).toList();
      final byCol = {for (final c in changes) c.col: c.value};
      expect(byCol[presentColumn], true);
      expect((byCol['title'], byCol['due_date'], byCol['priority'], byCol['project_id']), ('From a script', '2026-10-20', 1, 'inbox'));
      expect(byCol['created_at'], now.millisecondsSinceEpoch ~/ 1000);
      for (final c in changes) {
        expect(syncSchema['tasks']!.contains(c.col) || c.col == presentColumn, isTrue, reason: 'column ${c.col} must be one the app knows');
      }
    });

    test('rejects what the app would reject', () async {
      Future<void> bad(Map<String, Object?> body, [String? hint]) async {
        final r = await call('POST', '/api/v1/tasks', token: t, body: {'title': 'x', ...body});
        expect(r.status, anyOf(400, 404), reason: '$body → ${r.text}');
        if (hint != null) expect(r.text, contains(hint));
      }

      expect((await call('POST', '/api/v1/tasks', token: t, body: {'title': '   '})).status, 400);
      expect((await call('POST', '/api/v1/tasks', token: t, body: {})).status, 400);
      await bad({'title': 'x' * 501}, '500');
      await bad({'priority': 9}, 'priority');
      await bad({'priority': '1'}, 'priority');
      await bad({'due_date': '2026-02-31'}, 'due_date');
      await bad({'due_date': '2026-10-16', 'due_time': '25:00'}, 'due_time');
      await bad({'due_time': '09:00'}, 'needs a due_date');
      await bad({'due_date': '2026-10-16', 'recurrence': 'every blue moon'}, 'repeat');
      await bad({'deadline': 'soon'}, 'deadline');
      await bad({'duration_minutes': 0}, 'duration');
      await bad({'project_id': 'nope'}, 'project');
      await bad({'parent_id': 'nope'}, 'parent');
      await bad({'labels': 'work'}, 'labels');
      expect(((await call('GET', '/api/v1/tasks', token: t)).json['tasks'] as List), isEmpty, reason: 'nothing half-created');
    });

    test('sub-tasks nest at most four levels and inherit the project', () async {
      final p = (await call('POST', '/api/v1/projects', token: t, body: {'name': 'P'})).json['id'];
      var parent = (await create({'title': 'L1', 'project_id': p}))['id'];
      for (var i = 2; i <= 4; i++) {
        final k = await create({'title': 'L$i', 'parent_id': parent});
        expect(k['project_id'], p);
        parent = k['id'];
      }
      final tooDeep = await call('POST', '/api/v1/tasks', token: t, body: {'title': 'L5', 'parent_id': parent});
      expect(tooDeep.status, 400);
    });

    test('update changes only what is sent, clears with null, and moving takes sub-tasks along', () async {
      final p = (await call('POST', '/api/v1/projects', token: t, body: {'name': 'Other'})).json['id'];
      final parent = await create({'title': 'Parent', 'due_date': '2026-10-16', 'due_time': '09:00', 'priority': 3});
      final kid = await create({'title': 'Kid', 'parent_id': parent['id']});
      var r = await call('POST', '/api/v1/tasks/${parent['id']}', token: t, body: {'title': 'Renamed'});
      expect((r.json['title'], r.json['priority'], (r.json['due'] as Map)['time']), ('Renamed', 3, '09:00'));
      r = await call('POST', '/api/v1/tasks/${parent['id']}', token: t, body: {'due_date': null});
      expect((r.json['due'], r.status), (null, 200), reason: 'clearing the date clears its time too');
      r = await call('POST', '/api/v1/tasks/${parent['id']}', token: t, body: {'project_id': p});
      expect(r.json['project_id'], p);
      expect((await call('GET', '/api/v1/tasks/${kid['id']}', token: t)).json['project_id'], p);
      expect((await call('POST', '/api/v1/tasks/${parent['id']}', token: t, body: {'parent_id': kid['id']})).status, 400, reason: 'a task cannot go inside its own sub-task');
    });

    test('close completes a task and logs it; reopen undoes both', () async {
      final task = await create({'title': 'Do it', 'due_date': '2026-10-14'});
      final closed = await call('POST', '/api/v1/tasks/${task['id']}/close', token: t);
      expect(closed.json['is_completed'], true);
      expect(closed.json['completed_at'], '2026-10-14T09:00:00.000Z');
      expect(((await call('GET', '/api/v1/tasks', token: t)).json['tasks'] as List), isEmpty);
      expect(((await call('GET', '/api/v1/tasks?include_completed=true', token: t)).json['tasks'] as List), hasLength(1));
      final done = (await call('GET', '/api/v1/completed', token: t)).json['items'] as List;
      expect((done.single['title'], done.single['due_date']), ('Do it', '2026-10-14'));
      final reopened = await call('POST', '/api/v1/tasks/${task['id']}/reopen', token: t);
      expect(reopened.json['is_completed'], false);
      expect(((await call('GET', '/api/v1/completed', token: t)).json['items'] as List), isEmpty);
    });

    test('closing a repeating task moves it to its next date instead', () async {
      final task = await create({'title': 'Gym', 'due_date': '2026-10-14', 'due_time': '07:00', 'recurrence': 'every mon, fri at 7am'});
      final r = await call('POST', '/api/v1/tasks/${task['id']}/close', token: t);
      expect(r.json['is_completed'], false);
      expect((r.json['due'] as Map)['date'], '2026-10-16', reason: 'the next Friday after Wednesday the 14th');
      expect(((await call('GET', '/api/v1/completed', token: t)).json['items'] as List), hasLength(1));
    });

    test('delete trashes a task and its sub-tasks; they stop appearing', () async {
      final parent = await create({'title': 'P'});
      await create({'title': 'K', 'parent_id': parent['id']});
      expect((await call('DELETE', '/api/v1/tasks/${parent['id']}', token: t)).status, 204);
      expect(((await call('GET', '/api/v1/tasks', token: t)).json['tasks'] as List), isEmpty);
      expect((await call('GET', '/api/v1/tasks/${parent['id']}', token: t)).status, 404);
    });

    test('filtering by label, due date and parent', () async {
      await create({'title': 'a', 'labels': ['x'], 'due_date': '2026-10-15'});
      await create({'title': 'b', 'labels': ['y']});
      Future<List> titles(String q) async => ((await call('GET', '/api/v1/tasks$q', token: t)).json['tasks'] as List).map((e) => e['title']).toList();
      expect(await titles('?label=X'), ['a']);
      expect(await titles('?due_date=2026-10-15'), ['a']);
      expect(await titles(''), ['a', 'b']);
    });

    test('comments, sections, projects and labels', () async {
      final task = await create({'title': 'T'});
      final c = (await call('POST', '/api/v1/comments', token: t, body: {'task_id': task['id'], 'content': 'a note'})).json;
      expect(((await call('GET', '/api/v1/comments?task_id=${task['id']}', token: t)).json['comments'] as List).single['content'], 'a note');
      expect((await call('POST', '/api/v1/comments', token: t, body: {'task_id': task['id'], 'content': ' '})).status, 400);
      expect((await call('DELETE', '/api/v1/comments/${c['id']}', token: t)).status, 204);
      expect(((await call('GET', '/api/v1/comments?task_id=${task['id']}', token: t)).json['comments'] as List), isEmpty);

      final p = (await call('POST', '/api/v1/projects', token: t, body: {'name': 'Home', 'color': 0xFF123456})).json['id'];
      expect((await call('POST', '/api/v1/projects/$p', token: t, body: {'name': 'House', 'is_favorite': true})).json['name'], 'House');
      expect((await call('POST', '/api/v1/projects/inbox', token: t, body: {'name': 'x'})).status, 400);
      expect((await call('DELETE', '/api/v1/projects/inbox', token: t)).status, 400);
      final moved = await create({'title': 'in home', 'project_id': p});
      expect((await call('DELETE', '/api/v1/projects/$p', token: t)).status, 204);
      expect((await call('GET', '/api/v1/tasks/${moved['id']}', token: t)).json['project_id'], 'inbox', reason: 'its tasks go to the Inbox');
      final lab = (await call('POST', '/api/v1/labels', token: t, body: {'name': 'errands'})).json;
      expect((await call('POST', '/api/v1/labels', token: t, body: {'name': 'Errands'})).json['id'], lab['id'], reason: 'same name, same label');
      expect((await call('DELETE', '/api/v1/labels/${lab['id']}', token: t)).status, 204);
    });

    test('a later edit from a device beats an API edit, and an API edit beats an older one', () async {
      final d = await device(alice);
      final task = await create({'title': 'Original'});
      // Older than "now": the API's edit wins.
      final old = SyncChange(table: 'tasks', row: task['id'] as String, col: 'title', value: 'device (old)', hlc: formatHlc(now.millisecondsSinceEpoch - 5000, 0, 'phone'));
      await call('POST', '/v1/sync', token: d, body: SyncRequest(cursor: 0, changes: [old]).toJson());
      expect((await call('GET', '/api/v1/tasks/${task['id']}', token: t)).json['title'], 'Original');
      await call('POST', '/api/v1/tasks/${task['id']}', token: t, body: {'title': 'From API'});
      expect((await call('GET', '/api/v1/tasks/${task['id']}', token: t)).json['title'], 'From API');
      // A device edit made after the API's: it wins.
      final fresh = SyncChange(table: 'tasks', row: task['id'] as String, col: 'title', value: 'device (new)', hlc: formatHlc(now.millisecondsSinceEpoch + 60000, 0, 'phone'));
      await call('POST', '/v1/sync', token: d, body: SyncRequest(cursor: 0, changes: [fresh]).toJson());
      expect((await call('GET', '/api/v1/tasks/${task['id']}', token: t)).json['title'], 'device (new)');
      // And an API edit straight after beats even that.
      await call('POST', '/api/v1/tasks/${task['id']}', token: t, body: {'title': 'API again'});
      expect((await call('GET', '/api/v1/tasks/${task['id']}', token: t)).json['title'], 'API again');
    });
  });

  group('outgoing webhooks', () {
    late HttpServer receiver;
    late List<({Map<String, String> headers, String body})> received;
    var respondWith = 200;

    setUp(() async {
      received = [];
      respondWith = 200;
      receiver = await io.serve((Request r) async {
        received.add((headers: r.headers, body: await r.readAsString()));
        return Response(respondWith);
      }, InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async => receiver.close(force: true));

    String url() => 'http://127.0.0.1:${receiver.port}/hook';

    Future<Map<String, dynamic>> register(String deviceToken, {List<String>? events}) async {
      final r = await call('POST', '/v1/webhooks', token: deviceToken, body: {'url': url(), 'events': ?events});
      expect(r.status, 201, reason: r.text);
      return (r.json as Map).cast<String, dynamic>();
    }

    test('a call is signed so the receiver can check who sent it and when', () async {
      final d = await device(alice);
      final hook = await register(d);
      final t = await apiToken(alice);
      await call('POST', '/api/v1/tasks', token: t, body: {'title': 'Signed'});
      await hooks.flush();
      expect(received, hasLength(1));
      final msg = received.single;
      final ts = int.parse(msg.headers['x-taskflow-timestamp']!);
      expect(msg.headers['x-taskflow-signature'], signPayload(hook['secret'] as String, ts, msg.body));
      expect(msg.headers['x-taskflow-event'], 'task.added');
      final payload = jsonDecode(msg.body) as Map;
      expect((payload['event'], (payload['data'] as Map)['title']), ('task.added', 'Signed'));
      expect(verifySignedCall(secret: hook['secret'] as String, timestamp: '$ts', signature: msg.headers['x-taskflow-signature'], body: msg.body, now: now), isNull);
      expect(verifySignedCall(secret: 'other', timestamp: '$ts', signature: msg.headers['x-taskflow-signature'], body: msg.body, now: now), isNotNull);
      expect(verifySignedCall(secret: hook['secret'] as String, timestamp: '$ts', signature: msg.headers['x-taskflow-signature'], body: '${msg.body} ', now: now), isNotNull, reason: 'tampered body');
      expect(verifySignedCall(secret: hook['secret'] as String, timestamp: '$ts', signature: msg.headers['x-taskflow-signature'], body: msg.body, now: now.add(const Duration(minutes: 6))), isNotNull, reason: 'too old');
    });

    test('events: added, completed, uncompleted, updated, deleted, and edits made on a device count too', () async {
      final d = await device(alice);
      await register(d);
      final t = await apiToken(alice);
      final task = (await call('POST', '/api/v1/tasks', token: t, body: {'title': 'Life of a task'})).json;
      await call('POST', '/api/v1/tasks/${task['id']}', token: t, body: {'priority': 1});
      await call('POST', '/api/v1/tasks/${task['id']}/close', token: t);
      await call('POST', '/api/v1/tasks/${task['id']}/reopen', token: t);
      // An edit from the phone:
      await call('POST', '/v1/sync', token: d, body: SyncRequest(cursor: 0, changes: [SyncChange(table: 'tasks', row: task['id'] as String, col: 'title', value: 'Renamed on phone', hlc: formatHlc(now.millisecondsSinceEpoch + 5000, 0, 'phone'))]).toJson());
      await call('DELETE', '/api/v1/tasks/${task['id']}', token: t);
      await hooks.flush();
      expect(received.map((m) => m.headers['x-taskflow-event']), ['task.added', 'task.updated', 'task.completed', 'task.uncompleted', 'task.updated', 'task.deleted']);
      expect((jsonDecode(received[4].body) as Map)['data']['title'], 'Renamed on phone');
    });

    test('a webhook can ask for only some events, and one person\'s events never go to another\'s webhook', () async {
      final d = await device(alice);
      await register(d, events: ['task.completed']);
      final bobDevice = await device(bob);
      await register(bobDevice, events: ['*']);
      final t = await apiToken(alice);
      final task = (await call('POST', '/api/v1/tasks', token: t, body: {'title': 'x'})).json;
      await call('POST', '/api/v1/tasks/${task['id']}/close', token: t);
      await hooks.flush();
      // Alice's hook got only the completion; Bob's hook is the same receiver here, so Bob's events would show as extra calls.
      expect(received.map((m) => m.headers['x-taskflow-event']), ['task.completed']);
    });

    test('a receiver that keeps failing is counted and finally switched off; a refusal is not retried', () async {
      final d = await device(alice);
      final hook = await register(d);
      respondWith = 500;
      final t = await apiToken(alice);
      await call('POST', '/api/v1/tasks', token: t, body: {'title': 'one'});
      await hooks.flush();
      expect(received.length, 2, reason: 'tried twice (the test uses two attempts)');
      var row = store.listWebhooks(alice.id).single;
      expect((row['failures'], row['lastStatus'], row['active']), (1, '500', true));
      received.clear();
      respondWith = 403;
      await call('POST', '/api/v1/tasks', token: t, body: {'title': 'two'});
      await hooks.flush();
      expect(received.length, 1, reason: 'a 4xx is a refusal: no retry');
      for (var i = 0; i < 20; i++) {
        store.recordWebhookResult(hook['id'] as String, ok: false, status: '500');
      }
      row = store.listWebhooks(alice.id).single;
      expect(row['active'], false);
      expect((await call('POST', '/v1/webhooks/${hook['id']}/reactivate', token: d)).status, 204);
      expect(store.listWebhooks(alice.id).single['active'], true);
    });

    test('addresses that point inside a private network are refused (unless the server owner allows them)', () async {
      final strict = buildApi(store, config: const ApiConfig(trustProxy: true), clock: () => now);
      final d = await device(alice);
      Future<Reply> post(String url) async => Reply(
            (await strict(Request('POST', Uri.parse('http://x/v1/webhooks'), headers: {'authorization': 'Bearer $d', 'content-type': 'application/json'}, body: jsonEncode({'url': url})))).statusCode,
            const {},
            '',
          );
      expect((await post('http://example.com/hook')).status, 400, reason: 'https only');
      expect((await post('https://127.0.0.1/hook')).status, 400);
      expect((await post('https://localhost/hook')).status, 400);
      expect((await post('https://192.168.1.10/hook')).status, 400);
      expect((await post('https://10.0.0.5/hook')).status, 400);
      expect((await post('https://169.254.169.254/latest/meta-data')).status, 400, reason: 'cloud metadata address');
      expect((await post('https://[::1]/hook')).status, 400);
      expect((await post('https://user:pass@example.com/hook')).status, 400);
      expect((await post('not a url')).status, 400);
      expect(isPrivateAddress(InternetAddress('100.64.1.1')), isTrue);
      expect(isPrivateAddress(InternetAddress('8.8.8.8')), isFalse);
      expect(isPrivateAddress(InternetAddress('fd00::1')), isTrue);
    });

    test('delivery re-checks the address, so a name that later points inside is not called', () async {
      final strictHooks = WebhookDispatcher(store, allowPrivate: false, retryDelays: const [Duration.zero], lookup: (h) async => [InternetAddress('10.1.2.3')]);
      store.onApplied = strictHooks.onChanges;
      store.db.execute("INSERT INTO webhooks(id, user_id, url, secret, events, created_at) VALUES ('w1', ?, 'https://rebind.example.com/x', 's', '*', 0)", [alice.id]);
      final t = await apiToken(alice);
      await call('POST', '/api/v1/tasks', token: t, body: {'title': 'x'});
      await strictHooks.flush();
      expect(received, isEmpty);
      expect(store.listWebhooks(alice.id).single['lastStatus'], startsWith('blocked'));
    });

    test('too many webhooks and bad event names are refused', () async {
      final d = await device(alice);
      expect((await call('POST', '/v1/webhooks', token: d, body: {'url': url(), 'events': ['task.exploded']})).status, 400);
      for (var i = 0; i < 10; i++) {
        expect((await call('POST', '/v1/webhooks', token: d, body: {'url': url()})).status, 201);
      }
      expect((await call('POST', '/v1/webhooks', token: d, body: {'url': url()})).status, 400);
    });
  });

  group('incoming webhook', () {
    late String hookId;
    late String secret;

    setUp(() async {
      final d = await device(alice);
      final r = await call('POST', '/v1/inbound-hooks', token: d, body: {'name': 'IFTTT'});
      expect(r.status, 201, reason: r.text);
      hookId = r.json['id'] as String;
      secret = r.json['secret'] as String;
    });

    Future<Reply> send(String body, {int? timestamp, String? signature, String? id, Map<String, String> extra = const {}, String contentType = 'application/json'}) {
      final ts = timestamp ?? now.millisecondsSinceEpoch ~/ 1000;
      return call('POST', '/hooks/in/${id ?? hookId}', rawBody: body, contentType: contentType, headers: {
        'x-taskflow-timestamp': '$ts',
        'x-taskflow-signature': signature ?? signPayload(secret, ts, body),
        ...extra,
      });
    }

    test('a signed call makes a task from a Quick Add line', () async {
      final r = await send(jsonEncode({'text': 'Buy milk tomorrow at 4pm p1 %errands'}));
      expect(r.status, 201, reason: r.text);
      expect((r.json['title'], r.json['priority']), ('Buy milk', 1));
      expect(r.json['labels'], ['errands']);
      expect((r.json['due'] as Map)['date'], '2026-10-15');
      expect((r.json['due'] as Map)['time'], '16:00');
      final t = await apiToken(alice);
      expect(((await call('GET', '/api/v1/tasks', token: t)).json['tasks'] as List), hasLength(1));
    });

    test('plain text works, and the sender can say what time zone to use', () async {
      // 23:30 UTC on the 14th is already the 15th at UTC+2, so "today" means the 15th.
      now = DateTime.utc(2026, 10, 14, 23, 30);
      final r = await send('Pay rent today', contentType: 'text/plain', extra: {'x-taskflow-utc-offset-minutes': '120'});
      expect(r.status, 201, reason: r.text);
      expect((r.json['due'] as Map)['date'], '2026-10-15');
    });

    test('a wrong signature, an unknown hook, a stale timestamp and a replay are all refused', () async {
      final body = jsonEncode({'text': 'x'});
      expect((await send(body, signature: 'sha256=${'0' * 64}')).status, 401);
      expect((await send(body, id: 'doesnotexist')).status, 401);
      expect((await send(body, timestamp: now.millisecondsSinceEpoch ~/ 1000 - 3600)).status, 401);
      expect((await send(body, signature: signPayload('wrong secret', now.millisecondsSinceEpoch ~/ 1000, body))).status, 401);
      final t = await apiToken(alice);
      expect(((await call('GET', '/api/v1/tasks', token: t)).json['tasks'] as List), isEmpty, reason: 'nothing was created');
      expect((await send(body)).status, 201);
      expect((await send(body)).status, 409, reason: 'the identical signed call, replayed');
    });

    test('a body that is too big, or has no text, is refused', () async {
      expect((await send('x' * 20000, contentType: 'text/plain')).status, 413);
      expect((await send(jsonEncode({'nope': 1}))).status, 400);
      expect((await send('   ', contentType: 'text/plain')).status, 400);
    });

    test('a hook only ever writes to its own owner', () async {
      final t = await apiToken(bob);
      await send(jsonEncode({'text': 'for alice'}));
      expect(((await call('GET', '/api/v1/tasks', token: t)).json['tasks'] as List), isEmpty);
    });
  });

  group('calendar feed', () {
    test('lists dated open tasks as events, at their time or all day, and deadlines too', () async {
      final t = await apiToken(alice);
      Future<void> make(Map<String, Object?> b) async => expect((await call('POST', '/api/v1/tasks', token: t, body: b)).status, 201);
      await make({'title': 'Dentist, 2nd floor; bring card', 'due_date': '2026-10-20', 'due_time': '09:30', 'duration_minutes': 45, 'description': 'Line one\nLine two', 'priority': 1, 'labels': ['health']});
      await make({'title': 'All day thing', 'due_date': '2026-10-21'});
      await make({'title': 'With deadline', 'deadline': '2026-11-01'});
      await make({'title': 'No date'});
      final done = (await call('POST', '/api/v1/tasks', token: t, body: {'title': 'Finished', 'due_date': '2026-10-22'})).json;
      await call('POST', '/api/v1/tasks/${done['id']}/close', token: t);

      final d = await device(alice);
      final link = (await call('POST', '/v1/calendar', token: d)).json['path'] as String;
      final r = await call('GET', link);
      expect(r.status, 200);
      expect(r.headers['content-type'], startsWith('text/calendar'));
      final ics = r.text.replaceAll('\r\n ', ''); // unfold
      expect(ics, contains('BEGIN:VCALENDAR'));
      expect(ics, contains('SUMMARY:Dentist\\, 2nd floor\\; bring card'));
      expect(ics, contains('DTSTART:20261020T093000'));
      expect(ics, contains('DTEND:20261020T101500'), reason: '45 minutes long');
      expect(ics, contains('DESCRIPTION:Line one\\nLine two'));
      expect(ics, contains('CATEGORIES:health'));
      expect(ics, contains('PRIORITY:1'));
      expect(ics, contains('DTSTART;VALUE=DATE:20261021'));
      expect(ics, contains('DTEND;VALUE=DATE:20261022'));
      expect(ics, contains('SUMMARY:Deadline: With deadline'));
      expect(ics, contains('DTSTART;VALUE=DATE:20261101'));
      expect(ics, isNot(contains('No date')));
      expect(ics, isNot(contains('Finished')));
      expect('BEGIN:VEVENT'.allMatches(ics).length, 3, reason: 'the timed task, the all-day task, and the deadline');
      for (final line in r.text.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75), reason: 'folded: $line');
      }
    });

    test('long lines fold without cutting a character in half', () {
      final folded = foldLine('SUMMARY:${'é' * 80}');
      for (final part in folded.split('\r\n')) {
        expect(utf8.encode(part).length, lessThanOrEqualTo(75));
      }
      expect(folded.replaceAll('\r\n ', ''), 'SUMMARY:${'é' * 80}');
    });

    test('the link is secret: a wrong one finds nothing, a new one replaces the old, deleting turns it off', () async {
      final d = await device(alice);
      expect((await call('GET', '/v1/calendar', token: d)).json['enabled'], false);
      final first = (await call('POST', '/v1/calendar', token: d)).json['path'] as String;
      expect((await call('GET', first)).status, 200);
      expect((await call('GET', '/ical/${'a' * 43}.ics')).status, 404);
      expect((await call('GET', first.replaceAll('.ics', ''))).status, 404);
      final second = (await call('POST', '/v1/calendar', token: d)).json['path'] as String;
      expect(second, isNot(first));
      expect((await call('GET', first)).status, 404, reason: 'the old link stops working');
      expect((await call('GET', second)).status, 200);
      expect((await call('DELETE', '/v1/calendar', token: d)).status, 204);
      expect((await call('GET', second)).status, 404);
    });

    test('a feed shows only its own owner\'s tasks', () async {
      final ta = await apiToken(alice);
      await call('POST', '/api/v1/tasks', token: ta, body: {'title': 'Alice only', 'due_date': '2026-10-20'});
      final link = (await call('POST', '/v1/calendar', token: await device(bob))).json['path'] as String;
      expect((await call('GET', link)).text, isNot(contains('Alice only')));
    });

    test('the token is stored only as a hash', () async {
      final d = await device(alice);
      final link = (await call('POST', '/v1/calendar', token: d)).json['path'] as String;
      final token = link.substring('/ical/'.length, link.length - 4);
      expect(store.db.select('SELECT * FROM calendar_feeds').first.values.join(' '), isNot(contains(token)));
      expect(sha256.convert(utf8.encode(token)).toString(), store.db.select('SELECT token_hash FROM calendar_feeds').first['token_hash']);
    });
  });

  test('deleting an account removes its tokens, hooks and calendar link', () async {
    final d = await device(alice);
    await call('POST', '/v1/api-tokens', token: d, body: {'name': 'x'});
    await call('POST', '/v1/webhooks', token: d, body: {'url': 'http://127.0.0.1:9/x'});
    await call('POST', '/v1/inbound-hooks', token: d, body: {'name': 'x'});
    await call('POST', '/v1/calendar', token: d);
    final r = await call('POST', '/v1/me/delete', token: d, body: {'confirm': 'DELETE MY DATA'});
    expect(r.status, 204);
    for (final t in ['api_tokens', 'webhooks', 'inbound_hooks', 'calendar_feeds']) {
      expect(store.db.select('SELECT COUNT(*) AS n FROM $t').first['n'], 0, reason: t);
    }
  });

  test('the model helper makes valid ids and refuses to touch the Inbox project', () {
    final id = UserModel.newId();
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(id), isTrue);
    expect(() => UserModel(store, alice.id).deleteProject(inboxId), throwsA(isA<ModelError>()));
  });
}
