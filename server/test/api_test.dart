import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:taskflow_core/sync.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';
import 'package:test/test.dart';

class Reply {
  Reply(this.status, this.headers, this.text);
  final int status;
  final Map<String, String> headers;
  final String text;
  Map<String, Object?> get json => jsonDecode(text) as Map<String, Object?>;
}

void main() {
  late Store store;
  late Handler api;
  late DateTime now;
  late List<String> logLines;
  late Account alice;
  late Account bob;

  Handler build({ApiConfig config = const ApiConfig(trustProxy: true)}) =>
      buildApi(store, config: config, log: logLines.add, clock: () => now);

  setUp(() {
    now = DateTime.utc(2026, 10, 19, 12);
    store = Store.open(':memory:', clock: () => now);
    logLines = [];
    api = build();
    alice = store.createUser('Alice');
    bob = store.createUser('Bob');
  });
  tearDown(() => store.close());

  Future<Reply> call(
    String method,
    String path, {
    Object? body,
    String? rawBody,
    String? token,
    String ip = '1.2.3.4',
    String contentType = 'application/json',
    Handler? handler,
  }) async {
    final headers = <String, String>{
      'x-forwarded-for': ip,
      if (token != null) 'authorization': 'Bearer $token',
      if (body != null || rawBody != null) 'content-type': contentType,
    };
    final request = Request(method, Uri.parse('http://localhost$path'), headers: headers, body: rawBody ?? (body == null ? null : jsonEncode(body)));
    final response = await (handler ?? api)(request);
    return Reply(response.statusCode, response.headers, await response.readAsString());
  }

  /// Pairs a new device for [account] and returns its token.
  Future<String> pair(Account account, {String name = 'Phone', String ip = '1.2.3.4'}) async {
    final code = store.createInvite(account.id);
    final r = await call('POST', '/v1/pair', body: {'code': code, 'deviceName': name}, ip: ip);
    expect(r.status, 200, reason: r.text);
    return r.json['token'] as String;
  }

  SyncChange ch(String row, String col, Object? v, int wall, {String node = 'd1', String table = 'tasks'}) =>
      SyncChange(table: table, row: row, col: col, value: v, hlc: formatHlc(wall, 0, node));

  Future<Reply> sync(String token, {int cursor = 0, List<SyncChange> changes = const [], int limit = 500}) =>
      call('POST', '/v1/sync', token: token, body: SyncRequest(cursor: cursor, changes: changes, limit: limit).toJson());

  group('basics', () {
    test('health, unknown routes, and security headers', () async {
      final h = await call('GET', '/health');
      expect(h.status, 200);
      expect(h.json['ok'], true);
      expect(h.headers['strict-transport-security'], contains('max-age'));
      expect(h.headers['x-content-type-options'], 'nosniff');
      expect(h.headers['cache-control'], 'no-store');
      expect(h.headers['content-security-policy'], "default-src 'none'");
      final nf = await call('GET', '/nothing/here');
      expect(nf.status, 404);
      expect(nf.json['error'], 'not_found');
    });

    test('errors never reveal internals', () async {
      final r = await call('POST', '/v1/sync', token: 'x' * 40, body: {});
      expect(r.status, 401);
      expect(r.text, isNot(contains('Exception')));
      expect(r.text, isNot(contains('.dart')));
    });
  });

  group('pairing over HTTP (SEC-2, SEC-8)', () {
    test('a good code gives a token that works', () async {
      final token = await pair(alice);
      final me = await call('GET', '/v1/me', token: token);
      expect(me.status, 200);
      expect((me.json['user'] as Map)['name'], 'Alice');
      final devices = me.json['devices'] as List;
      expect(devices.single['current'], true);
    });

    test('a code works once', () async {
      final code = store.createInvite(alice.id);
      expect((await call('POST', '/v1/pair', body: {'code': code, 'deviceName': 'A'})).status, 200);
      final second = await call('POST', '/v1/pair', body: {'code': code, 'deviceName': 'B'});
      expect(second.status, 401);
      expect(second.json['error'], 'bad_code');
    });

    test('an expired code is refused', () async {
      final code = store.createInvite(alice.id);
      now = now.add(const Duration(minutes: 11));
      store = store; // the store shares the clock closure
      expect((await call('POST', '/v1/pair', body: {'code': code, 'deviceName': 'A'})).status, 401);
    });

    test('malformed pairing requests', () async {
      expect((await call('POST', '/v1/pair', body: {'nothing': 1})).status, 400);
      expect((await call('POST', '/v1/pair', body: {'code': 5})).status, 400);
      expect((await call('POST', '/v1/pair', rawBody: 'not json')).status, 400);
      expect((await call('POST', '/v1/pair', body: {'code': 'AAAA-AAAA'}, contentType: 'text/plain')).status, 415);
    });

    test('five wrong guesses lock that address, even for a right code', () async {
      final good = store.createInvite(alice.id);
      for (var i = 0; i < 5; i++) {
        expect((await call('POST', '/v1/pair', body: {'code': 'AAAA-AAA$i'.replaceAll('0', '2').replaceAll('1', '3'), 'deviceName': 'x'}, ip: '9.9.9.9')).status, 401);
      }
      final locked = await call('POST', '/v1/pair', body: {'code': good, 'deviceName': 'x'}, ip: '9.9.9.9');
      expect(locked.status, 429);
      expect(locked.headers['retry-after'], isNotNull);
      // Another address is unaffected.
      expect((await call('POST', '/v1/pair', body: {'code': good, 'deviceName': 'x'}, ip: '8.8.8.8')).status, 200);
    });

    test('the lockout ends after fifteen minutes', () async {
      for (var i = 0; i < 5; i++) {
        await call('POST', '/v1/pair', body: {'code': 'AAAA-AAAA', 'deviceName': 'x'}, ip: '9.9.9.9');
      }
      now = now.add(const Duration(minutes: 16));
      final good = store.createInvite(alice.id);
      expect((await call('POST', '/v1/pair', body: {'code': good, 'deviceName': 'x'}, ip: '9.9.9.9')).status, 200);
    });

    test('without a trusted proxy the forwarded address cannot be faked', () async {
      final plain = build(config: const ApiConfig());
      for (var i = 0; i < 6; i++) {
        await call('POST', '/v1/pair', body: {'code': 'AAAA-AAAA', 'deviceName': 'x'}, ip: '1.1.1.$i', handler: plain);
      }
      // All six were counted against the same (unknown) source, so it is now locked.
      final r = await call('POST', '/v1/pair', body: {'code': 'AAAA-AAAA', 'deviceName': 'x'}, ip: '5.5.5.5', handler: plain);
      expect(r.status, 429);
    });
  });

  group('authentication (SEC-4)', () {
    test('missing, malformed and unknown tokens get 401', () async {
      expect((await call('POST', '/v1/sync', body: {'cursor': 0})).status, 401);
      expect((await call('POST', '/v1/sync', token: 'short', body: {'cursor': 0})).status, 401);
      expect((await call('POST', '/v1/sync', token: 'A' * 43, body: {'cursor': 0})).status, 401);
      expect((await call('GET', '/v1/me')).status, 401);
      expect((await call('GET', '/v1/export')).status, 401);
      expect((await call('DELETE', '/v1/devices/abc')).status, 401);
      expect((await call('POST', '/v1/me/delete', body: {'confirm': confirmPhrase})).status, 401);
    });

    test('a token must use the Bearer scheme', () async {
      final token = await pair(alice);
      final r = await api(Request('GET', Uri.parse('http://localhost/v1/me'), headers: {'authorization': 'Basic $token'}));
      expect(r.statusCode, 401);
    });

    test('revoking a device stops it at once', () async {
      final phone = await pair(alice, name: 'Phone');
      final tablet = await pair(alice, name: 'Tablet');
      final me = await call('GET', '/v1/me', token: tablet);
      final phoneId = (me.json['devices'] as List).firstWhere((d) => d['name'] == 'Phone')['id'];
      expect((await call('DELETE', '/v1/devices/$phoneId', token: tablet)).status, 204);
      expect((await call('GET', '/v1/me', token: phone)).status, 401);
      expect((await call('GET', '/v1/me', token: tablet)).status, 200);
    });
  });

  group('syncing over HTTP', () {
    test('two devices exchange changes', () async {
      final phone = await pair(alice, name: 'Phone');
      final tablet = await pair(alice, name: 'Tablet');
      final push = await sync(phone, changes: [ch('t1', 'title', 'Buy milk', 1000), ch('t1', presentColumn, true, 1000)]);
      expect(push.status, 200);
      expect(push.json['changes'], isEmpty); // nothing from other devices yet
      final pull = await sync(tablet);
      final got = SyncResponse.fromJson(pull.json);
      expect(got.changes.map((c) => c.col).toSet(), {'title', presentColumn});
      expect(got.more, isFalse);
      // Resuming from the returned cursor yields nothing new.
      expect((await sync(tablet, cursor: got.cursor)).json['changes'], isEmpty);
    });

    test('paging: more=true until everything is delivered', () async {
      final phone = await pair(alice, name: 'Phone');
      final tablet = await pair(alice, name: 'Tablet');
      await sync(phone, changes: [for (var i = 0; i < 30; i++) ch('t$i', 'title', 'v$i', 1000 + i, node: 'phone')]);
      var cursor = 0, total = 0, rounds = 0;
      while (true) {
        final r = SyncResponse.fromJson((await sync(tablet, cursor: cursor, limit: 10)).json);
        total += r.changes.length;
        cursor = r.cursor;
        rounds++;
        if (!r.more) break;
      }
      expect((total, rounds), (30, 3));
    });

    test('a replayed push changes nothing', () async {
      final phone = await pair(alice);
      final c = ch('t1', 'title', 'x', 1000);
      await sync(phone, changes: [c]);
      await sync(phone, changes: [c]);
      expect(store.fieldCount(alice.id), 1);
    });

    test('bad input is refused with a clear 400 (SEC-9)', () async {
      final t = await pair(alice);
      Future<Reply> raw(Object body) => call('POST', '/v1/sync', token: t, body: body);
      Map<String, Object?> one(Map<String, Object?> change) => {'cursor': 0, 'changes': [change]};
      final good = ch('t1', 'title', 'x', 1000).toJson();
      expect((await raw(one({...good, 't': 'users'}))).status, 400);
      expect((await raw(one({...good, 'c': 'password'}))).status, 400);
      expect((await raw(one({...good, 'h': 'now'}))).status, 400);
      expect((await raw(one({...good, 'v': {'a': 1}}))).status, 400);
      expect((await raw({'cursor': -3, 'changes': []})).status, 400);
      expect((await raw({'cursor': 'x'})).status, 400);
      expect((await raw({'cursor': 0, 'changes': 'no'})).status, 400);
      final tooMany = [for (var i = 0; i < maxChangesPerRequest + 1; i++) ch('r$i', 'title', 'x', 1000 + i).toJson()];
      final r = await raw({'cursor': 0, 'changes': tooMany});
      expect(r.status, 400);
      expect(r.json['message'], contains('Too many'));
      expect(store.fieldCount(alice.id), 0); // nothing from a refused request was stored
    });

    test('an SQL-looking value is just data', () async {
      final t = await pair(alice);
      await sync(t, changes: [ch('t1', 'title', "x'); DROP TABLE fields;--", 1000)]);
      expect(store.fieldCount(alice.id), 1);
      expect(store.exportAll(alice.id).single.value, "x'); DROP TABLE fields;--");
    });

    test('oversized bodies get 413', () async {
      final t = await pair(alice);
      final small = build(config: const ApiConfig(trustProxy: true, maxBodyBytes: 1000));
      final r = await call('POST', '/v1/sync', token: t, body: {'cursor': 0, 'changes': [], 'pad': 'x' * 5000}, handler: small);
      expect(r.status, 413);
    });

    test('POST bodies must be JSON', () async {
      final t = await pair(alice);
      expect((await call('POST', '/v1/sync', token: t, rawBody: '{}', contentType: 'text/plain')).status, 415);
      expect((await call('POST', '/v1/sync', token: t, rawBody: '{bad')).status, 400);
    });
  });

  group('one person never reaches another (SEC-5, SEC-6)', () {
    late String aliceToken, bobToken, aliceTablet;

    setUp(() async {
      aliceToken = await pair(alice, name: 'Alice phone');
      aliceTablet = await pair(alice, name: 'Alice tablet');
      bobToken = await pair(bob, name: 'Bob phone');
      await sync(aliceToken, changes: [ch('t1', 'title', 'ALICE-SECRET', 1000), ch('t1', presentColumn, true, 1000)]);
    });

    test('Bob\'s sync from the start returns nothing of Alice\'s', () async {
      final r = await sync(bobToken);
      expect(r.text, isNot(contains('ALICE-SECRET')));
      expect(SyncResponse.fromJson(r.json).changes, isEmpty);
    });

    test('Bob\'s export and device list hold nothing of Alice\'s', () async {
      for (final path in ['/v1/export', '/v1/me']) {
        final r = await call('GET', path, token: bobToken);
        expect(r.status, 200);
        expect(r.text, isNot(contains('ALICE-SECRET')), reason: path);
        expect(r.text, isNot(contains('Alice')), reason: path);
      }
    });

    test('Bob writing to the same row id does not touch Alice\'s data', () async {
      await sync(bobToken, changes: [ch('t1', 'title', 'bob wrote this', 9000)]);
      final mine = await sync(aliceTablet);
      final titles = SyncResponse.fromJson(mine.json).changes.where((c) => c.col == 'title').map((c) => c.value).toList();
      expect(titles, ['ALICE-SECRET']);
      expect(store.exportAll(bob.id).single.value, 'bob wrote this');
    });

    test('Bob cannot revoke Alice\'s device, even knowing its id', () async {
      final me = await call('GET', '/v1/me', token: aliceToken);
      final aliceDevice = (me.json['device'] as Map)['id'];
      expect((await call('DELETE', '/v1/devices/$aliceDevice', token: bobToken)).status, 404);
      expect((await call('GET', '/v1/me', token: aliceToken)).status, 200);
    });

    test('Bob deleting his account leaves Alice\'s data and devices alone', () async {
      expect((await call('POST', '/v1/me/delete', token: bobToken, body: {'confirm': confirmPhrase})).status, 204);
      expect((await call('GET', '/v1/me', token: bobToken)).status, 401);
      final mine = await sync(aliceTablet);
      expect(mine.text, contains('ALICE-SECRET'));
    });

    test('a cursor from Alice\'s account does not skip Bob\'s data', () async {
      final bobsFirst = SyncResponse.fromJson((await sync(bobToken, changes: [ch('b1', 'title', 'b', 5000), ch('b2', 'title', 'b', 5001)])).json);
      expect(bobsFirst.cursor, lessThanOrEqualTo(2));
      final tabletBob = await pair(bob, name: 'Bob tablet');
      final pull = SyncResponse.fromJson((await sync(tabletBob, cursor: 0)).json);
      expect(pull.changes, hasLength(2));
    });
  });

  group('account deletion and export (SEC-17)', () {
    test('export returns the person\'s own fields', () async {
      final t = await pair(alice);
      await sync(t, changes: [ch('t1', 'title', 'mine', 1000)]);
      final r = await call('GET', '/v1/export', token: t);
      expect(r.status, 200);
      expect((r.json['fields'] as List).single['v'], 'mine');
    });

    test('deleting needs the exact confirmation and then removes everything', () async {
      final t = await pair(alice);
      await sync(t, changes: [ch('t1', 'title', 'mine', 1000)]);
      expect((await call('POST', '/v1/me/delete', token: t, body: {})).status, 400);
      expect((await call('POST', '/v1/me/delete', token: t, body: {'confirm': 'yes'})).status, 400);
      expect(store.fieldCount(alice.id), 1);
      expect((await call('POST', '/v1/me/delete', token: t, body: {'confirm': confirmPhrase})).status, 204);
      expect(store.fieldCount(alice.id), 0);
      expect((await call('GET', '/v1/me', token: t)).status, 401);
    });
  });

  group('rate limits (SEC-8)', () {
    test('too many requests from one device get 429', () async {
      final t = await pair(alice);
      final tight = build(config: const ApiConfig(trustProxy: true, syncPerMinute: 5));
      for (var i = 0; i < 5; i++) {
        expect((await call('GET', '/v1/me', token: t, handler: tight)).status, 200);
      }
      final r = await call('GET', '/v1/me', token: t, handler: tight);
      expect(r.status, 429);
      expect(r.headers['retry-after'], isNotNull);
      now = now.add(const Duration(minutes: 2));
      expect((await call('GET', '/v1/me', token: t, handler: tight)).status, 200);
    });

    test('one device being limited does not affect another', () async {
      final a = await pair(alice, name: 'A');
      final b = await pair(bob, name: 'B');
      final tight = build(config: const ApiConfig(trustProxy: true, syncPerMinute: 2), );
      for (var i = 0; i < 3; i++) {
        await call('GET', '/v1/me', token: a, handler: tight);
      }
      expect((await call('GET', '/v1/me', token: a, handler: tight)).status, 429);
      expect((await call('GET', '/v1/me', token: b, handler: tight)).status, 200);
    });
  });

  group('the access log (SEC-12)', () {
    test('records who, what and the result, and never tokens, codes or task content', () async {
      final code = store.createInvite(alice.id);
      final paired = await call('POST', '/v1/pair', body: {'code': code, 'deviceName': 'Phone'});
      final token = paired.json['token'] as String;
      await sync(token, changes: [ch('t1', 'title', 'TOP-SECRET-TASK-TEXT', 1000)]);
      await call('GET', '/v1/me', token: token);
      await call('GET', '/v1/me', token: 'bad-token-value-12345678901');

      final log = logLines.join('\n');
      expect(log, contains('POST /v1/sync 200'));
      expect(log, contains('GET /v1/me 401'));
      expect(log, contains('user=${alice.id.substring(0, 8)}'));
      expect(log, isNot(contains(token)));
      expect(log, isNot(contains(code)));
      expect(log, isNot(contains('TOP-SECRET-TASK-TEXT')));
      expect(log, isNot(contains('bad-token-value')));
      expect(log, isNot(contains('Authorization')));
    });
  });
}
