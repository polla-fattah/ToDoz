import 'dart:convert';
import 'dart:io';

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
import 'package:taskflow_core/sharing.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Catalog catalog;
  late SyncService sync;
  late Repo repo;
  late AppDatabase db;
  final calls = <String>[];

  http.Client fakeServer() => MockClient((request) async {
        http.Response json(int status, Object body) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
        calls.add('${request.method} ${request.url.path}');
        switch ('${request.method} ${request.url.path}') {
          case 'POST /v1/pair':
            return json(200, {'token': 'tok_${'x' * 30}', 'deviceId': 'd1', 'userName': 'Alice', 'userId': 'u-alice'});
          case 'POST /v1/sync':
            return json(200, {'cursor': 0, 'more': false, 'changes': []});
          case 'GET /v1/me':
            return json(200, {'user': {'name': 'Alice', 'id': 'u-alice'}, 'devices': []});
          case 'POST /v1/projects/home/invites':
            return json(201, {'code': 'ABCD-2345', 'expiresInHours': 24, 'role': jsonDecode(request.body)['role']});
          case 'POST /v1/invites/redeem':
            final code = (jsonDecode(request.body) as Map)['code'];
            return code == 'GOOD-CODE' ? json(200, {'projectId': 'other', 'role': 'member'}) : json(401, {'error': 'bad_code', 'message': 'That code is wrong, already used, or has expired'});
          default:
            return json(404, {'error': 'not_found', 'message': 'no route ${request.url.path}'});
        }
      });

  Future<void> open(WidgetTester tester, {List<ShareInfo> shares = const [], Future<void> Function()? seed}) async {
    calls.clear();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 1000);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repo(db);
      await db.ensureSyncMeta();
      await db.ensureInbox();
      await repo.createProject(name: 'Home').then((id) async {
        // Give it a known id so the fake server can match it.
        await db.customStatement("UPDATE projects SET id = 'home' WHERE id = ?", [id]);
      });
      sync = SyncService(repo, MemoryTokenStore(), client: fakeServer(), interval: const Duration(hours: 1), debounce: const Duration(hours: 1));
      await sync.pair('http://127.0.0.1:1', 'ABCD-2345', 'Phone');
      await db.saveShares(shares);
      await seed?.call();
    });
    catalog = Catalog(repo)..sync = sync;
    await tester.pumpWidget(TaskFlowApp(catalog: catalog));
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    catalog.dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> openProjectShare(WidgetTester tester) async {
    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share…'));
    await tester.pumpAndSettle();
  }

  testWidgets('an unshared project offers to invite someone; choosing a role shows the code to give them', (tester) async {
    await open(tester);
    await openProjectShare(tester);
    expect(find.textContaining('This project is private'), findsOneWidget);
    await tester.tap(find.text('Invite someone'));
    await tester.pumpAndSettle();
    expect(find.text('What may they do?'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget, reason: 'the owner may make admins');
    await tester.tap(find.text('Member'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.text('Invitation code'), findsOneWidget);
    expect(find.text('ABCD-2345'), findsOneWidget);
    expect(calls, contains('POST /v1/projects/home/invites'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await close(tester);
  });

  testWidgets('a read-only member sees who is in the project and their own role, and can only leave', (tester) async {
    await open(tester, shares: const [
      ShareInfo(
        projectId: 'home',
        ownerId: 'u-sam',
        myRole: ShareRole.viewer,
        members: [
          ShareMember(userId: 'u-sam', name: 'Sam', role: ShareRole.owner),
          ShareMember(userId: 'u-alice', name: 'Alice', role: ShareRole.viewer),
        ],
      ),
    ]);
    await openProjectShare(tester);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Alice (you)'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    expect(find.text('Invite another person'), findsNothing, reason: 'a viewer cannot invite');
    expect(find.text('Leave project'), findsOneWidget);
    expect(find.text('Stop sharing'), findsNothing);
    await close(tester);
  });

  testWidgets('the owner of a shared project can invite more people and stop sharing', (tester) async {
    await open(tester, shares: const [
      ShareInfo(
        projectId: 'home',
        ownerId: 'u-alice',
        myRole: ShareRole.owner,
        members: [
          ShareMember(userId: 'u-alice', name: 'Alice', role: ShareRole.owner),
          ShareMember(userId: 'u-sam', name: 'Sam', role: ShareRole.member),
        ],
      ),
    ]);
    await openProjectShare(tester);
    expect(find.text('Invite another person'), findsOneWidget);
    expect(find.text('Stop sharing'), findsOneWidget);
    expect(find.text('Leave project'), findsNothing);
    // Sam's row has a menu to change the role or remove him.
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    await close(tester);
  });

  testWidgets('"Join a shared project" takes a code; a wrong one is explained, not called a sign-out', (tester) async {
    await open(tester);
    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join a shared project'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'NOPE-0000');
    await tester.tap(find.text('Join'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(find.textContaining('wrong, already used'), findsOneWidget);
    expect(find.textContaining('signed out'), findsNothing);
    expect(sync.state, isNot(SyncState.signedOut));
    await close(tester);
  });

  testWidgets('a task in a shared project shows who it is assigned to, and the project shows a people icon', (tester) async {
    await open(tester, seed: () async {
      final id = await repo.addTask(title: 'Fix the tap', projectId: 'home');
      await repo.assignTask(id, 'u-sam');
    }, shares: const [
      ShareInfo(
        projectId: 'home',
        ownerId: 'u-alice',
        myRole: ShareRole.owner,
        members: [
          ShareMember(userId: 'u-alice', name: 'Alice', role: ShareRole.owner),
          ShareMember(userId: 'u-sam', name: 'Sam', role: ShareRole.member),
        ],
      ),
    ]);
    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.people_outline), findsOneWidget);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Fix the tap'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget, reason: 'the assignee is shown on the row');
    await tester.tap(find.text('Fix the tap'));
    await tester.pumpAndSettle();
    expect(find.text('Assigned to'), findsOneWidget);
    expect(find.text('Sam'), findsWidgets);
    await close(tester);
  });
}
