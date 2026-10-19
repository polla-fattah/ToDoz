import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';
import 'package:taskflow_server/web_assets.dart';
import 'package:test/test.dart';

class Reply {
  Reply(this.status, this.headers, this.text);
  final int status;
  final Map<String, String> headers;
  final String text;
  dynamic get json => jsonDecode(text);
}

/// NoteDo for the web: the page, the browser sign-in, and the REST calls it makes.
void main() {
  late Store store;
  late Handler api;
  late DateTime now;
  late Account alice;
  late Account bob;

  Handler build({bool web = true}) => buildApi(
        store,
        config: ApiConfig(trustProxy: true, syncPerMinute: 100000, apiPerMinute: 100000, webClient: web),
        clock: () => now,
        log: (l) {
          if (l.contains('internal error')) print(l);
        },
      );

  setUp(() {
    now = DateTime.utc(2026, 10, 19, 9);
    store = Store.open(':memory:', clock: () => now);
    api = build();
    alice = store.createUser('Alice');
    bob = store.createUser('Bob');
  });
  tearDown(() => store.close());

  Future<Reply> call(String method, String path, {Object? body, String? token, String ip = '1.2.3.4'}) async {
    final h = <String, String>{
      'x-forwarded-for': ip,
      if (token != null) 'authorization': 'Bearer $token',
      if (body != null) 'content-type': 'application/json',
    };
    final response = await api(Request(method, Uri.parse('http://localhost$path'), headers: h, body: body == null ? null : jsonEncode(body)));
    return Reply(response.statusCode, response.headers, await response.readAsString());
  }

  Future<String> signIn(Account a, {String ip = '1.2.3.4'}) async {
    final r = await call('POST', '/web/login', body: {'code': store.createInvite(a.id), 'name': 'Web browser 2026-10-19'}, ip: ip);
    expect(r.status, 200, reason: r.text);
    return r.json['token'] as String;
  }

  group('the page', () {
    test('is served at /app with a policy that lets only its own files run, and no framing', () async {
      final r = await call('GET', '/app');
      expect(r.status, 200);
      expect(r.headers['content-type'], startsWith('text/html'));
      expect(r.headers['cache-control'], 'no-store', reason: 'the page itself is always fetched fresh, so a new build is picked up');
      final csp = r.headers['content-security-policy']!;
      expect(csp, contains("default-src 'none'"));
      expect(csp, contains("script-src 'self'"));
      expect(csp, contains("connect-src 'self'"));
      expect(csp, contains("frame-ancestors 'none'"));
      expect(csp, isNot(contains("script-src 'unsafe")), reason: 'no inline scripts');
      expect(csp, isNot(contains('http')), reason: 'nothing may load from another site');
      expect(r.headers['x-frame-options'], 'DENY');
      expect(r.text, contains('<div id="root">'));
    });

    test('every file the page asks for is served, with the right type, kept for a year', () async {
      final page = (await call('GET', '/app')).text;
      final files = RegExp(r'(?:src|href)="(/app/assets/[^"]+)"').allMatches(page).map((m) => m.group(1)!).toList();
      expect(files.where((f) => f.endsWith('.js')), isNotEmpty);
      expect(files.where((f) => f.endsWith('.css')), isNotEmpty);
      for (final f in files) {
        final r = await call('GET', f);
        expect(r.status, 200, reason: f);
        expect(r.headers['cache-control'], contains('immutable'), reason: f);
        expect(r.headers['x-content-type-options'], 'nosniff');
        if (f.endsWith('.js')) expect(r.headers['content-type'], startsWith('text/javascript'));
        if (f.endsWith('.css')) expect(r.headers['content-type'], startsWith('text/css'));
      }
    });

    test('the font files named in the style sheet are served too', () async {
      final page = (await call('GET', '/app')).text;
      final css = RegExp(r'href="(/app/assets/[^"]+\.css)"').firstMatch(page)!.group(1)!;
      final fonts = RegExp(r'url\((/app/assets/[^)]+\.woff2)\)').allMatches((await call('GET', css)).text).map((m) => m.group(1)!).toSet();
      expect(fonts, isNotEmpty);
      for (final f in fonts) {
        final r = await api(Request('GET', Uri.parse('http://localhost$f'), headers: {'x-forwarded-for': '1.2.3.4'}));
        expect(r.statusCode, 200, reason: f);
        expect(r.headers['content-type'], 'font/woff2');
        expect((await r.read().expand((c) => c).toList()).length, greaterThan(1000), reason: f);
      }
    });

    test('an unknown file, or a way out of the folder, is not found', () async {
      expect((await call('GET', '/app/assets/nothing.js')).status, 404);
      expect((await call('GET', '/app/assets/..%2Findex.html')).status, 404);
      expect((await call('GET', '/app/assets/%2e%2e%2f%2e%2e%2fstore.dart')).status, 404);
    });

    test('the root address goes to it; /app/ works too', () async {
      final r = await call('GET', '/');
      expect(r.status, 302);
      expect(r.headers['location'], '/app');
      expect((await call('GET', '/app/')).status, 200);
    });

    test('every other answer still has the strictest policy and no caching', () async {
      for (final path in ['/health', '/nope']) {
        final r = await call('GET', path);
        expect(r.headers['content-security-policy'], "default-src 'none'");
        expect(r.headers['cache-control'], 'no-store');
      }
    });

    test('with --no-web there is no page, no files and no browser sign-in', () async {
      api = build(web: false);
      expect((await call('GET', '/app')).status, 404);
      expect((await call('GET', '/app/assets/anything.js')).status, 404);
      final r = await call('POST', '/web/login', body: {'code': store.createInvite(alice.id)});
      expect(r.status, 404);
    });

    test('is the same as the last build in web/dist (run python tool/embed_web.py after changing the page)', () {
      final dist = Directory('web/dist');
      if (!dist.existsSync()) return; // not built here (a checkout without Node): the embedded copy is what counts
      for (final entity in dist.listSync(recursive: true).whereType<File>()) {
        final rel = entity.path.replaceAll('\\', '/').split('web/dist/').last;
        expect(webAssets.containsKey(rel), isTrue, reason: '$rel is built but not embedded');
        expect(base64.decode(webAssets[rel]!.data), entity.readAsBytesSync(), reason: '$rel differs');
      }
    });

    test('puts nothing from your tasks into the page as HTML', () {
      final src = Directory('web/src');
      if (!src.existsSync()) return;
      for (final f in src.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.ts') || f.path.endsWith('.tsx'))) {
        final text = f.readAsStringSync();
        for (final bad in ['dangerouslySetInnerHTML', 'innerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function(']) {
          expect(text, isNot(contains(bad)), reason: '${f.path} uses $bad');
        }
      }
    });
  });

  group('signing in from a browser', () {
    test('a one-time code gives a token that works on the REST API, for that person only', () async {
      final t = await signIn(alice);
      expect(t, startsWith('tf_'));
      expect((await call('GET', '/api/v1/projects', token: t)).status, 200);
      await call('POST', '/api/v1/tasks', token: t, body: {'title': 'Alice only'});
      final bobToken = await signIn(bob);
      expect((await call('GET', '/api/v1/tasks', token: bobToken)).json['tasks'], isEmpty);
      expect((await call('GET', '/api/v1/tasks', token: t)).json['tasks'], hasLength(1));
    });

    test('the code works once, and a wrong or expired one is refused without saying which', () async {
      final code = store.createInvite(alice.id);
      expect((await call('POST', '/web/login', body: {'code': code})).status, 200);
      final again = await call('POST', '/web/login', body: {'code': code});
      expect(again.status, 401);
      expect(again.json['error'], 'bad_code');
      expect((await call('POST', '/web/login', body: {'code': 'ZZZZ-ZZZZ'})).status, 401);
      final old = store.createInvite(alice.id);
      now = now.add(const Duration(hours: 2));
      expect((await call('POST', '/web/login', body: {'code': old})).status, 401);
    });

    test('a code made for the phone cannot be reused as a device afterwards', () async {
      final code = store.createInvite(alice.id);
      expect((await call('POST', '/web/login', body: {'code': code})).status, 200);
      expect((await call('POST', '/v1/pair', body: {'code': code, 'deviceName': 'Phone'})).status, 401);
    });

    test('five wrong codes lock the address out for a while, as for phones', () async {
      for (var i = 0; i < 5; i++) {
        expect((await call('POST', '/web/login', body: {'code': 'AAAA-000$i'}, ip: '9.9.9.9')).status, 401);
      }
      final locked = await call('POST', '/web/login', body: {'code': store.createInvite(alice.id)}, ip: '9.9.9.9');
      expect(locked.status, 429);
      expect((await call('POST', '/web/login', body: {'code': store.createInvite(alice.id)}, ip: '8.8.8.8')).status, 200, reason: 'another address is not affected');
    });

    test('the token is listed under the person\'s API tokens (so the app can revoke it) and only its hash is stored', () async {
      final t = await signIn(alice);
      final device = (await call('POST', '/v1/pair', body: {'code': store.createInvite(alice.id), 'deviceName': 'Phone'})).json['token'] as String;
      final list = (await call('GET', '/v1/api-tokens', token: device)).json['tokens'] as List;
      expect(list.single['name'], startsWith('Web browser'));
      expect(list.single['readOnly'], isFalse);
      expect(store.db.select('SELECT * FROM api_tokens').first.values.join(' '), isNot(contains(t)));
    });

    test('signing out ends that token and no other', () async {
      final one = await signIn(alice);
      final two = await signIn(alice);
      expect((await call('DELETE', '/api/v1/session', token: one)).status, 204);
      expect((await call('GET', '/api/v1/tasks', token: one)).status, 401);
      expect((await call('GET', '/api/v1/tasks', token: two)).status, 200);
      expect((await call('DELETE', '/api/v1/session')).status, 401);
    });

    test('when the person has the most tokens allowed, the oldest browser sign-in makes room; other tokens are kept', () async {
      final device = (await call('POST', '/v1/pair', body: {'code': store.createInvite(alice.id), 'deviceName': 'Phone'})).json['token'] as String;
      final script = (await call('POST', '/v1/api-tokens', token: device, body: {'name': 'my script'})).json['token'] as String;
      final first = await signIn(alice, ip: '10.0.0.0');
      for (var i = 1; i < 19; i++) {
        now = now.add(const Duration(seconds: 1));
        await signIn(alice, ip: '10.0.0.$i'); // a different address each time: the rate limit is per address
      }
      expect(store.listApiTokens(alice.id).where((t) => t['revoked'] == false), hasLength(20));
      now = now.add(const Duration(seconds: 1));
      await signIn(alice, ip: '10.0.0.99');
      expect((await call('GET', '/api/v1/tasks', token: first)).status, 401, reason: 'the oldest browser sign-in was dropped');
      expect((await call('GET', '/api/v1/tasks', token: script)).status, 200, reason: 'a script token is never dropped');
    });
  });

  group('adding a task from a line of text', () {
    late String t;
    setUp(() async => t = await signIn(alice));

    test('understands dates, priority, labels and projects like the apps, as of the sender\'s clock', () async {
      final home = (await call('POST', '/api/v1/projects', token: t, body: {'name': 'Home'})).json['id'] as String;
      final r = await call('POST', '/api/v1/quick-add', token: t, body: {'text': 'Call mum tomorrow 17:00 p1 %family #Home', 'today': '2026-10-19T09:30'});
      expect(r.status, 201, reason: r.text);
      final task = r.json;
      expect(task['title'], 'Call mum');
      expect(task['priority'], 1);
      expect(task['project_id'], home);
      expect(task['labels'], ['family']);
      expect(task['due']['date'], '2026-10-20');
      expect(task['due']['time'], '17:00');
    });

    test('uses the project it is given when the line names none, and the Inbox otherwise', () async {
      final p = (await call('POST', '/api/v1/projects', token: t, body: {'name': 'Work'})).json['id'] as String;
      expect((await call('POST', '/api/v1/quick-add', token: t, body: {'text': 'Write report', 'project_id': p})).json['project_id'], p);
      expect((await call('POST', '/api/v1/quick-add', token: t, body: {'text': 'Buy milk'})).json['project_id'], 'inbox');
    });

    test('refuses an empty line, a bad clock, a missing project, and does nothing for a read-only token', () async {
      expect((await call('POST', '/api/v1/quick-add', token: t, body: {'text': '   '})).status, 400);
      expect((await call('POST', '/api/v1/quick-add', token: t, body: {'text': 'x', 'today': 'soon'})).status, 400);
      expect((await call('POST', '/api/v1/quick-add', token: t, body: {'text': 'x', 'project_id': 'nope'})).status, 404);
      final device = (await call('POST', '/v1/pair', body: {'code': store.createInvite(alice.id), 'deviceName': 'P'})).json['token'] as String;
      final ro = (await call('POST', '/v1/api-tokens', token: device, body: {'name': 'ro', 'readOnly': true})).json['token'] as String;
      expect((await call('POST', '/api/v1/quick-add', token: ro, body: {'text': 'Nope'})).status, 403);
      expect((await call('GET', '/api/v1/tasks', token: t)).json['tasks'], isEmpty);
    });

    test('shows up for the person\'s other devices at their next sync', () async {
      await call('POST', '/api/v1/quick-add', token: t, body: {'text': 'From the browser today', 'today': '2026-10-19T09:30'});
      final device = (await call('POST', '/v1/pair', body: {'code': store.createInvite(alice.id), 'deviceName': 'Phone'})).json['token'] as String;
      final sync = await call('POST', '/v1/sync', token: device, body: {'cursor': 0, 'changes': []});
      expect(sync.text, contains('From the browser'));
    });
  });

  group('putting tasks and sections in order (drag and drop)', () {
    late String t;
    late String project;
    late List<String> ids;
    setUp(() async {
      t = await signIn(alice);
      project = (await call('POST', '/api/v1/projects', token: t, body: {'name': 'Work'})).json['id'] as String;
      ids = [
        for (final title in ['A', 'B', 'C']) (await call('POST', '/api/v1/tasks', token: t, body: {'title': title, 'project_id': project})).json['id'] as String,
      ];
    });

    Future<List<String>> titles({String? section}) async {
      final r = await call('GET', '/api/v1/tasks?project_id=$project${section == null ? '' : '&section_id=$section'}', token: t);
      final tasks = (r.json['tasks'] as List).cast<Map>();
      return [for (final x in tasks) x['title'] as String];
    }

    test('the order given becomes the order tasks come back in', () async {
      expect(await titles(), ['A', 'B', 'C']);
      final r = await call('POST', '/api/v1/tasks/reorder', token: t, body: {'ids': [ids[2], ids[0], ids[1]]});
      expect(r.status, 204, reason: r.text);
      expect(await titles(), ['C', 'A', 'B']);
      final orders = {for (final x in ((await call('GET', '/api/v1/tasks', token: t)).json['tasks'] as List).cast<Map>()) x['title']: x['order']};
      expect(orders, {'C': 0, 'A': 1, 'B': 2});
    });

    test('only the tasks named are touched', () async {
      await call('POST', '/api/v1/tasks/reorder', token: t, body: {'ids': [ids[1], ids[0]]});
      final tasks = ((await call('GET', '/api/v1/tasks', token: t)).json['tasks'] as List).cast<Map>();
      expect(tasks.firstWhere((x) => x['title'] == 'C')['order'], 2, reason: 'C keeps the number it had');
    });

    test('a task moved to a section can be placed in it in one go', () async {
      final section = (await call('POST', '/api/v1/sections', token: t, body: {'project_id': project, 'name': 'Doing'})).json['id'] as String;
      await call('POST', '/api/v1/tasks/${ids[0]}', token: t, body: {'section_id': section});
      await call('POST', '/api/v1/tasks/${ids[2]}', token: t, body: {'section_id': section});
      await call('POST', '/api/v1/tasks/reorder', token: t, body: {'ids': [ids[2], ids[0]]});
      expect(await titles(section: section), ['C', 'A']);
    });

    test('refuses a list that is not ids, has a repeat, is too long, or names something that does not exist', () async {
      expect((await call('POST', '/api/v1/tasks/reorder', token: t, body: {'ids': 'abc'})).status, 400);
      expect((await call('POST', '/api/v1/tasks/reorder', token: t, body: {'ids': [1, 2]})).status, 400);
      expect((await call('POST', '/api/v1/tasks/reorder', token: t, body: {'ids': [ids[0], ids[0]]})).status, 400);
      expect((await call('POST', '/api/v1/tasks/reorder', token: t, body: {'ids': List.filled(1001, 'x')})).status, 400);
      expect((await call('POST', '/api/v1/tasks/reorder', token: t, body: {'ids': [ids[0], 'missing']})).status, 404);
      expect((await call('POST', '/api/v1/tasks/reorder', token: t, body: {})).status, 400);
      expect(await titles(), ['A', 'B', 'C'], reason: 'a refused request changes nothing');
    });

    test('cannot reorder tasks of another person, and a read-only token cannot reorder', () async {
      final other = await signIn(bob);
      expect((await call('POST', '/api/v1/tasks/reorder', token: other, body: {'ids': [ids[0]]})).status, 404);
      final device = (await call('POST', '/v1/pair', body: {'code': store.createInvite(alice.id), 'deviceName': 'P'})).json['token'] as String;
      final ro = (await call('POST', '/v1/api-tokens', token: device, body: {'name': 'ro', 'readOnly': true})).json['token'] as String;
      expect((await call('POST', '/api/v1/tasks/reorder', token: ro, body: {'ids': ids})).status, 403);
    });

    test('reaches the phone at its next sync', () async {
      await call('POST', '/api/v1/tasks/reorder', token: t, body: {'ids': [ids[2], ids[1], ids[0]]});
      final device = (await call('POST', '/v1/pair', body: {'code': store.createInvite(alice.id), 'deviceName': 'Phone'})).json['token'] as String;
      final sync = await call('POST', '/v1/sync', token: device, body: {'cursor': 0, 'changes': []});
      final changes = (sync.json['changes'] as List).cast<Map>().where((c) => c['c'] == 'sort_order' && c['t'] == 'tasks');
      final byRow = {for (final c in changes) c['r']: c['v']};
      expect(byRow[ids[2]], 0);
      expect(byRow[ids[0]], 2);
    });

    test('sections: rename, and put in order', () async {
      final a = (await call('POST', '/api/v1/sections', token: t, body: {'project_id': project, 'name': 'One'})).json['id'] as String;
      final b = (await call('POST', '/api/v1/sections', token: t, body: {'project_id': project, 'name': 'Two'})).json['id'] as String;
      expect((await call('POST', '/api/v1/sections/$a', token: t, body: {'name': 'First'})).json['name'], 'First');
      expect((await call('POST', '/api/v1/sections/$a', token: t, body: {'name': ' '})).status, 400);
      expect((await call('POST', '/api/v1/sections/nope', token: t, body: {'name': 'x'})).status, 404);
      expect((await call('POST', '/api/v1/sections/reorder', token: t, body: {'ids': [b, a]})).status, 204);
      final sections = ((await call('GET', '/api/v1/sections?project_id=$project', token: t)).json['sections'] as List).cast<Map>();
      expect({for (final x in sections) x['name']: x['order']}, {'Two': 0, 'First': 1});
    });
  });

  group('previewing a Quick Add line and sections in it', () {
    late String t;
    late String work;
    late String doing;
    setUp(() async {
      t = await signIn(alice);
      work = (await call('POST', '/api/v1/projects', token: t, body: {'name': 'Work'})).json['id'] as String;
      doing = (await call('POST', '/api/v1/sections', token: t, body: {'project_id': work, 'name': 'Doing'})).json['id'] as String;
    });

    test('a line with a project and a section lands in that section', () async {
      final r = await call('POST', '/api/v1/quick-add', token: t, body: {'text': 'Write report #Work /Doing p2', 'today': '2026-10-19T09:00'});
      expect(r.status, 201, reason: r.text);
      expect(r.json['project_id'], work);
      expect(r.json['section_id'], doing);
      expect(r.json['priority'], 2);
    });

    test('the preview says what each part means, where the words are, and saves nothing', () async {
      const line = 'Call mum tomorrow 5pm p1 %family #Work /Doing';
      final r = await call('POST', '/api/v1/quick-add/parse', token: t, body: {'text': line, 'today': '2026-10-19T09:00'});
      expect(r.status, 200, reason: r.text);
      final j = r.json;
      expect(j['title'], 'Call mum');
      expect(j['priority'], 1);
      expect(j['due'], {'date': '2026-10-20', 'time': '17:00', 'recurrence': null});
      expect(j['labels'], ['family']);
      expect(j['project'], {'id': work, 'name': 'Work', 'typed': 'Work', 'known': true});
      expect(j['section'], {'id': doing, 'name': 'Doing', 'typed': 'Doing', 'known': true});
      final tokens = (j['tokens'] as List).cast<Map>();
      final p1 = tokens.firstWhere((x) => x['kind'] == 'priority');
      expect(line.substring(p1['start'] as int, p1['end'] as int), 'p1');
      expect(tokens.map((x) => x['kind']), containsAll(['date', 'time', 'priority', 'label', 'project', 'section']));
      expect((await call('GET', '/api/v1/tasks', token: t)).json['tasks'], isEmpty);
    });

    test('an unknown project or section is marked as not known (the app offers to create it)', () async {
      final r = await call('POST', '/api/v1/quick-add/parse', token: t, body: {'text': 'x #Nowhere /Nothing'});
      expect(r.json['project']['known'], isFalse);
      expect(r.json['project']['typed'], 'Nowhere');
      expect(r.json['section']['known'], isFalse);
      final inInbox = await call('POST', '/api/v1/quick-add/parse', token: t, body: {'text': 'plain words'});
      expect(inInbox.json['project']['id'], 'inbox');
      expect(inInbox.json['project']['known'], isTrue);
      expect(inInbox.json['section'], isNull);
    });

    test('is allowed for a read-only token, and refuses bad input', () async {
      final device = (await call('POST', '/v1/pair', body: {'code': store.createInvite(alice.id), 'deviceName': 'P'})).json['token'] as String;
      final ro = (await call('POST', '/v1/api-tokens', token: device, body: {'name': 'ro', 'readOnly': true})).json['token'] as String;
      expect((await call('POST', '/api/v1/quick-add/parse', token: ro, body: {'text': 'x'})).status, 200);
      expect((await call('POST', '/api/v1/quick-add/parse', token: t, body: {})).status, 400);
      expect((await call('POST', '/api/v1/quick-add/parse', token: t, body: {'text': 'x', 'today': 'soon'})).status, 400);
      expect((await call('POST', '/api/v1/quick-add/parse', token: t, body: {'text': 'x', 'project_id': 'nope'})).status, 404);
    });
  });
}
