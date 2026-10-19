import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart' show Value, Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/sync_engine.dart';
import 'package:taskflow/sync/sync_triggers.dart';
import 'package:taskflow_core/backup.dart' show inboxId;
import 'package:taskflow_core/reminder.dart' show ReminderSpec;
import 'package:taskflow_core/sync.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';

/// Calls the real server code in the same process, as if over HTTP.
class InProcessTransport implements SyncTransport {
  InProcessTransport(this.handler, this.token);
  final Handler handler;
  final String token;
  bool offline = false;
  int calls = 0;

  @override
  Future<SyncResponse> sync(SyncRequest request) async {
    if (offline) throw SyncTransportException('offline');
    calls++;
    final response = await handler(Request(
      'POST',
      Uri.parse('http://localhost/v1/sync'),
      headers: {'authorization': 'Bearer $token', 'content-type': 'application/json'},
      body: jsonEncode(request.toJson()),
    ));
    if (response.statusCode == 401) throw SyncTransportException('signed out', unauthorized: true);
    if (response.statusCode != 200) throw SyncTransportException('status ${response.statusCode}');
    return SyncResponse.fromJson(jsonDecode(await response.readAsString()));
  }
}

class Device {
  Device(this.db, this.repo, this.transport, this.engine);
  final AppDatabase db;
  final Repo repo;
  final InProcessTransport transport;
  final SyncEngine engine;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Store server;
  late Handler api;
  late Account alice;
  late Account bob;
  late DateTime wall; // a controllable clock for the "phone"

  setUp(() {
    server = Store.open(':memory:');
    api = buildApi(server, config: const ApiConfig(trustProxy: true, syncPerMinute: 100000));
    alice = server.createUser('Alice');
    bob = server.createUser('Bob');
    wall = DateTime(2026, 10, 19, 9);
  });
  tearDown(() => server.close());

  var counter = 0;

  Future<Device> device(Account who, {bool enable = true, DateTime Function()? clock}) async {
    final code = server.createInvite(who.id);
    final paired = server.redeemInvite(code, 'dev${++counter}')!;
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.ensureSyncMeta();
    await db.ensureInbox();
    final repo = Repo(db, clock: clock ?? () => wall);
    final transport = InProcessTransport(api, paired.token);
    final engine = SyncEngine(db, transport);
    if (enable) await engine.enable();
    return Device(db, repo, transport, engine);
  }

  Future<List<String>> titles(Device d) async =>
      (await d.repo.watchAllOpen().first).map((t) => t.title).toList()..sort();

