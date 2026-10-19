import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/sync_engine.dart';
import 'package:taskflow/sync/sync_service.dart';
import 'package:taskflow/sync/transport.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';

/// The app's sync service against the real server code over real HTTP on this machine.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // flutter_test answers every HTTP request with 400 unless this is cleared
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Store server;
  late HttpServer http;
  late String url;
  late Account alice;

  setUp(() async {
    server = Store.open(':memory:');
    alice = server.createUser('Alice');
    http = await io.serve(buildApi(server, config: const ApiConfig(syncPerMinute: 100000)), InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${http.port}';
  });
  tearDown(() async {
    await http.close(force: true);
    server.close();
  });

  var count = 0;

  Future<({SyncService svc, Repo repo, AppDatabase db, MemoryTokenStore tokens})> app({MemoryTokenStore? tokens, AppDatabase? existing, Duration debounce = const Duration(milliseconds: 30)}) async {
    final db = existing ?? AppDatabase(NativeDatabase.memory());
    if (existing == null) {
      await db.ensureSyncMeta();
      await db.ensureInbox();
    }
    final repo = Repo(db);
    final store = tokens ?? MemoryTokenStore();
    final svc = SyncService(repo, store, interval: const Duration(hours: 1), debounce: debounce);
    // Stop the service and let a sync already under way finish before the database goes away,
    // or its last query fails against a closed database and is blamed on the next test.
    addTearDown(() async {
      svc.dispose();
      for (var i = 0; i < 100 && svc.state == SyncState.syncing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (existing == null) await db.close();
    });
    return (svc: svc, repo: repo, db: db, tokens: store);
  }

  Future<void> pair(SyncService svc, {String? code, String name = 'Phone'}) =>
      svc.pair(url, code ?? server.createInvite(alice.id), '$name${++count}');

  /// Waits for background work (an automatic sync) to finish or reach [until].
  Future<void> settle(SyncService svc, {SyncState? until}) async {
    for (var i = 0; i < 200; i++) {
      final done = until != null ? svc.state == until : svc.state != SyncState.syncing;
      if (done) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<List<String>> titles(Repo r) async => (await r.watchAllOpen().first).map((t) => t.title).toList()..sort();

  test('server addresses: https by default, http only on this machine or a private network', () {
    expect(parseServerUrl('sync.example.com')?.toString(), 'https://sync.example.com');
    expect(parseServerUrl('https://sync.example.com/')?.toString(), 'https://sync.example.com');
    for (final ok in ['http://localhost:8080', 'http://10.0.2.2:8080', 'http://192.168.1.20', 'http://172.20.0.5', 'http://100.101.2.3', 'http://pc.tail1234.ts.net']) {
      expect(parseServerUrl(ok), isNotNull, reason: ok);
    }
    for (final bad in ['http://example.com', 'http://10.example.com', 'http://172.32.0.1', 'http://100.1.2.3', 'http://8.8.8.8', 'ftp://example.com', '']) {
      expect(parseServerUrl(bad), isNull, reason: bad);
    }
  });

  test('pairing stores the token, saves the server and uploads existing tasks', () async {
    final a = await app();
    await a.repo.addTask(title: 'before pairing');
    expect(a.svc.state, SyncState.unpaired);

    await pair(a.svc);

    expect(a.svc.state, SyncState.idle);
    expect(a.svc.userName, 'Alice');
    expect(await a.tokens.read(), isNotNull);
    expect(await a.repo.getSetting('sync.url'), url);
    expect(server.fieldCount(alice.id), greaterThan(0));
    expect(a.svc.lastSyncAt, isNotNull);
    expect(a.svc.pendingChanges, 0);
  });

  test('a wrong pairing code says so and leaves the app unpaired', () async {
    final a = await app();
    await expectLater(a.svc.pair(url, 'ZZZZ-9999', 'Phone'), throwsA(isA<SyncTransportException>()));
    expect(a.svc.state, SyncState.unpaired);
    expect(await a.tokens.read(), isNull);
  });

  test('plain http to an internet address is refused before anything is sent', () async {
    final a = await app();
    await expectLater(
      a.svc.pair('http://example.com', server.createInvite(alice.id), 'Phone'),
      throwsA(isA<SyncTransportException>().having((e) => e.message, 'message', contains('http'))),
    );
    expect(a.svc.state, SyncState.unpaired);
  });

  test('two devices of one person end up with the same tasks', () async {
    final a = await app();
    final b = await app();
    await a.repo.addTask(title: 'from phone');
    await pair(a.svc);
    await pair(b.svc, name: 'PC');
    await b.repo.addTask(title: 'from pc');
    await b.svc.syncNow();
    await a.svc.syncNow();

    expect(await titles(a.repo), ['from pc', 'from phone']);
    expect(await titles(b.repo), ['from pc', 'from phone']);
  });

  test('an edit is sent by itself shortly after it is made', () async {
    final a = await app();
    final b = await app();
    await pair(a.svc);
    await pair(b.svc, name: 'PC');

    await a.repo.addTask(title: 'automatic');
    // The debounce timer fires and the sync runs without anyone calling syncNow on a.
    var seen = <String>[];
    for (var i = 0; i < 100 && !seen.contains('automatic'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await settle(b.svc);
      await b.svc.syncNow();
      await settle(b.svc);
      seen = await titles(b.repo);
    }
    expect(seen, ['automatic']);
  });

  test('unpairing keeps the tasks, forgets the token and stops queueing changes', () async {
    final a = await app();
    await a.repo.addTask(title: 'keep me');
    await pair(a.svc);
    await a.svc.unpair();

    expect(a.svc.state, SyncState.unpaired);
    expect(await a.tokens.read(), isNull);
    expect(await a.repo.getSetting('sync.url'), isNull);
    expect(await titles(a.repo), ['keep me']);
    await a.repo.addTask(title: 'after');
    expect(await SyncEngine(a.db, MemoryTransport()).pending(), 0);
  });

  test('a device the owner signs out learns about it and stops, with its tasks intact', () async {
    final a = await app();
    final b = await app();
    await pair(a.svc);
    await pair(b.svc, name: 'PC');

    final me = await a.svc.loadMe();
    final other = me.devices.firstWhere((d) => !d.current);
    await a.svc.revokeDevice(other.id);

    await b.repo.addTask(title: 'offline edit');
    await b.svc.syncNow();
    await settle(b.svc, until: SyncState.signedOut);
    expect(b.svc.state, SyncState.signedOut);
    expect(await titles(b.repo), contains('offline edit'));
    expect(await b.repo.getSetting('sync.signedout'), '1');

    // Restarting the app keeps it signed out rather than retrying forever.
    b.svc.dispose();
    final again = await app(tokens: b.tokens, existing: b.db);
    await again.svc.init();
    expect(again.svc.state, SyncState.signedOut);
  });

  test('a restarted app picks the pairing up again and carries on', () async {
    final a = await app();
    await pair(a.svc);
    a.svc.dispose();
    final restarted = await app(tokens: a.tokens, existing: a.db);
    await restarted.svc.init();
    await settle(restarted.svc);
    expect(restarted.svc.state, SyncState.idle);
    expect(restarted.svc.userName, 'Alice');
    expect(restarted.svc.serverUrl.toString(), url);
  });

  test('an unreachable server is reported and the queued changes are kept for later', () async {
    final a = await app();
    await pair(a.svc);
    await http.close(force: true);
    await a.repo.addTask(title: 'while offline');
    await a.svc.syncNow();

    expect(a.svc.state, SyncState.error);
    expect(a.svc.lastError, isNotNull);
    expect(a.svc.pendingChanges, greaterThan(0));
  });

  test('resetting from the server replaces local tasks with the server copy', () async {
    final a = await app();
    final b = await app(debounce: const Duration(hours: 1)); // so 'never sent' really is never sent
    await pair(a.svc);
    await pair(b.svc, name: 'PC');
    await a.repo.addTask(title: 'on server');
    await a.svc.syncNow();
    await b.repo.addTask(title: 'never sent');
    await b.svc.resetFromServer();

    expect(await titles(b.repo), ['on server']);
  });

  test('deleting my data removes the account on the server and unpairs', () async {
    final a = await app();
    await a.repo.addTask(title: 'mine');
    await pair(a.svc);
    await a.svc.deleteServerData();

    expect(a.svc.state, SyncState.unpaired);
    expect(server.findUser('Alice'), isNull);
    expect(await titles(a.repo), ['mine']);
  });
}
