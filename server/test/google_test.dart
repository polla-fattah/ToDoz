import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/google_api.dart';
import 'package:taskflow_server/google_sync.dart';
import 'package:taskflow_server/model.dart';
import 'package:taskflow_server/store.dart';
import 'package:test/test.dart';

/// A small imitation of the parts of Google the app uses, so the whole flow runs offline.
class FakeGoogle {
  FakeGoogle(this.now);
  DateTime Function() now;

  final calendars = <String, Map<String, Map<String, Object?>>>{}; // calendar -> event id -> event
  final deletedCalendars = <String>{};
  final log = <String>[];
  var _n = 0;
  bool refreshRevoked = false;
  bool withoutRefreshToken = false;
  String goodCode = 'good-code';
  final revoked = <String>[];

  http.Client get client => MockClient((request) async {
        final path = request.url.path;
        final method = request.method;
        log.add('$method $path');
        http.Response json(int status, Object? body) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
        Object? body() => request.body.isEmpty ? null : jsonDecode(request.body);

        if (path == '/token') {
          final f = request.bodyFields;
          if (f['grant_type'] == 'authorization_code') {
            if (f['code'] != goodCode) return json(400, {'error': 'invalid_grant', 'error_description': 'Bad code'});
            return json(200, {'access_token': 'acc', if (!withoutRefreshToken) 'refresh_token': 'ref', 'expires_in': 3599});
          }
          if (f['refresh_token'] != 'ref' || refreshRevoked) return json(400, {'error': 'invalid_grant', 'error_description': 'Token has been expired or revoked.'});
          return json(200, {'access_token': 'acc', 'expires_in': 3599});
        }
        if (path == '/revoke') {
          revoked.add(request.bodyFields['token'] ?? '');
          return json(200, {});
        }
        if (request.headers['authorization'] != 'Bearer acc') return json(401, {'error': {'message': 'Invalid Credentials'}});

        final cal = RegExp(r'^/calendar/v3/calendars/([^/]+)$').firstMatch(path);
        if (path == '/calendar/v3/calendars' && method == 'POST') {
          final id = 'cal${++_n}@group.calendar.google.com';
          calendars[id] = {};
          return json(200, {'id': id, ...(body() as Map).cast<String, Object?>()});
        }
        if (cal != null) {
          final id = Uri.decodeComponent(cal[1]!);
          if (!calendars.containsKey(id)) return json(404, {'error': {'message': 'Not Found'}});
          if (method == 'DELETE') {
            calendars.remove(id);
            deletedCalendars.add(id);
            return http.Response('', 204);
          }
          return json(200, {'id': id});
        }
        final ev = RegExp(r'^/calendar/v3/calendars/([^/]+)/events(?:/([^/]+))?$').firstMatch(path);
        if (ev != null) {
          final calId = Uri.decodeComponent(ev[1]!);
          final events = calendars[calId];
          if (events == null) return json(404, {'error': {'message': 'Not Found'}});
          final eventId = ev[2] == null ? null : Uri.decodeComponent(ev[2]!);
          switch (method) {
            case 'POST':
              final id = 'ev${++_n}';
              events[id] = {...(body() as Map).cast<String, Object?>(), 'id': id, 'status': 'confirmed', 'updated': now().toUtc().toIso8601String()};
              return json(200, events[id]);
            case 'PATCH':
              final e = events[eventId];
              if (e == null || e['status'] == 'cancelled') return json(404, {'error': {'message': 'Not Found'}});
              (body() as Map).forEach((k, v) {
                if (v == null) {
                  e.remove(k);
                } else {
                  e[k as String] = v;
                }
              });
              e['updated'] = now().toUtc().toIso8601String();
              return json(200, e);
            case 'DELETE':
              final e = events[eventId];
              if (e == null || e['status'] == 'cancelled') return json(410, {'error': {'message': 'Resource has been deleted'}});
              e['status'] = 'cancelled';
              e['updated'] = now().toUtc().toIso8601String();
              return http.Response('', 204);
            case 'GET':
              final min = request.url.queryParameters['updatedMin'];
              final items = [
                for (final e in events.values)
                  if (min == null || DateTime.parse(e['updated'] as String).isAfter(DateTime.parse(min)) || DateTime.parse(e['updated'] as String).isAtSameMomentAs(DateTime.parse(min))) e,
              ];
              return json(200, {'items': items});
          }
        }
        return json(404, {'error': {'message': 'No such fake route $method $path'}});
      });