  group('change capture', () {
    test('nothing is queued while sync is off', () async {
      final d = await device(alice, enable: false);
      await d.repo.addTask(title: 'x');
      expect(await d.engine.pending(), 0);
    });

    test('adding a task queues one change per field plus _present', () async {
      final d = await device(alice);
      final before = await d.engine.pending();
      final id = await d.repo.addTask(title: 'Buy milk', dueDate: '2026-10-20');
      final rows = await d.db.customSelect("SELECT col, value FROM outbox WHERE tbl = 'tasks' AND row_id = ?", variables: [Variable<String>(id)]).get();
      final byCol = {for (final r in rows) r.read<String>('col'): r.read<String>('value')};
      expect(byCol[presentColumn], 'true');
      expect(byCol['title'], '"Buy milk"');
      expect(byCol['due_date'], '"2026-10-20"');
      expect(byCol['deadline'], 'null');
      expect(await d.engine.pending(), greaterThan(before));
      expect(rows.length, syncSchema['tasks']!.length + 1);
    });

    test('an update queues only the changed field, and not when the value is the same', () async {
      final d = await device(alice);
      final id = await d.repo.addTask(title: 'a');
      await d.db.customStatement('DELETE FROM outbox');
      await d.repo.updateTask(id, title: 'b');
      final cols = (await d.db.customSelect("SELECT col FROM outbox WHERE row_id = ?", variables: [Variable<String>(id)]).get()).map((r) => r.read<String>('col')).toSet();
      expect(cols, contains('title')); // updated_at is unchanged here: the test clock does not move
      expect(cols.length, lessThan(3));
      expect(cols, isNot(contains('due_date')));
      await d.db.customStatement('DELETE FROM outbox');
      await d.repo.updateTask(id, title: 'b'); // same title again
      final again = (await d.db.customSelect("SELECT col FROM outbox WHERE row_id = ?", variables: [Variable<String>(id)]).get()).map((r) => r.read<String>('col')).toSet();
      expect(again, isNot(contains('title')));
    });

    test('a hard delete queues _present=false', () async {
      final d = await device(alice);
      final label = await d.repo.createLabel('x');
      await d.db.customStatement('DELETE FROM outbox');
      await d.repo.deleteLabel(label);
      final r = await d.db.customSelect("SELECT value FROM outbox WHERE tbl = 'labels' AND col = '_present'").get();
      expect(r.single.read<String>('value'), 'false');
    });

    test('a task-label link is a row of its own', () async {
      final d = await device(alice);
      final label = await d.repo.createLabel('x');
      final t = await d.repo.addTask(title: 't', labelIds: [label]);
      final r = await d.db.customSelect("SELECT row_id FROM outbox WHERE tbl = 'task_labels'").get();
      expect(r.single.read<String>('row_id'), '$t|$label');
    });

    test('every change is stamped with a valid, increasing clock', () async {
      final d = await device(alice);
      await d.repo.addTask(title: 'a');
      await d.repo.addTask(title: 'b');
      final rows = await d.db.customSelect('SELECT hlc FROM outbox ORDER BY seq').get();
      final hlcs = rows.map((r) => r.read<String>('hlc')).toList();
      expect(hlcs.every(isValidHlc), isTrue);
      expect(hlcs.toSet().length, hlcs.length); // all distinct
      expect(hlcs, orderedEquals([...hlcs]..sort()));
    });

    test('housekeeping with capture off is not queued', () async {
      final d = await device(alice);
      final id = await d.repo.addTask(title: 'old');
      await d.repo.deleteTask(id);
      await d.db.customStatement('DELETE FROM outbox');
      await d.db.customStatement('UPDATE tasks SET deleted_at = 1 WHERE id = ?', [id]); // long ago
      await d.db.customStatement('DELETE FROM outbox');
      await Repo(d.db, clock: () => wall.add(const Duration(days: 60))).purgeOldTrash();
      expect(await d.repo.getTask(id), isNull);
      expect(await d.engine.pending(), 0);
    });

    test('every synced column exists in the database (the schema list matches Drift)', () async {
      final d = await device(alice, enable: false);
      for (final entry in syncSchema.entries) {
        final info = await d.db.customSelect('PRAGMA table_info(${entry.key})').get();
        final names = info.map((r) => r.read<String>('name')).toSet();
        expect(names.containsAll(entry.value), isTrue, reason: '${entry.key}: ${entry.value.where((c) => !names.contains(c))}');
        // Anything in the table but not synced must be on purpose.
        // A snooze belongs to one device; so does knowing whether this device has uploaded an attachment's file.
        final onPurpose = switch (entry.key) { 'tasks' => {'snoozed_until'}, 'attachments' => {'uploaded'}, _ => <String>{} };
        final unsynced = names.difference({...entry.value, 'id', 'task_id', 'label_id', ...onPurpose});
        expect(unsynced, isEmpty, reason: '${entry.key} has unsynced columns $unsynced');
      }
    });

    test('there is a trigger for every column, and the statements are valid SQL', () async {
      final d = await device(alice, enable: false);
      final triggers = (await d.db.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync_%'").get()).map((r) => r.read<String>('name')).toSet();
      expect(triggers, syncTriggerNames().toSet());
    });
  });

  group('two devices', () {
    test('a task created on one appears on the other', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      await phone.repo.addTask(title: 'Buy milk', priority: 2, dueDate: '2026-10-20', dueTime: '08:30');
      await phone.engine.run();
      await tablet.engine.run();
      final t = (await tablet.repo.watchAllOpen().first).single;
      expect((t.title, t.priority, t.dueDate, t.dueTime), ('Buy milk', 2, '2026-10-20', '08:30'));
    });

    test('everything round-trips: projects, sections, labels, sub-tasks, comments, reminders, filters', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      final p = await phone.repo.createProject(name: 'Work', color: 0xFF112233);
      final s = await phone.repo.createSection(p, 'Todo');
      final l = await phone.repo.createLabel('urgent');
      final t = await phone.repo.addTask(title: 'Report', projectId: p, sectionId: s, labelIds: [l]);
      final sub = await phone.repo.addTask(title: 'Outline', parentId: t);
      await phone.repo.addComment(t, 'note');
      await phone.repo.addReminder(t, const ReminderSpec.before(15));
      await phone.repo.createFilter(name: 'F', query: 'p1');
      await phone.repo.completeTask(sub);
      await phone.engine.run();
      await tablet.engine.run();

      expect((await tablet.repo.getProject(p))!.name, 'Work');
      expect((await tablet.repo.watchSections(p).first).single.name, 'Todo');
      expect((await tablet.repo.watchLabels().first).single.name, 'urgent');
      final got = (await tablet.repo.getTask(t))!;
      expect((got.projectId, got.sectionId), (p, s));
      expect((await tablet.repo.watchLabelLinks().first).single.labelId, l);
      expect((await tablet.repo.getTask(sub))!.parentId, t);
      expect((await tablet.repo.getTask(sub))!.completedAt, isNotNull);
      expect((await tablet.repo.watchComments(t).first).single.body, 'note');
      expect((await tablet.repo.watchReminders(t).first).single.spec, '15m');
      expect((await tablet.repo.watchFilters().first).single.query, 'p1');
      expect(await tablet.repo.completedOn(DateTime(2026, 10, 19)), 1);
    });

    test('edits to different fields from two devices both survive (FR-S3)', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      final id = await phone.repo.addTask(title: 'Report');
      await phone.engine.run();
      await tablet.engine.run();

      await phone.repo.updateTask(id, title: 'Report v2'); // phone edits the title
      await tablet.repo.updateTask(id, priority: 1); // tablet edits the priority, offline from the phone
      await phone.engine.run();
      await tablet.engine.run();
      await phone.engine.run();

      for (final d in [phone, tablet]) {
        final t = (await d.repo.getTask(id))!;
        expect((t.title, t.priority), ('Report v2', 1), reason: 'device ${d.transport.token}');
      }
    });

