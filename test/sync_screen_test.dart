import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:taskflow/app.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/sync_service.dart';
import 'package:taskflow/ui/catalog.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// A server that answers like the real one, without a network.
http.Client fakeServer({bool goodCode = true}) => MockClient((request) async {
      http.Response json(int status, Object body) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
      switch ('${request.method} ${request.url.path}') {
        case 'POST /v1/pair':
          return goodCode
              ? json(200, {'token': 'tok_${'x' * 30}', 'deviceId': 'd1', 'userName': 'Alice'})
              : json(401, {'error': 'bad_code', 'message': 'That code is wrong, already used, or has expired'});
        case 'POST /v1/sync':
          return json(200, {'cursor': 0, 'more': false, 'changes': []});
        case 'GET /v1/me':
          return json(200, {
            'user': {'name': 'Alice'},
            'devices': [
              {'id': 'd1', 'name': 'Pixel', 'current': true, 'revoked': false, 'lastSeen': null},
              {'id': 'd2', 'name': 'Office PC', 'current': false, 'revoked': false, 'lastSeen': null},
            ],
          });
        default:
          return json(404, {'error': 'not_found', 'message': 'no such route'});
      }
    });

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Catalog catalog;
  late SyncService sync;

  Future<void> start(WidgetTester tester, http.Client client) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.reset);
    late Repo repo;
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      repo = Repo(db);
      await db.ensureSyncMeta();
      await db.ensureInbox();
    });
    sync = SyncService(repo, MemoryTokenStore(), client: client, interval: const Duration(hours: 1), debounce: const Duration(hours: 1));
    catalog = Catalog(repo)..sync = sync;
    await tester.pumpWidget(TaskFlowApp(catalog: catalog));
    await settle(tester);
    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Set up sync'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Set up sync'));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    catalog.dispose();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> fillAndPair(WidgetTester tester) async {
    await tester.enterText(find.widgetWithText(TextField, 'Server address'), 'sync.example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Pairing code'), 'abcd-2345');
    await tester.pump();
    await tester.tap(find.text('Pair this device'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the pairing form needs an address and a well-formed code, and says sync is not end-to-end encrypted', (tester) async {
    await start(tester, fakeServer());
    expect(find.text('Keep your devices in step'), findsOneWidget);
    expect(find.textContaining('not end-to-end encrypted'), findsOneWidget);
    FilledButton button() => tester.widget<FilledButton>(find.ancestor(of: find.text('Pair this device'), matching: find.byType(FilledButton)));
    expect(button().onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, 'Server address'), 'sync.example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Pairing code'), 'abc');
    await tester.pump();
    expect(button().onPressed, isNull); // code too short

    await tester.enterText(find.widgetWithText(TextField, 'Pairing code'), 'abcd-2345');
    await tester.pump();
    expect(button().onPressed, isNotNull);
    await finish(tester);
  });

  testWidgets('a wrong code shows the server\'s message and stays on the form', (tester) async {
    await start(tester, fakeServer(goodCode: false));
    await fillAndPair(tester);
    expect(find.text('That code is wrong, already used, or has expired'), findsOneWidget);
    expect(find.text('Pair this device'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('pairing shows who is signed in, the devices, and Unpair returns to the form', (tester) async {
    await start(tester, fakeServer());
    await fillAndPair(tester);
    await tester.pumpAndSettle();

    expect(find.text('Up to date'), findsOneWidget);
    expect(find.textContaining('Signed in as Alice'), findsOneWidget);
    expect(find.text('Pixel (this device)'), findsOneWidget);
    expect(find.text('Office PC'), findsOneWidget);
    expect(find.byTooltip('Sign this device out'), findsOneWidget); // only the other device can be signed out here

    await tester.tap(find.text('Unpair'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Unpair'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('Keep your devices in step'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('deleting server data needs the exact phrase typed', (tester) async {
    await start(tester, fakeServer());
    await fillAndPair(tester);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Delete my data on the server'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Delete my data on the server'));
    await tester.pumpAndSettle();
    FilledButton del() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'));
    expect(del().onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Type DELETE MY DATA'), 'delete');
    await tester.pump();
    expect(del().onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Type DELETE MY DATA'), 'DELETE MY DATA');
    await tester.pump();
    expect(del().onPressed, isNotNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await finish(tester);
  });
}
