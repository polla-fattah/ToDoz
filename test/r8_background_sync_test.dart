import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/background_sync.dart';
import 'package:taskflow/sync/share_notifier.dart';
import 'package:taskflow/sync/sync_service.dart';
import 'package:taskflow_core/sharing.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';

class Recorder implements BackgroundScheduler {
  final calls = <String>[];
  @override
  Future<void> enable() async => calls.add('enable');
  @override
  Future<void> disable() async => calls.add('disable');
}

class RecordingAlerts implements ShareAlerts {
  final shown = <String>[];
  @override
  Future<void> show({required int id, required String title, required String body, String? taskId}) async => shown.add('$title | $body');
}

/// The sync that runs while the app is closed, against the real server code over HTTP.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Store server;
  late HttpServer http;
  late String url;
  late Account aliceAccount;
  late Account bobAccount;
  var clock = DateTime(2026, 10, 19, 9);

  /// One phone or PC: its database, and the token store the closed-app job reads too.
  Future<({Repo repo, SyncService svc, MemoryTokenStore tokens})> device(Account account, String name, {BackgroundScheduler? scheduler}) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.ensureSyncMeta();
    await db.ensureInbox();
    final repo = Repo(db, clock: () => clock);
    final tokens = MemoryTokenStore();
    final svc = SyncService(repo, tokens, scheduler: scheduler, interval: const Duration(hours: 1), debounce: const Duration(hours: 1));
    addTearDown(svc.dispose);
    await svc.pair(url, server.createInvite(account.id), name);
    return (repo: repo, svc: svc, tokens: tokens);
  }

  Future<List<String>> titles(Repo r) async => (await r.watchAllOpen().first).map((t) => t.title).toList()..sort();

  setUp(() async {
    clock = DateTime(2026, 10, 19, 9);
    server = Store.open(':memory:');
    aliceAccount = server.createUser('Alice');
    bobAccount = server.createUser('Bob');
    http = await io.serve(buildApi(server, config: const ApiConfig(syncPerMinute: 100000)), InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${http.port}';
  });
  tearDown(() async {
    await http.close(force: true);
    server.close();
  });

  group('a pass while the app is closed', () {
    test('brings in what another device changed', () async {
      final pc = await device(aliceAccount, 'PC');
      final phone = await device(aliceAccount, 'Phone');
      await pc.repo.addTask(title: 'Added on the PC');
      await pc.svc.syncNow();
      expect(await titles(phone.repo), isEmpty, reason: 'the phone has not synced yet');

      final outcome = await runBackgroundSync(repo: phone.repo, tokens: phone.tokens);
      expect(outcome, BackgroundSyncOutcome.synced);
      expect(await titles(phone.repo), ['Added on the PC']);
      expect(await phone.repo.getSetting(lastRunKey), isNotNull, reason: 'the time of the last run is kept for the Sync screen');
    });

    test('sends what is waiting on the phone', () async {
      final pc = await device(aliceAccount, 'PC');
      final phone = await device(aliceAccount, 'Phone');
      await phone.repo.addTask(title: 'Added on the phone');
      expect(await runBackgroundSync(repo: phone.repo, tokens: phone.tokens), BackgroundSyncOutcome.synced);
      await pc.svc.syncNow();
      expect(await titles(pc.repo), ['Added on the phone']);
    });

    test('does nothing while the app is open, and resumes once it has gone or gone quiet', () async {
      final pc = await device(aliceAccount, 'PC');
      final phone = await device(aliceAccount, 'Phone');
      await pc.repo.addTask(title: 'From the PC');
      await pc.svc.syncNow();

      await phone.repo.setSetting(ForegroundMark.key, '${clock.millisecondsSinceEpoch}');
      expect(await runBackgroundSync(repo: phone.repo, tokens: phone.tokens), BackgroundSyncOutcome.skippedAppOpen);
      expect(await titles(phone.repo), isEmpty);

      await phone.repo.setSetting(ForegroundMark.key, '0'); // the app went to the background
      expect(await ForegroundMark.isActive(phone.repo), isFalse);
      await phone.repo.setSetting(ForegroundMark.key, '${clock.millisecondsSinceEpoch}');
      clock = clock.add(const Duration(minutes: 3)); // the app stopped reporting (it was killed)
      expect(await runBackgroundSync(repo: phone.repo, tokens: phone.tokens), BackgroundSyncOutcome.synced);
      expect(await titles(phone.repo), ['From the PC']);
    });

    test('is not run when it is switched off, the device is not paired, or the server signed it out', () async {
      final phone = await device(aliceAccount, 'Phone');
      await phone.repo.setSetting(SyncService.backgroundSyncKey, '0');
      expect(await runBackgroundSync(repo: phone.repo, tokens: phone.tokens), BackgroundSyncOutcome.switchedOff);
      await phone.repo.setSetting(SyncService.backgroundSyncKey, '1');

      await phone.repo.setSetting('sync.signedout', '1');
      expect(await runBackgroundSync(repo: phone.repo, tokens: phone.tokens), BackgroundSyncOutcome.signedOut);

      final lonely = AppDatabase(NativeDatabase.memory());
      addTearDown(lonely.close);
      await lonely.ensureSyncMeta();
      await lonely.ensureInbox();
      expect(await runBackgroundSync(repo: Repo(lonely), tokens: MemoryTokenStore()), BackgroundSyncOutcome.notPaired);
    });

    test('reports a server that cannot be reached as a failed pass and leaves the data alone', () async {
      final phone = await device(aliceAccount, 'Phone');
      await phone.repo.addTask(title: 'Keep me');
      await http.close(force: true);
      expect(await runBackgroundSync(repo: phone.repo, tokens: phone.tokens), BackgroundSyncOutcome.failed);
      expect(await titles(phone.repo), ['Keep me']);
      expect(await phone.repo.getSetting(lastRunKey), isNull);
    });

    test('tells the person about a comment on a shared task, once', () async {
      final alice = await device(aliceAccount, 'Alice phone');
      final bob = await device(bobAccount, 'Bob phone');
      final p = await alice.repo.createProject(name: 'Home');
      final task = await alice.repo.addTask(title: 'Buy bread', projectId: p);
      await alice.svc.syncNow();
      await bob.svc.api!.redeemInvite(await alice.svc.api!.createInvite(p, ShareRole.member));
      await bob.svc.syncNow();
      await alice.svc.syncNow();

      final alerts = RecordingAlerts();
      // The first pass learns what is already there and stays quiet.
      expect(await runBackgroundSync(repo: bob.repo, tokens: bob.tokens, alerts: alerts), BackgroundSyncOutcome.synced);
      expect(alerts.shown, isEmpty);

      await alice.repo.addComment(task, 'Wholemeal, please');
      await alice.svc.syncNow();
      expect(await runBackgroundSync(repo: bob.repo, tokens: bob.tokens, alerts: alerts), BackgroundSyncOutcome.synced);
      expect(alerts.shown, hasLength(1));
      expect(alerts.shown.single, contains('Alice commented on "Buy bread"'));
      expect(alerts.shown.single, contains('Wholemeal, please'));

      expect(await runBackgroundSync(repo: bob.repo, tokens: bob.tokens, alerts: alerts), BackgroundSyncOutcome.synced);
      expect(alerts.shown, hasLength(1), reason: 'the same comment is not announced again');
    });
  });

  group('scheduling', () {
    test('pairing starts the job, switching it off stops it, unpairing stops it', () async {
      final recorder = Recorder();
      final phone = await device(aliceAccount, 'Phone', scheduler: recorder);
      await pumpEventQueue();
      expect(recorder.calls, contains('enable'));
      expect(phone.svc.backgroundSync, isTrue);

      recorder.calls.clear();
      await phone.svc.setBackgroundSync(false);
      expect(recorder.calls, ['disable']);
      expect(await phone.repo.getSetting(SyncService.backgroundSyncKey), '0');

      recorder.calls.clear();
      await phone.svc.setBackgroundSync(true);
      expect(recorder.calls, ['enable']);

      recorder.calls.clear();
      await phone.svc.unpair();
      expect(recorder.calls, ['disable']);
    });

    test('a restart of the app keeps the choice', () async {
      final recorder = Recorder();
      final phone = await device(aliceAccount, 'Phone', scheduler: recorder);
      await phone.svc.setBackgroundSync(false);

      final again = Recorder();
      final svc = SyncService(phone.repo, phone.tokens, scheduler: again, interval: const Duration(hours: 1), debounce: const Duration(hours: 1));
      addTearDown(svc.dispose);
      await svc.init();
      await pumpEventQueue();
      expect(svc.backgroundSync, isFalse);
      expect(again.calls, ['disable']);
    });

    test('init without the background part starts nothing', () async {
      final recorder = Recorder();
      final phone = await device(aliceAccount, 'Phone', scheduler: recorder);
      recorder.calls.clear();
      final svc = SyncService(phone.repo, phone.tokens, scheduler: recorder);
      addTearDown(svc.dispose);
      await svc.init(background: false);
      await pumpEventQueue();
      expect(svc.paired, isTrue);
      expect(recorder.calls, isEmpty);
    });
  });
}