    test('the later edit of the same field wins on both devices (FR-S3)', () async {
      final phone = await device(alice, clock: () => wall);
      final tablet = await device(alice, clock: () => wall);
      final id = await phone.repo.addTask(title: 'start');
      await phone.engine.run();
      await tablet.engine.run();

      await phone.repo.updateTask(id, title: 'edited on phone');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tablet.repo.updateTask(id, title: 'edited on tablet, later');
      // The tablet synced first, but its edit is still the later one.
      await tablet.engine.run();
      await phone.engine.run();
      await tablet.engine.run();

      expect((await phone.repo.getTask(id))!.title, 'edited on tablet, later');
      expect((await tablet.repo.getTask(id))!.title, 'edited on tablet, later');
    });

    test('a phone whose clock is far behind cannot make its old edit win', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      final id = await phone.repo.addTask(title: 'start');
      await phone.engine.run();
      await tablet.engine.run();

      // The tablet edits now; then the phone, after receiving that edit, edits again.
      await tablet.repo.updateTask(id, title: 'tablet first');
      await tablet.engine.run();
      await phone.engine.run(); // phone receives the tablet clock and moves its floor above it
      await phone.repo.updateTask(id, title: 'phone second');
      await phone.engine.run();
      await tablet.engine.run();
      expect((await tablet.repo.getTask(id))!.title, 'phone second');
    });

    test('a delete on one device removes the task on the other; a restore brings it back (FR-S4)', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      final id = await phone.repo.addTask(title: 'x');
      await phone.engine.run();
      await tablet.engine.run();

      final ids = await phone.repo.deleteTask(id);
      await phone.engine.run();
      await tablet.engine.run();
      expect(await titles(tablet), isEmpty);
      expect((await tablet.repo.getTask(id))!.deletedAt, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await phone.repo.restoreTasks(ids);
      await phone.engine.run();
      await tablet.engine.run();
      expect(await titles(tablet), ['x']);
    });

    test('a permanent delete on one device removes the row on the other', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      final l = await phone.repo.createLabel('gone');
      await phone.engine.run();
      await tablet.engine.run();
      expect(await tablet.repo.watchLabels().first, hasLength(1));
      await phone.repo.deleteLabel(l);
      await phone.engine.run();
      await tablet.engine.run();
      expect(await tablet.repo.watchLabels().first, isEmpty);
    });

    test('an edit made before a delete does not bring the row back', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      final l = await phone.repo.createLabel('x');
      await phone.engine.run();
      await tablet.engine.run();

      await tablet.repo.updateLabel(l, name: 'renamed'); // earlier
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await phone.repo.deleteLabel(l); // later
      await phone.engine.run();
      await tablet.engine.run();
      await phone.engine.run();
      await tablet.engine.run();
      expect(await phone.repo.watchLabels().first, isEmpty);
      expect(await tablet.repo.watchLabels().first, isEmpty);
    });

    test('removing a label from a task, then re-adding it, converges', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      final l = await phone.repo.createLabel('x');
      final t = await phone.repo.addTask(title: 't', labelIds: [l]);
      await phone.engine.run();
      await tablet.engine.run();
      await phone.repo.updateTask(t, labelIds: []);
      await phone.engine.run();
      await tablet.engine.run();
      expect(await tablet.repo.watchLabelLinks().first, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await phone.repo.updateTask(t, labelIds: [l]);
      await phone.engine.run();
      await tablet.engine.run();
      expect((await tablet.repo.watchLabelLinks().first).single.labelId, l);
    });
  });

  group('connectivity and recovery', () {
    test('offline edits queue up and send once the connection returns', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      phone.transport.offline = true;
      await phone.repo.addTask(title: 'offline 1');
      await phone.repo.addTask(title: 'offline 2');
      await expectLater(phone.engine.run(), throwsA(isA<SyncTransportException>()));
      expect(await phone.engine.pending(), greaterThan(0));
      phone.transport.offline = false;
      await phone.engine.run();
      expect(await phone.engine.pending(), 0);
      await tablet.engine.run();
      expect(await titles(tablet), ['offline 1', 'offline 2']);
    });

    test('a failed send keeps the queue, and retrying sends no duplicates', () async {
      final phone = await device(alice);
      await phone.repo.addTask(title: 'x');
      phone.transport.offline = true;
      await expectLater(phone.engine.run(), throwsA(anything));
      phone.transport.offline = false;
      await phone.engine.run();
      await phone.engine.run();
      final fields = server.fieldCount(alice.id);
      await phone.engine.run();
      expect(server.fieldCount(alice.id), fields);
    });

    test('syncing with nothing to do sends nothing and stops', () async {
      final phone = await device(alice);
      await phone.engine.run();
      final calls = phone.transport.calls;
      final report = await phone.engine.run();
      expect((report.pushed, report.pulled, report.rounds), (0, 0, 1));
      expect(phone.transport.calls, calls + 1);
    });

    test('many edits to one field travel as one', () async {
      final phone = await device(alice);
      final id = await phone.repo.addTask(title: 'v0');
      await phone.engine.run();
      for (var i = 1; i <= 20; i++) {
        await phone.repo.updateTask(id, title: 'v$i');
      }
      final report = await phone.engine.run();
      // The task's title travels once, not twenty times (updated_at does not change: the test clock is fixed);
      // each of the 20 edits also left one activity row (its 10 fields plus _present), and those all travel.
      expect(report.pushed, 1 + 20 * (syncSchema['activity']!.length + 1));
      final tablet = await device(alice);
      await tablet.engine.run();
      expect((await tablet.repo.getTask(id))!.title, 'v20');
    });

    test('a large amount of data is paged across several rounds', () async {
      final phone = await device(alice);
      for (var i = 0; i < 40; i++) {
        await phone.repo.addTask(title: 'task $i');
      }
      final report = await phone.engine.run();
      expect(report.rounds, greaterThan(1));
      final tablet = await device(alice);
      await tablet.engine.run();
      expect((await tablet.repo.watchAllOpen().first), hasLength(40));
    });

    test('a device that is revoked is told so', () async {
      final phone = await device(alice);
      final info = server.listDevices(alice.id).first;
      server.revokeDevice(alice.id, info.id);
      await phone.repo.addTask(title: 'x');
      await expectLater(
        phone.engine.run(),
        throwsA(isA<SyncTransportException>().having((e) => e.unauthorized, 'unauthorized', isTrue)),
      );
    });

    test('resetting from the server gives back exactly the server\'s data', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      await phone.repo.addTask(title: 'from phone');
      await phone.engine.run();
      await tablet.repo.addTask(title: 'unsent on tablet');
      await tablet.engine.resetFromServer();
      expect(await titles(tablet), ['from phone']);
      expect(await tablet.engine.pending(), 0);
      expect(await tablet.engine.enabled, isTrue);
    });

    test('turning sync off keeps the data and stops queueing', () async {
      final phone = await device(alice);
      await phone.repo.addTask(title: 'keep me');
      await phone.engine.disable();
      await phone.repo.addTask(title: 'more');
      expect(await phone.engine.pending(), 0);
      expect(await titles(phone), ['keep me', 'more']);
    });

    test('the first sync uploads data that was on the device before pairing', () async {
      final phone = await device(alice, enable: false);
      await phone.repo.addTask(title: 'before pairing');
      final p = await phone.repo.createProject(name: 'Old project');
      await phone.engine.enable();
      await phone.engine.run();
      final tablet = await device(alice);
      await tablet.engine.run();
      expect(await titles(tablet), ['before pairing']);
      expect((await tablet.repo.getProject(p))!.name, 'Old project');
    });

    test('the Inbox is shared, not duplicated', () async {
      final phone = await device(alice);
      final tablet = await device(alice);
      await phone.engine.run();
      await tablet.engine.run();
      await phone.engine.run();
      for (final d in [phone, tablet]) {
        final inboxes = (await d.repo.watchProjects().first).where((p) => p.id == inboxId);
        expect(inboxes, hasLength(1));
      }
    });
  });

  group('people stay separate end to end (SEC-6)', () {
    test('Bob\'s device never receives Alice\'s tasks', () async {
      final a = await device(alice);
      final b = await device(bob);
      await a.repo.addTask(title: 'ALICE-ONLY');
      await b.repo.addTask(title: 'BOB-ONLY');
      await a.engine.run();
      await b.engine.run();
      await a.engine.run();
      expect(await titles(a), ['ALICE-ONLY']);
      expect(await titles(b), ['BOB-ONLY']);
    });
  });

  group('random interleavings converge', () {
    test('three devices, random edits, random sync order: all end identical', () async {
      final rnd = Random(2026);
      final devices = [await device(alice), await device(alice), await device(alice)];
      final ids = <String>[];
      final firstTask = await devices[0].repo.addTask(title: 'seed');
      ids.add(firstTask);
      for (final d in devices) {
        await d.engine.run();
      }
      for (var step = 0; step < 120; step++) {
        final d = devices[rnd.nextInt(devices.length)];
        switch (rnd.nextInt(6)) {
          case 0:
            ids.add(await d.repo.addTask(title: 'task ${rnd.nextInt(1000)}'));
          case 1:
            final id = ids[rnd.nextInt(ids.length)];
            if (await d.repo.getTask(id) != null) await d.repo.updateTask(id, title: 'title ${rnd.nextInt(1000)}');
          case 2:
            final id = ids[rnd.nextInt(ids.length)];
            if (await d.repo.getTask(id) != null) await d.repo.updateTask(id, priority: 1 + rnd.nextInt(4));
          case 3:
            final id = ids[rnd.nextInt(ids.length)];
            if (await d.repo.getTask(id) != null) await d.repo.updateTask(id, dueDate: Value(rnd.nextBool() ? '2026-10-${10 + rnd.nextInt(18)}' : null));
          case 4:
            final id = ids[rnd.nextInt(ids.length)];
            final t = await d.repo.getTask(id);
            if (t != null) {
              if (t.deletedAt == null) {
                await d.repo.deleteTask(id);
              } else {
                await d.repo.restoreTasks([id]);
              }
            }
          case 5:
            await d.engine.run();
        }
        await Future<void>.delayed(const Duration(milliseconds: 1)); // distinct clock milliseconds
      }
      // Quiesce: everyone sends, then everyone receives, twice.
      for (var round = 0; round < 3; round++) {
        for (final d in devices) {
          await d.engine.run();
        }
      }
      Future<List<String>> snapshot(Device d) async {
        final rows = await d.db.customSelect(
          'SELECT id, title, priority, due_date, deleted_at IS NULL AS live FROM tasks ORDER BY id',
        ).get();
        return [for (final r in rows) '${r.read<String>('id')}|${r.read<String>('title')}|${r.read<int>('priority')}|${r.readNullable<String>('due_date')}|${r.read<int>('live')}'];
      }

      final base = await snapshot(devices[0]);
      expect(base, isNotEmpty);
      expect(await snapshot(devices[1]), base);
      expect(await snapshot(devices[2]), base);
    });
  });

  group('activity log', () {
    test('travels to the other device once, and applying it does not log it again', () async {
      final phone = await device(alice);
      final pc = await device(alice);
      final id = await phone.repo.addTask(title: 'logged');
      await phone.repo.updateTask(id, priority: 1);
      await phone.engine.run();
      await pc.engine.run();
      Future<List<String>> events(Device d) async =>
          [for (final e in await d.db.select(d.db.activity).get()) '${e.entityType}:${e.event}:${e.field}:${e.title}'..toString()]..sort();
      expect(await events(phone), isNotEmpty);
      expect(await events(pc), await events(phone), reason: 'same history on both, no duplicates');
      // The PC's own action adds one more, and it reaches the phone.
      await pc.repo.completeTask(id);
      await pc.engine.run();
      await phone.engine.run();
      expect(await events(phone), await events(pc));
      expect((await events(phone)).where((e) => e.contains(':complete:')).length, 1);
    });
  });
}
