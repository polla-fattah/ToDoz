import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/platform/auto_backup.dart';
import 'package:taskflow/security/app_lock.dart';
import 'package:taskflow/security/secret_store.dart';
import 'package:taskflow/ui/lock_screen.dart';

class FakeBiometric implements Biometric {
  FakeBiometric(this.result);
  bool result;
  @override
  Future<bool> available() async => true;
  @override
  Future<bool> authenticate(String reason) async => result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('app lock', () {
    late MemorySecretStore store;
    late DateTime now;
    AppLock make({Biometric? bio}) => AppLock(store, biometric: bio, clock: () => now, rounds: 50);

    setUp(() {
      store = MemorySecretStore();
      now = DateTime(2026, 10, 19, 9);
    });

    test('starts off, and a PIN must be 4 to 12 digits', () async {
      final l = make();
      await l.init();
      expect(l.enabled, isFalse);
      expect(l.locked, isFalse);
      for (final bad in ['123', 'abcd', '1234567890123', '12 4']) {
        await expectLater(l.enable(bad), throwsArgumentError, reason: bad);
      }
    });

    test('the PIN is never stored, only a salted hash', () async {
      final l = make();
      await l.init();
      await l.enable('482913');
      final all = store.values.values.join(' ');
      expect(all, isNot(contains('482913')));
      expect(store.values['taskflow.lock.pin'], startsWith('v1:'));
      // Two locks with the same PIN do not store the same hash (random salt).
      final store2 = MemorySecretStore();
      await AppLock(store2, rounds: 50).enable('482913');
      expect(store2.values['taskflow.lock.pin'], isNot(store.values['taskflow.lock.pin']));
    });

    test('opening the app starts locked; the right PIN unlocks, a wrong one does not', () async {
      await (make()..enabled = false).enable('2468');
      final l = make();
      await l.init();
      expect(l.locked, isTrue);
      expect(await l.unlock('1111'), UnlockResult.wrong);
      expect(l.locked, isTrue);
      expect(await l.unlock('2468'), UnlockResult.ok);
      expect(l.locked, isFalse);
    });

    test('five wrong tries make the next one wait, longer each time, and the wait survives a restart', () async {
      await make().enable('2468');
      final l = make();
      await l.init();
      for (var i = 0; i < 5; i++) {
        expect(await l.unlock('0000'), UnlockResult.wrong);
      }
      expect(l.waitSeconds, greaterThan(0));
      expect(await l.unlock('2468'), UnlockResult.waiting, reason: 'even the right PIN waits');
      final restarted = make();
      await restarted.init();
      expect(restarted.waitSeconds, greaterThan(0));
      now = now.add(const Duration(seconds: 31));
      expect(await restarted.unlock('0000'), UnlockResult.wrong);
      expect(restarted.waitSeconds, greaterThan(30)); // doubled
      now = now.add(const Duration(minutes: 20));
      expect(await restarted.unlock('2468'), UnlockResult.ok);
      expect(restarted.failures, 0);
    });

    test('turning it off needs the PIN', () async {
      final l = make();
      await l.init();
      await l.enable('2468');
      expect(await l.disable('1111'), isFalse);
      expect(l.enabled, isTrue);
      expect(await l.disable('2468'), isTrue);
      expect(l.enabled, isFalse);
      expect(store.values, isEmpty);
    });

    test('it locks again after a long time in the background, not after a short one', () async {
      final l = make();
      await l.init();
      await l.enable('2468');
      l.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 20));
      l.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(l.locked, isFalse);
      l.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 5));
      l.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(l.locked, isTrue);
    });

    test('biometric unlock works only when switched on and passed', () async {
      final bio = FakeBiometric(false);
      final l = make(bio: bio);
      await l.init();
      await l.enable('2468', useBiometric: true);
      l.lockNow();
      expect(await l.unlockWithBiometric(), isFalse);
      expect(l.locked, isTrue);
      bio.result = true;
      expect(await l.unlockWithBiometric(), isTrue);
      expect(l.locked, isFalse);
      await l.setBiometric(false);
      l.lockNow();
      expect(await l.unlockWithBiometric(), isFalse);
    });
  });

  testWidgets('the lock screen hides the app until the right PIN is typed', (tester) async {
    final store = MemorySecretStore();
    final lock = AppLock(store, rounds: 50);
    await tester.runAsync(() => lock.enable('2468'));
    lock.lockNow();
    await tester.pumpWidget(MaterialApp(home: LockGate(lock: lock, child: const Scaffold(body: Text('secret tasks')))));
    expect(find.text('NoteDo is locked'), findsOneWidget);

    Future<void> type(String pin) async {
      for (final d in pin.split('')) {
        await tester.tap(find.text(d).last);
        await tester.pump();
      }
      await tester.tap(find.text('Unlock'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    await type('1111');
    expect(find.text('Wrong PIN'), findsOneWidget);
    expect(find.text('NoteDo is locked'), findsOneWidget);
    await type('2468');
    expect(find.text('NoteDo is locked'), findsNothing);
    expect(find.text('secret tasks'), findsOneWidget);
    lock.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  group('automatic backups', () {
    late AppDatabase db;
    late Repo repo;
    late Directory dir;
    late DateTime clock;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      clock = DateTime(2026, 10, 19, 9);
      repo = Repo(db, clock: () => clock);
      await db.ensureInbox();
      dir = await Directory.systemTemp.createTemp('taskflow_autobackup');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
      await db.close();
    });

    AutoBackup make() => AutoBackup(repo, defaultFolder: () async => dir);
    List<String> files() => dir.listSync().map((e) => p.basename(e.path)).toList()..sort();

    test('writes one file a day and not twice on the same day', () async {
      await repo.addTask(title: 'saved by the backup');
      final b = make();
      final f = await b.runIfDue();
      expect(f, isNotNull);
      expect(files(), ['TaskFlow-auto-2026-10-19.json']);
      expect(await b.runIfDue(), isNull);
      expect(jsonDecode(await f!.readAsString()).toString(), contains('saved by the backup'));
      clock = clock.add(const Duration(days: 1));
      expect(await b.runIfDue(), isNotNull);
      expect(files().length, 2);
    });

    test('keeps only the newest N and leaves other files alone', () async {
      await repo.setSetting('backup.keep', '3');
      File(p.join(dir.path, 'my-notes.txt')).writeAsStringSync('not a backup');
      final b = make();
      for (var i = 0; i < 6; i++) {
        await b.runIfDue();
        clock = clock.add(const Duration(days: 1));
      }
      final names = files();
      expect(names.where((n) => n.startsWith('TaskFlow-auto-')).toList(), [
        'TaskFlow-auto-2026-10-22.json',
        'TaskFlow-auto-2026-10-23.json',
        'TaskFlow-auto-2026-10-24.json',
      ]);
      expect(names, contains('my-notes.txt'));
    });

    test('can be switched off, and a backup is restorable', () async {
      await repo.setSetting('backup.auto', 'false');
      expect(await make().runIfDue(), isNull);
      expect(files(), isEmpty);
      await repo.addTask(title: 'round trip');
      final f = await make().backupNow();
      final restored = AppDatabase(NativeDatabase.memory());
      final r2 = Repo(restored);
      await restored.ensureInbox();
      await r2.replaceAll(await repo.exportBundle());
      expect((await r2.watchAllOpen().first).map((t) => t.title), contains('round trip'));
      expect(f, isNotNull);
      await restored.close();
    });

    test('an unwritable folder is reported, not thrown', () async {
      final blocked = File(p.join(dir.path, 'file-not-folder'))..writeAsStringSync('x');
      await repo.setSetting('backup.folder', p.join(blocked.path, 'sub'));
      expect(await make().backupNow(), isNull);
      expect(await repo.getSetting('backup.error'), contains('Could not write the backup'));
    });
  });

  group('deleting everything', () {
    test('erases tasks and settings, keeps a working Inbox, and queues nothing for the server', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.ensureInbox();
      final repo = Repo(db);
      await db.metaSet('capture', '1');
      await repo.addTask(title: 'gone');
      await repo.createProject(name: 'Gone too');
      await repo.setSetting('weekStart', '7');
      await db.customStatement('DELETE FROM outbox');
      await repo.deleteEverything();
      expect(await repo.watchAllOpen().first, isEmpty);
      expect((await repo.watchProjects().first).map((p) => p.name), ['Inbox']);
      expect(await repo.getSetting('weekStart'), isNull);
      expect((await db.customSelect('SELECT COUNT(*) AS n FROM outbox').getSingle()).read<int>('n'), 0);
      expect(await db.metaGet('capture'), '1', reason: 'capture is restored after the wipe');
    });

    test('restoring a backup keeps this device\'s pairing settings and never exports them', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.ensureInbox();
      final repo = Repo(db);
      await repo.setSetting('sync.url', 'https://sync.example.com');
      await repo.setSetting('weekStart', '7');
      final bundle = await repo.exportBundle();
      expect(bundle.settings.keys, contains('weekStart'));
      expect(bundle.settings.keys.where((k) => k.startsWith('sync.')), isEmpty);
      await repo.replaceAll(bundle);
      expect(await repo.getSetting('sync.url'), 'https://sync.example.com');
      expect(await repo.getSetting('weekStart'), '7');
    });
  });
}
