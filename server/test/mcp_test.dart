import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';
import 'package:test/test.dart';

class Reply {
  Reply(this.status, this.headers, this.text);
  final int status;
  final Map<String, String> headers;
  final String text;
  dynamic get json => jsonDecode(text);
}

/// The remote MCP server at /mcp: what Claude, ChatGPT and Gemini talk to.
void main() {
  late Store store;
  late Handler api;
  late DateTime now;
  late Account alice;
  late Account bob;
  late List<String> logs;

  setUp(() {
    now = DateTime.utc(2026, 10, 19, 9);
    store = Store.open(':memory:', clock: () => now);
    logs = [];
    api = buildApi(store, config: const ApiConfig(trustProxy: true, apiPerMinute: 100000), clock: () => now, log: logs.add);
    alice = store.createUser('Alice');
    bob = store.createUser('Bob');
  });
  tearDown(() => store.close());

  String tokenFor(Account a, {bool readOnly = false}) => store.createApiToken(a.id, 'Claude connector', readOnly: readOnly).token;

  Future<Reply> post(String path, Object? body, {String? token, String ip = '1.2.3.4', String type = 'application/json'}) async {
    final response = await api(Request(
      'POST',
      Uri.parse('http://localhost$path'),
      headers: {'x-forwarded-for': ip, 'content-type': type, 'authorization': ?(token == null ? null : 'Bearer $token')},
      body: body is String ? body : jsonEncode(body),
    ));
    return Reply(response.statusCode, response.headers, await response.readAsString());
  }

  Map<String, Object?> rpc(String method, [Map<String, Object?>? params, int id = 1]) => {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params};

  Future<Map<String, dynamic>> call(String token, String tool, [Map<String, Object?> args = const {}]) async {
    final r = await post('/mcp', rpc('tools/call', {'name': tool, 'arguments': args}), token: token);
    expect(r.status, 200, reason: r.text);
    return r.json['result'] as Map<String, dynamic>;
  }

  Object? payload(Map<String, dynamic> result) => jsonDecode((result['content'] as List).single['text'] as String);

  group('the handshake', () {
    test('initialize answers with the protocol version it shares, its name and the tools capability', () async {
      final t = tokenFor(alice);
      final r = await post('/mcp', rpc('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'x', 'version': '1'}}), token: t);
      expect(r.status, 200);
      expect(r.headers['content-type'], startsWith('application/json'));
      final result = r.json['result'];
      expect(r.json['id'], 1);
      expect(result['protocolVersion'], '2025-03-26');
      expect(result['serverInfo']['name'], 'todoz');
      expect(result['capabilities'], containsPair('tools', isA<Map>()));
      expect(result['instructions'], contains('local_now'));
    });

    test('an unknown protocol version gets the newest one this server speaks', () async {
      final r = await post('/mcp', rpc('initialize', {'protocolVersion': '2099-01-01'}), token: tokenFor(alice));
      expect(r.json['result']['protocolVersion'], '2025-06-18');
    });

    test('a notification gets 202 and no body; ping answers; an unknown method is a JSON-RPC error', () async {
      final t = tokenFor(alice);
      final n = await post('/mcp', {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, token: t);
      expect(n.status, 202);
      expect(n.text, isEmpty);
      expect((await post('/mcp', rpc('ping'), token: t)).json['result'], isEmpty);
      final bad = await post('/mcp', rpc('resources/list', null, 7), token: t);
      expect(bad.json['id'], 7);
      expect(bad.json['error']['code'], -32601);
    });

    test('a batch is answered in one array, leaving out the notifications', () async {
      final t = tokenFor(alice);
      final r = await post('/mcp', [rpc('ping', null, 1), {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, rpc('tools/list', null, 2)], token: t);
      expect(r.status, 200);
      expect((r.json as List).map((e) => e['id']), [1, 2]);
      expect((await post('/mcp', [{'jsonrpc': '2.0', 'method': 'notifications/initialized'}], token: t)).status, 202);
    });

    test('bad JSON, a non-object and an empty batch are protocol errors, not crashes', () async {
      final t = tokenFor(alice);
      expect((await post('/mcp', '{nope', token: t)).json['error']['code'], -32700);
      expect((await post('/mcp', '5', token: t)).json['error']['code'], -32600);
      expect((await post('/mcp', '[]', token: t)).status, 400);
      expect((await post('/mcp', {'method': 'ping', 'id': 1}, token: t)).json['error']['code'], -32600, reason: 'jsonrpc is required');
    });

    test('GET and DELETE are refused politely (no stream of its own), and a huge body is refused', () async {
      for (final method in ['GET', 'DELETE']) {
        final r = await api(Request(method, Uri.parse('http://localhost/mcp'), headers: {'x-forwarded-for': '1.2.3.4'}));
        expect(r.statusCode, 405);
        expect(r.headers['allow'], 'POST');
      }
      final big = await post('/mcp', jsonEncode(rpc('ping', {'pad': 'x' * 300000})), token: tokenFor(alice));
      expect(big.status, 413);
    });
  });

  group('who may call it', () {
    test('no token, a wrong token and a device token are all refused with 401', () async {
      expect((await post('/mcp', rpc('ping'))).status, 401);
      expect((await post('/mcp', rpc('ping'), token: 'tf_${'a' * 30}')).status, 401);
      final device = store.createInvite(alice.id);
      expect((await post('/mcp', rpc('ping'), token: device)).status, 401);
    });

    test('the token can be in the address instead, for apps that cannot send a header', () async {
      final t = tokenFor(alice);
      final r = await post('/mcp/$t', rpc('tools/list'));
      expect(r.status, 200);
      expect(r.json['result']['tools'], isNotEmpty);
      expect((await post('/mcp/tf_${'b' * 30}', rpc('ping'))).status, 401);
      expect((await post('/mcp/not-a-token', rpc('ping'))).status, 401);
    });

    test('the secret address is never written to the log', () async {
      final t = tokenFor(alice);
      await post('/mcp/$t', rpc('ping'));
      await post('/mcp/tf_${'z' * 30}', rpc('ping'));
      expect(logs, isNotEmpty);
      expect(logs.where((l) => l.contains(t) || l.contains('z' * 30)), isEmpty);
      expect(logs.where((l) => l.contains('/mcp/...')), isNotEmpty);
    });

    test('guessing secret addresses is limited per caller address', () async {
      var last = 0;
      for (var i = 0; i < 25; i++) {
        last = (await post('/mcp/tf_${'q${i.toString().padLeft(2, '0')}' * 10}', rpc('ping'), ip: '6.6.6.6')).status;
      }
      expect(last, 429);
      expect((await post('/mcp/${tokenFor(alice)}', rpc('ping'), ip: '7.7.7.7')).status, 200, reason: 'another address is not affected');
    });

    test('a revoked token stops working', () async {
      final made = store.createApiToken(alice.id, 'Claude connector');
      expect((await post('/mcp', rpc('ping'), token: made.token)).status, 200);
      store.revokeApiToken(alice.id, made.id);
      expect((await post('/mcp', rpc('ping'), token: made.token)).status, 401);
    });
  });

  group('the tools', () {
    late String t;
    setUp(() => t = tokenFor(alice));

    test('lists the five tools with schemas; a read-only token sees only the ones that read', () async {
      final all = (await post('/mcp', rpc('tools/list'), token: t)).json['result']['tools'] as List;
      expect(all.map((e) => e['name']), unorderedEquals(['add_task', 'parse_preview', 'list_projects', 'list_tasks', 'complete_task']));
      for (final tool in all) {
        expect(tool['inputSchema']['type'], 'object');
        expect(tool['description'], isNotEmpty);
      }
      final ro = (await post('/mcp', rpc('tools/list'), token: tokenFor(alice, readOnly: true))).json['result']['tools'] as List;
      expect(ro.map((e) => e['name']), unorderedEquals(['parse_preview', 'list_projects', 'list_tasks']));
    });

    test('add_task reads the Quick Add line, in the owner\'s time when local_now is given', () async {
      final r = await call(t, 'add_task', {'text': 'Call mum tomorrow 17:00 p1 %family', 'local_now': '2026-10-19T23:30'});
      expect(r['isError'], isNull);
      final created = (payload(r) as Map)['created'] as Map;
      expect(created['title'], 'Call mum');
      expect(created['priority'], 1);
      expect(created['due'], {'date': '2026-10-20', 'time': '17:00', 'recurrence': null});
      expect(created['labels'], ['family']);
      expect(created['project_id'], 'inbox');
    });

    test('add_task takes a project by name or id, and says which exist when it is wrong', () async {
      final p = (await post('/api/v1/projects', {'name': 'Research'}, token: t)).json['id'] as String;
      expect(((payload(await call(t, 'add_task', {'text': 'Read paper', 'project': 'research'})) as Map)['created'] as Map)['project_id'], p);
      expect(((payload(await call(t, 'add_task', {'text': 'Read more', 'project': p})) as Map)['created'] as Map)['project_id'], p);
      final bad = await call(t, 'add_task', {'text': 'x', 'project': 'Nowhere'});
      expect(bad['isError'], true);
      expect((bad['content'] as List).single['text'], allOf(contains('No project called "Nowhere"'), contains('Research')));
    });

    test('what the tool adds is on the REST API and the other way round, for that owner only', () async {
      await call(t, 'add_task', {'text': 'From the assistant'});
      await post('/api/v1/tasks', {'title': 'From a script'}, token: t);
      final tasks = (payload(await call(t, 'list_tasks')) as Map)['tasks'] as List;
      expect(tasks.map((e) => e['title']), containsAll(['From the assistant', 'From a script']));
      final bobs = (payload(await call(tokenFor(bob), 'list_tasks')) as Map)['count'];
      expect(bobs, 0);
    });

    test('list_tasks filters by date and label, and refuses a badly written date', () async {
      await call(t, 'add_task', {'text': 'Pay rent 2026-10-25 %money'});
      await call(t, 'add_task', {'text': 'Tidy desk'});
      final byDate = payload(await call(t, 'list_tasks', {'due_date': '2026-10-25'})) as Map;
      expect((byDate['tasks'] as List).map((e) => e['title']), ['Pay rent']);
      final byLabel = payload(await call(t, 'list_tasks', {'label': 'money'})) as Map;
      expect(byLabel['count'], 1);
      final bad = await call(t, 'list_tasks', {'due_date': 'tomorrow'});
      expect(bad['isError'], true);
    });

    test('list_projects leaves out archived ones and includes the Inbox', () async {
      await post('/api/v1/projects', {'name': 'Home'}, token: t);
      final old = (await post('/api/v1/projects', {'name': 'Old'}, token: t)).json['id'];
      await post('/api/v1/projects/$old', {'is_archived': true}, token: t);
      final names = ((payload(await call(t, 'list_projects')) as Map)['projects'] as List).map((e) => e['name']);
      expect(names, containsAll(['Inbox', 'Home']));
      expect(names, isNot(contains('Old')));
    });

    test('parse_preview saves nothing', () async {
      final r = payload(await call(t, 'parse_preview', {'text': 'Plan trip tomorrow p2 %travel', 'local_now': '2026-10-19T09:00'})) as Map;
      expect(r, isNot(contains('tokens')));
      expect(jsonEncode(r), contains('Plan trip'));
      expect((payload(await call(t, 'list_tasks')) as Map)['count'], 0);
    });

    test('complete_task closes a task; an unknown id is a tool error, not a crash', () async {
      final id = (((payload(await call(t, 'add_task', {'text': 'Water plants'})) as Map)['created']) as Map)['id'];
      final done = payload(await call(t, 'complete_task', {'task_id': id})) as Map;
      expect(done['completed']['is_completed'], true);
      expect((payload(await call(t, 'list_tasks')) as Map)['count'], 0);
      final missing = await call(t, 'complete_task', {'task_id': 'nope'});
      expect(missing['isError'], true);
      expect((missing['content'] as List).single['text'], contains('No such task'));
    });

    test('a read-only token can look but add and complete come back as a tool error that says what to do', () async {
      final ro = tokenFor(alice, readOnly: true);
      expect((payload(await call(ro, 'list_projects')) as Map)['projects'], isNotEmpty);
      final r = await call(ro, 'add_task', {'text': 'Nope'});
      expect(r['isError'], true);
      expect((r['content'] as List).single['text'], contains('read-only'));
      expect((await call(ro, 'complete_task', {'task_id': 'x'}))['isError'], true);
      expect((payload(await call(t, 'list_tasks')) as Map)['count'], 0);
    });

    test('wrong arguments are tool errors with a plain message', () async {
      for (final args in [
        <String, Object?>{},
        {'text': ''},
        {'text': 5},
        {'text': 'x' * 2001},
        {'text': 'x', 'local_now': 'soon'},
      ]) {
        final r = await call(t, 'add_task', args);
        expect(r['isError'], true, reason: '$args');
      }
      final unknown = await post('/mcp', rpc('tools/call', {'name': 'delete_everything'}), token: t);
      expect(unknown.json['error']['code'], -32602);
    });

    test('the change shows under the assistant\'s own source, so the apps pick it up at their next sync', () async {
      await call(t, 'add_task', {'text': 'Shows on the phone'});
      final fields = store.exportAll(alice.id);
      expect(fields.where((f) => f.table == 'tasks' && f.value == 'Shows on the phone'), isNotEmpty);
    });
  });
}