  /// Events in the user's calendar that are not cancelled, by summary.
  List<Map<String, Object?>> live(String calendar) => [for (final e in calendars[calendar]!.values) if (e['status'] != 'cancelled') e];
}

void main() {
  late Store store;
  late DateTime now;
  late FakeGoogle google;
  late GoogleApi api;
  late GoogleSyncer syncer;
  late Handler handler;
  late Account alice;
  late Account bob;

  const tz = 'Asia/Riyadh';

  setUp(() {
    now = DateTime.utc(2026, 10, 14, 9);
    store = Store.open(':memory:', clock: () => now);
    google = FakeGoogle(() => now);
    api = GoogleApi(
      const GoogleConfig(clientId: 'cid', clientSecret: 'secret', publicUrl: 'https://sync.example.com'),
      client: google.client,
      tokenUrl: 'https://google.test/token',
      revokeUrl: 'https://google.test/revoke',
      apiBase: 'https://google.test/calendar/v3',
    );
    syncer = GoogleSyncer(store, api);
    handler = buildApi(store, config: const ApiConfig(trustProxy: true), google: api, googleSync: syncer, clock: () => now);
    alice = store.createUser('Alice');
    bob = store.createUser('Bob');
  });
  tearDown(() async {
    await syncer.flush();
    store.close();
  });

  Future<Response> call(String method, String path, {String? token, Object? body}) async => await handler(Request(method, Uri.parse('http://x$path'),
      headers: {if (token != null) 'authorization': 'Bearer $token', if (body != null) 'content-type': 'application/json', 'x-forwarded-for': '9.9.9.9'}, body: body == null ? null : jsonEncode(body)));

  Future<String> device(Account a) async {
    final r = await call('POST', '/v1/pair', body: {'code': store.createInvite(a.id), 'deviceName': 'Phone'});
    return (jsonDecode(await r.readAsString()) as Map)['token'] as String;
  }

  /// Goes through the connect flow and returns the account.
  Future<Account> connect(Account who) async {
    final d = await device(who);
    final r = await call('POST', '/v1/google/connect', token: d, body: {'timeZone': tz});
    final url = Uri.parse((jsonDecode(await r.readAsString()) as Map)['url'] as String);
    final cb = await call('GET', '/google/callback?code=good-code&state=${url.queryParameters['state']}');
    expect(cb.statusCode, 200, reason: await cb.readAsString());
    await syncer.flush(); // the sync that starts by itself when Google sends the person back
    return who;
  }

  UserModel model(Account a) => UserModel(store, a.id, source: 'test');

  String calendarOf(Account a) => store.googleAccount(a.id)!.calendarId!;

  Map<String, Object?> eventFor(Account a, String taskId) =>
      google.live(calendarOf(a)).firstWhere((e) => ((e['extendedProperties'] as Map)['private'] as Map)['taskflowId'] == taskId);

  group('connecting', () {
    test('the connect link asks for one narrow permission and comes back to this server', () async {
      final d = await device(alice);
      final r = await call('POST', '/v1/google/connect', token: d, body: {'timeZone': tz});
      expect(r.statusCode, 200);
      final url = Uri.parse((jsonDecode(await r.readAsString()) as Map)['url'] as String);
      expect(url.host, 'accounts.google.com');
      final q = url.queryParameters;
      expect(q['client_id'], 'cid');
      expect(q['scope'], 'https://www.googleapis.com/auth/calendar.app.created');
      expect(q['redirect_uri'], 'https://sync.example.com/google/callback');
      expect((q['access_type'], q['response_type'], q['prompt']), ('offline', 'code', 'consent'));
      expect(q['state'], isNotEmpty);
      expect(q.containsKey('client_secret'), isFalse);
    });

    test('the callback saves the sign-in, then makes the calendar and adds the tasks', () async {
      model(alice).createTask({'title': 'Dentist', 'due_date': '2026-10-20', 'due_time': '09:30'});
      await connect(alice);
      final acct = store.googleAccount(alice.id)!;
      expect((acct.refreshToken, acct.timeZone), ('ref', tz));
      // The first sync already ran by itself when Google sent the person back to the server.
      final report = await syncer.syncUser(alice.id);
      expect(report.error, isNull);
      expect(google.calendars.keys, hasLength(1));
      expect(google.live(calendarOf(alice)).map((e) => e['summary']), ['Dentist']);
      final s = await call('GET', '/v1/google', token: await device(alice));
      final status = jsonDecode(await s.readAsString()) as Map;
      expect((status['configured'], status['connected'], status['calendarReady']), (true, true, true));
      expect(status.containsKey('refreshToken'), isFalse);
    });

    test('a state value works once, and only for the person it was made for', () async {
      final d = await device(alice);
      final r = await call('POST', '/v1/google/connect', token: d, body: {'timeZone': tz});
      final state = Uri.parse((jsonDecode(await r.readAsString()) as Map)['url'] as String).queryParameters['state'];
      expect((await call('GET', '/google/callback?code=good-code&state=$state')).statusCode, 200);
      expect((await call('GET', '/google/callback?code=good-code&state=$state')).statusCode, 400, reason: 'used already');
      expect((await call('GET', '/google/callback?code=good-code&state=forged')).statusCode, 400);
      expect((await call('GET', '/google/callback?code=good-code')).statusCode, 400);
      expect(store.googleAccount(bob.id), isNull);
    });

    test('an expired state is refused', () async {
      final d = await device(alice);
      final r = await call('POST', '/v1/google/connect', token: d, body: {'timeZone': tz});
      final state = Uri.parse((jsonDecode(await r.readAsString()) as Map)['url'] as String).queryParameters['state'];
      now = now.add(const Duration(minutes: 11));
      expect((await call('GET', '/google/callback?code=good-code&state=$state')).statusCode, 400);
    });

    test('the person saying no, a bad code, and no long-term access are all explained, and nothing is saved', () async {
      final d = await device(alice);
      Future<String> state() async => Uri.parse((jsonDecode(await (await call('POST', '/v1/google/connect', token: d, body: {'timeZone': tz})).readAsString()) as Map)['url'] as String).queryParameters['state']!;
      var r = await call('GET', '/google/callback?error=access_denied&state=${await state()}');
      expect(r.statusCode, 400);
      expect(await r.readAsString(), contains('Not connected'));
      r = await call('GET', '/google/callback?code=wrong&state=${await state()}');
      expect(r.statusCode, 400);
      google.withoutRefreshToken = true;
      r = await call('GET', '/google/callback?code=good-code&state=${await state()}');
      expect(r.statusCode, 400);
      expect(await r.readAsString(), contains('long-term'));
      expect(store.googleAccount(alice.id), isNull);
    });

    test('text from Google is never put on the page as markup', () async {
      final r = await call('GET', '/google/callback?error=${Uri.encodeComponent('<script>alert(1)</script>')}');
      expect(await r.readAsString(), isNot(contains('<script>')));
    });

    test('a server without Google credentials says so plainly', () async {
      final bare = buildApi(store, config: const ApiConfig(trustProxy: true), clock: () => now);
      final d = (jsonDecode(await (await bare(Request('POST', Uri.parse('http://x/v1/pair'), headers: {'content-type': 'application/json', 'x-forwarded-for': '1.1.1.1'}, body: jsonEncode({'code': store.createInvite(alice.id), 'deviceName': 'p'})))).readAsString()) as Map)['token'] as String;
      final status = await bare(Request('GET', Uri.parse('http://x/v1/google'), headers: {'authorization': 'Bearer $d'}));
      expect((jsonDecode(await status.readAsString()) as Map)['configured'], false);
      final connect = await bare(Request('POST', Uri.parse('http://x/v1/google/connect'), headers: {'authorization': 'Bearer $d', 'content-type': 'application/json'}, body: '{}'));
      expect(connect.statusCode, 501);
    });
  });

  group('tasks become events', () {
    setUp(() async => await connect(alice));

    test('timed, all-day, long, coloured: written the way Google expects, with the task id attached', () async {
      final m = model(alice);
      final p = m.createProject({'name': 'Work'})['id'] as String;
      final timed = m.createTask({'title': 'Meeting', 'project_id': p, 'due_date': '2026-10-20', 'due_time': '14:30', 'duration_minutes': 90, 'priority': 1, 'description': 'Agenda'});
      final allDay = m.createTask({'title': 'Pay rent', 'due_date': '2026-10-21'});
      m.createTask({'title': 'No date'});
      final report = await syncer.syncUser(alice.id);
      expect(report.created, 2);
      final e = eventFor(alice, timed['id'] as String);
      expect(e['summary'], 'Meeting');
      expect(e['start'], {'dateTime': '2026-10-20T14:30:00', 'timeZone': tz});
      expect(e['end'], {'dateTime': '2026-10-20T16:00:00', 'timeZone': tz});
      expect(e['colorId'], '11');
      expect(e['description'], contains('Agenda'));
      expect(e['description'], contains('Project: Work'));
      final d = eventFor(alice, allDay['id'] as String);
      expect(d['start'], {'date': '2026-10-21'});
      expect(d['end'], {'date': '2026-10-22'});
      expect(d.containsKey('colorId'), isFalse);
    });

    test('syncing again with nothing changed does nothing', () async {
      model(alice).createTask({'title': 'Once', 'due_date': '2026-10-20'});
      await syncer.syncUser(alice.id);
      google.log.clear();
      now = now.add(const Duration(minutes: 5));
      final r = await syncer.syncUser(alice.id);
      expect((r.created, r.updated, r.deleted, r.pulled), (0, 0, 0, 0));
      expect(google.log.where((l) => (l.startsWith('POST') || l.startsWith('PATCH') || l.startsWith('DELETE')) && l.contains('/calendar/')), isEmpty);
    });

    test('changing, finishing, un-dating and deleting a task changes or removes its event', () async {
      final m = model(alice);
      final a = m.createTask({'title': 'A', 'due_date': '2026-10-20', 'due_time': '10:00'})['id'] as String;
      final b = m.createTask({'title': 'B', 'due_date': '2026-10-21'})['id'] as String;
      final c = m.createTask({'title': 'C', 'due_date': '2026-10-22'})['id'] as String;
      final d = m.createTask({'title': 'D', 'due_date': '2026-10-23'})['id'] as String;
      await syncer.syncUser(alice.id);
      now = now.add(const Duration(minutes: 5));

      m.updateTask(a, {'title': 'A renamed', 'due_time': '11:15', 'priority': 2});
      m.closeTask(b);
      m.updateTask(c, {'due_date': null});
      m.deleteTask(d);
      final r = await syncer.syncUser(alice.id);
      expect((r.updated, r.deleted), (1, 3));
      final e = eventFor(alice, a);
      expect((e['summary'], (e['start'] as Map)['dateTime'], e['colorId']), ('A renamed', '2026-10-20T11:15:00', '6'));
      expect(google.live(calendarOf(alice)), hasLength(1));
      expect(store.googleEvents(alice.id).keys, [a]);
    });

    test('completing a repeating task moves its event to the next date', () async {
      final m = model(alice);
      final id = m.createTask({'title': 'Weekly', 'due_date': '2026-10-14', 'recurrence': 'every week'})['id'] as String;
      await syncer.syncUser(alice.id);
      expect((eventFor(alice, id)['start'] as Map)['date'], '2026-10-14');
      m.closeTask(id);
      now = now.add(const Duration(minutes: 5));
      await syncer.syncUser(alice.id);
      expect((eventFor(alice, id)['start'] as Map)['date'], '2026-10-21');
      expect(eventFor(alice, id)['description'], contains('Repeats: every week'));
    });

    test('a task that comes back (reopened) gets its event again', () async {
      final m = model(alice);
      final id = m.createTask({'title': 'Undo me', 'due_date': '2026-10-20'})['id'] as String;
      await syncer.syncUser(alice.id);
      m.closeTask(id);
      await syncer.syncUser(alice.id);
      expect(google.live(calendarOf(alice)), isEmpty);
      m.reopenTask(id);
      final r = await syncer.syncUser(alice.id);
      expect(r.created, 1);
    });

    test('events in the calendar that the app did not make are left alone', () async {
      await syncer.syncUser(alice.id);
      final cal = calendarOf(alice);
      google.calendars[cal]!['mine'] = {'id': 'mine', 'status': 'confirmed', 'summary': 'Lunch with Sam', 'updated': now.toIso8601String(), 'start': {'date': '2026-10-20'}, 'end': {'date': '2026-10-21'}};
      model(alice).createTask({'title': 'x', 'due_date': '2026-10-20'});
      now = now.add(const Duration(minutes: 5));
      await syncer.syncUser(alice.id);
      expect(google.calendars[cal]!['mine']!['summary'], 'Lunch with Sam');
      expect(google.calendars[cal]!['mine']!['status'], 'confirmed');
    });

    test('a changed time zone rewrites the timed events', () async {
      final id = model(alice).createTask({'title': 'T', 'due_date': '2026-10-20', 'due_time': '09:00'})['id'] as String;
      await syncer.syncUser(alice.id);
      store.setGoogleTimeZone(alice.id, 'Europe/London');
      now = now.add(const Duration(minutes: 5));
      final r = await syncer.syncUser(alice.id);
      expect(r.updated, 1);
      expect((eventFor(alice, id)['start'] as Map)['timeZone'], 'Europe/London');
    });
  });

  group('events move tasks', () {
    late UserModel m;
    late String id;
    setUp(() async {
      await connect(alice);
      m = model(alice);
      id = m.createTask({'title': 'Movable', 'due_date': '2026-10-20', 'due_time': '10:00'})['id'] as String;
      await syncer.syncUser(alice.id);
      now = now.add(const Duration(minutes: 10));
    });

    void dragInGoogle(Map<String, Object?> start, Map<String, Object?> end) {
      final e = eventFor(alice, id);
      e['start'] = start;
      e['end'] = end;
      e['updated'] = now.toUtc().toIso8601String();
    }

    test('dragging an event to another day and time moves the task, and it is not pushed back', () async {
      dragInGoogle({'dateTime': '2026-10-22T16:00:00+03:00', 'timeZone': tz}, {'dateTime': '2026-10-22T16:30:00+03:00', 'timeZone': tz});
      final r = await syncer.syncUser(alice.id);
      expect(r.pulled, 1);
      final t = (UserModel(store, alice.id).taskView(id)['due'] as Map);
      expect((t['date'], t['time']), ('2026-10-22', '16:00'));
      google.log.clear();
      now = now.add(const Duration(minutes: 5));
      final again = await syncer.syncUser(alice.id);
      expect((again.pulled, again.updated), (0, 0));
      expect(google.log.where((l) => l.startsWith('PATCH')), isEmpty);
    });

    test('making the event longer changes the task\'s duration', () async {
      dragInGoogle({'dateTime': '2026-10-20T10:00:00+03:00', 'timeZone': tz}, {'dateTime': '2026-10-20T12:00:00+03:00', 'timeZone': tz});
      await syncer.syncUser(alice.id);
      expect(UserModel(store, alice.id).taskView(id)['duration_minutes'], 120);
    });

    test('turning a timed event into an all-day event removes the time', () async {
      dragInGoogle({'date': '2026-10-21'}, {'date': '2026-10-22'});
      await syncer.syncUser(alice.id);
      final t = (UserModel(store, alice.id).taskView(id)['due'] as Map);
      expect((t['date'], t['time']), ('2026-10-21', null));
    });

    test('an event moved to another time zone is left alone rather than guessed', () async {
      dragInGoogle({'dateTime': '2026-10-22T16:00:00-04:00', 'timeZone': 'America/New_York'}, {'dateTime': '2026-10-22T16:30:00-04:00', 'timeZone': 'America/New_York'});
      final r = await syncer.syncUser(alice.id);
      expect(r.pulled, 0);
      expect(((UserModel(store, alice.id).taskView(id)['due']) as Map)['date'], '2026-10-20');
    });

    test('if both sides changed, the later change wins', () async {
      // The task is changed in TaskFlow at 09:10, the event is dragged in Google at 09:20: Google wins.
      now = DateTime.utc(2026, 10, 14, 9, 10);
      m.updateTask(id, {'due_date': '2026-10-25'});
      now = DateTime.utc(2026, 10, 14, 9, 20);
      dragInGoogle({'dateTime': '2026-10-22T16:00:00+03:00', 'timeZone': tz}, {'dateTime': '2026-10-22T16:30:00+03:00', 'timeZone': tz});
      await syncer.syncUser(alice.id);
      expect(((UserModel(store, alice.id).taskView(id)['due']) as Map)['date'], '2026-10-22');

      // Now the other way round: the event is dragged at 09:30, the task is changed at 09:40: the task wins.
      now = DateTime.utc(2026, 10, 14, 9, 30);
      dragInGoogle({'dateTime': '2026-10-23T08:00:00+03:00', 'timeZone': tz}, {'dateTime': '2026-10-23T08:30:00+03:00', 'timeZone': tz});
      now = DateTime.utc(2026, 10, 14, 9, 40);
      model(alice).updateTask(id, {'due_date': '2026-10-28'});
      await syncer.syncUser(alice.id);
      expect(((UserModel(store, alice.id).taskView(id)['due']) as Map)['date'], '2026-10-28');
      expect((eventFor(alice, id)['start'] as Map)['dateTime'], startsWith('2026-10-28'));
    });

    test('deleting the event in Google keeps the task, and does not bring the event back until the task changes', () async {
      eventFor(alice, id)['status'] = 'cancelled';
      final cal = calendarOf(alice);
      google.calendars[cal]!.values.first['updated'] = now.toUtc().toIso8601String();
      await syncer.syncUser(alice.id);
      expect(UserModel(store, alice.id).taskExists(id), isTrue);
      expect(store.googleEvents(alice.id)[id]!.state, 'orphaned');
      expect(google.live(cal), isEmpty);
      now = now.add(const Duration(minutes: 5));
      expect((await syncer.syncUser(alice.id)).created, 0);
      expect(google.live(cal), isEmpty);
      model(alice).updateTask(id, {'title': 'Changed after the event was deleted'});
      now = now.add(const Duration(minutes: 5));
      expect((await syncer.syncUser(alice.id)).created, 1, reason: 'the task changed, so it is shown again');
    });
  });

  group('when things go wrong', () {
    test('a calendar deleted in Google is made again, with every event', () async {
      await connect(alice);
      final m = model(alice);
      m.createTask({'title': 'A', 'due_date': '2026-10-20'});
      m.createTask({'title': 'B', 'due_date': '2026-10-21'});
      await syncer.syncUser(alice.id);
      final first = calendarOf(alice);
      google.calendars.remove(first);
      now = now.add(const Duration(minutes: 5));
      final r = await syncer.syncUser(alice.id);
      expect(r.error, isNull);
      expect(calendarOf(alice), isNot(first));
      expect(google.live(calendarOf(alice)), hasLength(2));
    });

    test('an event that vanished is made again when its task changes', () async {
      await connect(alice);
      final id = model(alice).createTask({'title': 'A', 'due_date': '2026-10-20'})['id'] as String;
      await syncer.syncUser(alice.id);
      google.calendars[calendarOf(alice)]!.remove(store.googleEvents(alice.id)[id]!.eventId); // gone without a trace
      model(alice).updateTask(id, {'title': 'A again'});
      now = now.add(const Duration(minutes: 5));
      final r = await syncer.syncUser(alice.id);
      expect(r.error, isNull);
      expect(google.live(calendarOf(alice)).single['summary'], 'A again');
    });

    test('revoked access is reported, remembered, and stops the scheduler trying', () async {
      await connect(alice);
      model(alice).createTask({'title': 'A', 'due_date': '2026-10-20'});
      google.refreshRevoked = true;
      final r = await syncer.syncUser(alice.id);
      expect(r.needsReconnect, isTrue);
      expect(r.error, contains('Connect again'));
      final acct = store.googleAccount(alice.id)!;
      expect(acct.needsReconnect, isTrue);
      expect(acct.lastError, contains('Connect again'));
      expect(store.googleUsers(), isEmpty);
      // Connecting again clears it.
      google.refreshRevoked = false;
      await connect(alice);
      expect(store.googleAccount(alice.id)!.needsReconnect, isFalse);
      expect((await syncer.syncUser(alice.id)).error, isNull);
    });

    test('a task edited by someone else while a sync runs does not break it, and two syncs never overlap', () async {
      await connect(alice);
      model(alice).createTask({'title': 'A', 'due_date': '2026-10-20'});
      final a = syncer.syncUser(alice.id);
      final b = await syncer.syncUser(alice.id);
      expect(b.error, 'A sync is already running');
      expect((await a).error, isNull);
    });
  });

  group('disconnecting and isolation', () {
    test('disconnect revokes Google\'s access and forgets everything; the calendar can be removed too', () async {
      await connect(alice);
      model(alice).createTask({'title': 'A', 'due_date': '2026-10-20'});
      await syncer.syncUser(alice.id);
      final cal = calendarOf(alice);
      final d = await device(alice);
      expect((await call('POST', '/v1/google/disconnect', token: d, body: {'deleteCalendar': true})).statusCode, 204);
      expect(google.revoked, ['ref']);
      expect(google.deletedCalendars, {cal});
      expect(store.googleAccount(alice.id), isNull);
      expect(store.googleEvents(alice.id), isEmpty);
      expect((await call('POST', '/v1/google/disconnect', token: d, body: {})).statusCode, 204, reason: 'disconnecting twice is fine');
    });

    test('disconnect can keep the calendar', () async {
      await connect(alice);
      await syncer.syncUser(alice.id);
      final cal = calendarOf(alice);
      await call('POST', '/v1/google/disconnect', token: await device(alice), body: {'deleteCalendar': false});
      expect(google.calendars.containsKey(cal), isTrue);
    });

    test('two people each get their own calendar and never see each other\'s tasks', () async {
      await connect(alice);
      await connect(bob);
      model(alice).createTask({'title': 'Alice thing', 'due_date': '2026-10-20'});
      model(bob).createTask({'title': 'Bob thing', 'due_date': '2026-10-20'});
      await syncer.syncAll();
      expect(calendarOf(alice), isNot(calendarOf(bob)));
      expect(google.live(calendarOf(alice)).map((e) => e['summary']), ['Alice thing']);
      expect(google.live(calendarOf(bob)).map((e) => e['summary']), ['Bob thing']);
    });

    test('deleting the account removes the Google connection', () async {
      await connect(alice);
      await syncer.syncUser(alice.id);
      final d = await device(alice);
      expect((await call('POST', '/v1/me/delete', token: d, body: {'confirm': 'DELETE MY DATA'})).statusCode, 204);
      expect(store.db.select('SELECT COUNT(*) AS n FROM google_accounts').first['n'], 0);
      expect(store.db.select('SELECT COUNT(*) AS n FROM google_events').first['n'], 0);
    });

    test('the manual sync button runs a sync and reports what it did; it needs a connection', () async {
      final d = await device(alice);
      expect((await call('POST', '/v1/google/sync', token: d)).statusCode, 409);
      await connect(alice);
      model(alice).createTask({'title': 'A', 'due_date': '2026-10-20'});
      final r = await call('POST', '/v1/google/sync', token: d);
      expect(r.statusCode, 200);
      expect((jsonDecode(await r.readAsString()) as Map)['created'], 1);
    });
  });

  group('reading events', () {
    test('wall clock times are read in the person\'s zone only', () {
      expect(readWhen({'start': {'dateTime': '2026-10-20T10:00:00+03:00', 'timeZone': tz}, 'end': {'dateTime': '2026-10-20T10:45:00+03:00', 'timeZone': tz}}, tz), const When('2026-10-20', '10:00', 45));
      expect(readWhen({'start': {'date': '2026-10-20'}, 'end': {'date': '2026-10-21'}}, tz), const When('2026-10-20', null, null));
      expect(readWhen({'start': {'dateTime': '2026-10-20T10:00:00Z'}}, tz), isNull, reason: 'a UTC time cannot be turned into a wall clock without a zone database');
      expect(readWhen({'start': {'dateTime': '2026-10-20T10:00:00+03:00', 'timeZone': 'Europe/Paris'}}, tz), isNull);
      expect(readWhen({'start': {'dateTime': 'garbage'}}, tz), isNull);
      expect(readWhen({}, tz), isNull);
    });
  });
}
