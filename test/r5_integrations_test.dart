import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:taskflow/app.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/sync_engine.dart';
import 'package:taskflow/sync/sync_service.dart';
import 'package:taskflow/sync/transport.dart';
import 'package:taskflow/ui/catalog.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('the app talks to the real server', () {
    late Store server;
    late HttpServer http_;
    late ServerApi api;
    late Account alice;
    late String token;

    setUp(() async {
      server = Store.open(':memory:');
      alice = server.createUser('Alice');
      http_ = await io.serve(buildApi(server, config: const ApiConfig(syncPerMinute: 100000, apiPerMinute: 100000, allowPrivateWebhooks: true)), InternetAddress.loopbackIPv4, 0);
      final base = Uri.parse('http://127.0.0.1:${http_.port}');
      final paired = await ServerApi(base).pair(server.createInvite(alice.id), 'Phone');
      token = paired.token;
      api = ServerApi(base, token: token);
    });
    tearDown(() async {
      await http_.close(force: true);
      server.close();
    });

    test('calendar link: made, readable by any calendar app, replaced, turned off', () async {
      server.applyEdits(alice.id, 'test', [
        FieldEdit('tasks', 't1', '_present', true),
        FieldEdit('tasks', 't1', 'title', 'Dentist'),
        FieldEdit('tasks', 't1', 'project_id', 'inbox'),
        FieldEdit('tasks', 't1', 'due_date', '2026-10-20'),
      ]);
      expect(await api.calendarFeedEnabled(), isFalse);
      final link = await api.createCalendarFeed();
      expect(await api.calendarFeedEnabled(), isTrue);
      final feed = await http.get(link);
      expect(feed.statusCode, 200);
      expect(feed.body, contains('SUMMARY:Dentist'));
      final replaced = await api.createCalendarFeed();
      expect(replaced, isNot(link));
      expect((await http.get(link)).statusCode, 404);
      await api.deleteCalendarFeed();
      expect((await http.get(replaced)).statusCode, 404);
      expect(await api.calendarFeedEnabled(), isFalse);
    });

    test('API tokens: made once, usable on the REST API, listed without the secret, revoked', () async {
      final t = await api.createApiToken('backup script', readOnly: true);
      expect((await http.get(Uri.parse('${api.baseUrl}/api/v1/tasks'), headers: {'authorization': 'Bearer $t'})).statusCode, 200);
      expect((await http.post(Uri.parse('${api.baseUrl}/api/v1/tasks'), headers: {'authorization': 'Bearer $t', 'content-type': 'application/json'}, body: '{"title":"x"}')).statusCode, 403);
      final list = await api.listApiTokens();
      expect((list.single['name'], list.single['readOnly']), ('backup script', true));
      expect(jsonEncode(list), isNot(contains(t)));
      await api.revokeApiToken(list.single['id']! as String);
      expect((await http.get(Uri.parse('${api.baseUrl}/api/v1/tasks'), headers: {'authorization': 'Bearer $t'})).statusCode, 401);
    });

    test('webhooks: added with a secret, called when a task is made, listed, deleted', () async {
      final received = <String>[];
      final receiver = await io.serve((shelf.Request r) async {
        received.add(r.headers['x-taskflow-event'] ?? '');
        return shelf.Response.ok('ok');
      }, InternetAddress.loopbackIPv4, 0);
      addTearDown(() => receiver.close(force: true));
      final secret = await api.createWebhook('http://127.0.0.1:${receiver.port}/hook', const ['task.added']);
      expect(secret, isNotEmpty);
      final listed = await api.listWebhooks();
      expect(listed.single['events'], 'task.added');
      expect(jsonEncode(listed), isNot(contains(secret)));
      await api.deleteWebhook(listed.single['id']! as String);
      expect(await api.listWebhooks(), isEmpty);
    });

    test('incoming webhooks: the address and secret come back once', () async {
      final h = await api.createInboundHook('IFTTT');
      expect(h.url.path, startsWith('/hooks/in/'));
      expect(h.secret, isNotEmpty);
      expect((await api.listInboundHooks()).single['name'], 'IFTTT');
      await api.deleteInboundHook((await api.listInboundHooks()).single['id']! as String);
      expect(await api.listInboundHooks(), isEmpty);
    });

    test('Google: a server without credentials reports it and refuses to connect', () async {
      final s = await api.googleStatus();
      expect((s.configured, s.connected), (false, false));
      await expectLater(api.googleConnectUrl('Asia/Riyadh'), throwsA(isA<SyncTransportException>().having((e) => e.message, 'message', contains('not set up'))));
    });
  });

  group('the integrations screen', () {
    late Catalog catalog;
    late SyncService sync;

    http.Client fakeServer({bool googleConfigured = false, bool feedOn = false}) => MockClient((request) async {
          http.Response json(int status, Object body) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
          switch ('${request.method} ${request.url.path}') {
            case 'POST /v1/pair':
              return json(200, {'token': 'tok_${'x' * 30}', 'deviceId': 'd1', 'userName': 'Alice'});
            case 'POST /v1/sync':
              return json(200, {'cursor': 0, 'more': false, 'changes': []});
            case 'GET /v1/google':
              return json(200, {'configured': googleConfigured, 'connected': false});
            case 'GET /v1/calendar':
              return json(200, {'enabled': feedOn});
            case 'POST /v1/calendar':
              return json(201, {'path': '/ical/secrettoken.ics'});
            case 'GET /v1/api-tokens':
              return json(200, {'tokens': []});
            case 'GET /v1/webhooks':
              return json(200, {'webhooks': []});
            case 'GET /v1/inbound-hooks':
              return json(200, {'hooks': []});
            default:
              return json(404, {'error': 'not_found', 'message': 'no route ${request.url.path}'});
          }
        });

    Future<void> open(WidgetTester tester, {required bool paired, http.Client? client}) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(420, 1400);
      addTearDown(tester.view.reset);
      late Repo repo;
      await tester.runAsync(() async {
        final db = AppDatabase(NativeDatabase.memory());
        repo = Repo(db);
        await db.ensureSyncMeta();
        await db.ensureInbox();
      });
      sync = SyncService(repo, MemoryTokenStore(), client: client ?? fakeServer(), interval: const Duration(hours: 1), debounce: const Duration(hours: 1));
      if (paired) await tester.runAsync(() => sync.pair('http://127.0.0.1:1', 'ABCD-2345', 'Phone'));
      catalog = Catalog(repo)..sync = sync;
      await tester.pumpWidget(TaskFlowApp(catalog: catalog));
      await settle(tester);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Calendar and integrations'), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Calendar and integrations'));
      await tester.pumpAndSettle();
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      catalog.dispose();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('without sync it explains what to do first', (tester) async {
      await open(tester, paired: false);
      expect(find.textContaining('Set up sync first'), findsOneWidget);
      await close(tester);
    });

    testWidgets('with sync it shows each integration, and says when the server has no Google set up', (tester) async {
      await open(tester, paired: true);
      await settle(tester);
      expect(find.text('Google Calendar'), findsOneWidget);
      expect(find.textContaining('not set up for Google yet'), findsOneWidget);
      expect(find.text('Connect Google Calendar'), findsNothing);
      await tester.scrollUntilVisible(find.text('Create a calendar link'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Calendar link'), findsOneWidget);
      expect(find.text('API access'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Webhooks'), 200, scrollable: find.byType(Scrollable).first);
      await close(tester);
    });

    testWidgets('a configured server offers Connect, and creating a calendar link shows the address to copy', (tester) async {
      await open(tester, paired: true, client: fakeServer(googleConfigured: true));
      await settle(tester);
      expect(find.text('Connect Google Calendar'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Create a calendar link'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Create a calendar link'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(find.text('Your calendar link'), findsOneWidget);
      expect(find.textContaining('/ical/secrettoken.ics'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await close(tester);
    });
  });
}
