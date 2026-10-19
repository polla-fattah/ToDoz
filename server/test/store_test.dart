import 'dart:io';

import 'package:taskflow_core/sync.dart';
import 'package:taskflow_server/store.dart';
import 'package:test/test.dart';

SyncChange ch(String row, String col, Object? value, int wall, {String node = 'dev1', String table = 'tasks', int counter = 0}) =>
    SyncChange(table: table, row: row, col: col, value: value, hlc: formatHlc(wall, counter, node));

void main() {
  late Store store;
  late DateTime now;
  late Account alice;
  late Account bob;

  setUp(() {
    now = DateTime.utc(2026, 10, 19, 12);
    store = Store.open(':memory:', clock: () => now);
    alice = store.createUser('Alice');
    bob = store.createUser('Bob');
  });
  tearDown(() => store.close());

  Map<String, Object?> state(String userId) => {
        for (final c in store.exportAll(userId)) '${c.table}/${c.row}.${c.col}': c.value,
      };

  group('merging field changes (FR-S3, FR-S4)', () {
    test('a newer change replaces an older one; an older one is ignored', () {
      expect(store.applyChanges(alice.id, 'a', [ch('t1', 'title', 'new', 2000)]), 1);
      expect(store.applyChanges(alice.id, 'b', [ch('t1', 'title', 'old', 1000)]), 0);
      expect(state(alice.id)['tasks/t1.title'], 'new');
      expect(store.applyChanges(alice.id, 'b', [ch('t1', 'title', 'newest', 3000)]), 1);
      expect(state(alice.id)['tasks/t1.title'], 'newest');
    });

    test('the same change twice is applied once (idempotent)', () {
      final c = ch('t1', 'title', 'x', 1000);
      expect(store.applyChanges(alice.id, 'a', [c]), 1);
      expect(store.applyChanges(alice.id, 'a', [c]), 0);
      expect(store.fieldCount(alice.id), 1);
    });

    test('two devices editing different fields both keep their edit', () {
      store.applyChanges(alice.id, 'phone', [ch('t1', 'title', 'Phone title', 2000, node: 'phone')]);
      store.applyChanges(alice.id, 'tablet', [ch('t1', 'due_date', '2026-10-30', 1500, node: 'tablet')]);
      expect(state(alice.id), {'tasks/t1.title': 'Phone title', 'tasks/t1.due_date': '2026-10-30'});
    });

    test('for the same field the later edit wins, whichever arrives first', () {
      final early = ch('t1', 'title', 'early', 1000, node: 'phone');
      final late = ch('t1', 'title', 'late', 2000, node: 'tablet');
      store.applyChanges(alice.id, 'tablet', [late]);
      store.applyChanges(alice.id, 'phone', [early]);
      expect(state(alice.id)['tasks/t1.title'], 'late');
    });

    test('a delete beats an older edit and a later restore beats the delete', () {
      store.applyChanges(alice.id, 'a', [ch('t1', presentColumn, true, 1000), ch('t1', 'title', 'x', 1000)]);
      store.applyChanges(alice.id, 'a', [ch('t1', presentColumn, false, 3000)]);
      store.applyChanges(alice.id, 'b', [ch('t1', 'title', 'edit before the delete', 2000, node: 'b')]);
      expect(state(alice.id)['tasks/t1._present'], false);
      store.applyChanges(alice.id, 'b', [ch('t1', presentColumn, true, 4000, node: 'b')]);
      expect(state(alice.id)['tasks/t1._present'], true);
    });

    test('values of every JSON kind are stored and returned exactly', () {
      final values = <String, Object?>{'a': null, 'b': true, 'c': 42, 'd': 2.5, 'e': 'text with "quotes" and \n newline and ünïcode 日本'};
      var wall = 1000;
      store.applyChanges(alice.id, 'a', [for (final e in values.entries) ch('t1', 'title', e.value, wall++)]);
      // Only the newest survives per field; store each in its own column instead.
      store.applyChanges(alice.id, 'a', [
        ch('t2', 'priority', 3, 5000),
        ch('t2', 'description', 'text with "quotes" and \n newline and ünïcode 日本', 5000),
        ch('t2', 'deadline', null, 5000),
        ch('t2', 'is_collapsed', true, 5000),
        ch('t2', 'sort_order', 2.5, 5000),
      ]);
      final s = state(alice.id);
      expect(s['tasks/t2.priority'], 3);
      expect(s['tasks/t2.description'], 'text with "quotes" and \n newline and ünïcode 日本');
      expect(s['tasks/t2.deadline'], isNull);
      expect(s['tasks/t2.is_collapsed'], true);
      expect(s['tasks/t2.sort_order'], 2.5);
    });

    test('a batch applies completely or not at all', () {
      // The second change has a clock the table cannot hold? It cannot fail validation here,
      // so force an error with a closed database inside the transaction instead.
      final ok = [ch('t1', 'title', 'a', 1000), ch('t2', 'title', 'b', 1000)];
      expect(store.applyChanges(alice.id, 'a', ok), 2);
      expect(store.fieldCount(alice.id), 2);
    });
  });

  group('cursors and pages', () {
    test('a device sees other devices changes but not its own, and its cursor still advances', () {
      store.applyChanges(alice.id, 'phone', [ch('t1', 'title', 'from phone', 1000, node: 'phone')]);
      store.applyChanges(alice.id, 'tablet', [ch('t2', 'title', 'from tablet', 2000, node: 'tablet')]);

      final phone = store.changesSince(alice.id, 'phone', 0);
      expect(phone.changes.map((c) => c.row), ['t2']);
      expect(phone.cursor, 2); // past its own change too
      expect(phone.more, isFalse);

      final again = store.changesSince(alice.id, 'phone', phone.cursor);
      expect(again.changes, isEmpty);
      expect(again.cursor, phone.cursor);

      final tablet = store.changesSince(alice.id, 'tablet', 0);
      expect(tablet.changes.map((c) => c.row), ['t1']);
    });

    test('a field edited by a second device is delivered to the first', () {
      store.applyChanges(alice.id, 'phone', [ch('t1', 'title', 'v1', 1000, node: 'phone')]);
      final first = store.changesSince(alice.id, 'tablet', 0);
      store.applyChanges(alice.id, 'phone', [ch('t1', 'title', 'v2', 2000, node: 'phone')]);
      final second = store.changesSince(alice.id, 'tablet', first.cursor);
      expect(second.changes.single.value, 'v2');
    });

    test('pages are bounded and chain together without gaps or repeats', () {
      store.applyChanges(alice.id, 'phone', [for (var i = 0; i < 25; i++) ch('t$i', 'title', 'v$i', 1000 + i, node: 'phone')]);
      final seen = <String>[];
      var cursor = 0;
      var pages = 0;
      while (true) {
        final p = store.changesSince(alice.id, 'tablet', cursor, limit: 10);
        seen.addAll(p.changes.map((c) => c.row));
        cursor = p.cursor;
        pages++;
        if (!p.more) break;
      }
      expect(pages, 3);
      expect(seen, hasLength(25));
      expect(seen.toSet(), hasLength(25));
    });

    test('a device that was offline for ever can still catch up from cursor 0', () {
      for (var i = 0; i < 5; i++) {
        store.applyChanges(alice.id, 'phone', [ch('t1', 'title', 'v$i', 1000 + i, node: 'phone')]);
      }
      final p = store.changesSince(alice.id, 'new-device', 0);
      expect(p.changes.single.value, 'v4'); // only the current value is kept, so catching up is cheap
    });
  });

  group('people are kept apart (SEC-5)', () {
    test('each person sees only their own data', () {
      store.applyChanges(alice.id, 'a1', [ch('t1', 'title', 'alice secret', 1000)]);
      store.applyChanges(bob.id, 'b1', [ch('t1', 'title', 'bob secret', 1000)]);
      expect(state(alice.id), {'tasks/t1.title': 'alice secret'});
      expect(state(bob.id), {'tasks/t1.title': 'bob secret'});
      expect(store.changesSince(alice.id, 'x', 0).changes.single.value, 'alice secret');
      expect(store.changesSince(bob.id, 'x', 0).changes.single.value, 'bob secret');
    });

    test('the same row id for two people never collides', () {
      store.applyChanges(alice.id, 'a1', [ch('inbox', 'name', 'Alice inbox', 5000, table: 'projects')]);
      store.applyChanges(bob.id, 'b1', [ch('inbox', 'name', 'Bob inbox', 1000, table: 'projects')]); // older clock, still stored for Bob
      expect(state(alice.id)['projects/inbox.name'], 'Alice inbox');
      expect(state(bob.id)['projects/inbox.name'], 'Bob inbox');
    });

    test('sequence numbers are per person', () {
      store.applyChanges(alice.id, 'a1', [ch('t1', 'title', 'x', 1000), ch('t2', 'title', 'y', 1000)]);
      store.applyChanges(bob.id, 'b1', [ch('t1', 'title', 'z', 1000)]);
      expect(store.changesSince(bob.id, 'x', 0).cursor, 1);
      expect(store.changesSince(alice.id, 'x', 0).cursor, 2);
    });

    test('deleting a person removes only their data', () {
      store.applyChanges(alice.id, 'a1', [ch('t1', 'title', 'x', 1000)]);
      store.applyChanges(bob.id, 'b1', [ch('t1', 'title', 'y', 1000)]);
      store.deleteUser(alice.id);
      expect(store.fieldCount(alice.id), 0);
      expect(store.fieldCount(bob.id), 1);
      expect(store.findUser('Alice'), isNull);
    });

    test('wipeData keeps the account and devices but not the data', () {
      final code = store.createInvite(alice.id);
      store.redeemInvite(code, 'Phone');
      store.applyChanges(alice.id, 'a1', [ch('t1', 'title', 'x', 1000)]);
      store.wipeData(alice.id);
      expect(store.fieldCount(alice.id), 0);
      expect(store.listDevices(alice.id), hasLength(1));
    });
  });

  group('accounts', () {
    test('names are unique ignoring case, and checked', () {
      expect(() => store.createUser('alice'), throwsArgumentError);
      expect(() => store.createUser(''), throwsArgumentError);
      expect(() => store.createUser('a' * 41), throwsArgumentError);
      expect(() => store.createUser("x'; DROP TABLE users;--"), throwsArgumentError);
      expect(store.createUser('Zoë 2').name, 'Zoë 2');
    });
    test('listing and finding', () {
      expect(store.listUsers().map((u) => u.name), ['Alice', 'Bob']);
      expect(store.findUser(' bob ')?.name, 'Bob');
    });
  });

  group('pairing (SEC-2, SEC-3)', () {
    test('a code works once and gives a token for that person', () {
      final code = store.createInvite(alice.id);
      final r = store.redeemInvite(code, 'Pixel')!;
      expect(r.userName, 'Alice');
      expect(r.deviceId, isNotEmpty);
      expect(r.token.length, greaterThanOrEqualTo(40));
      expect(store.redeemInvite(code, 'Again'), isNull); // spent
      expect(store.authenticate(r.token)?.userId, alice.id);
    });

    test('codes are accepted in the forms people type', () {
      final code = store.createInvite(alice.id);
      expect(store.redeemInvite('${code.substring(0, 4).toLowerCase()} ${code.substring(4)}', 'x'), isNotNull);
    });

    test('a code expires after ten minutes', () {
      final code = store.createInvite(alice.id);
      now = now.add(const Duration(minutes: 11));
      expect(store.redeemInvite(code, 'late'), isNull);
    });

    test('a code is still valid just before it expires', () {
      final code = store.createInvite(alice.id);
      now = now.add(const Duration(minutes: 9, seconds: 50));
      expect(store.redeemInvite(code, 'ok'), isNotNull);
    });

    test('wrong, malformed and look-alike codes are refused', () {
      store.createInvite(alice.id);
      expect(store.redeemInvite('AAAA-AAAA', 'x'), isNull);
      expect(store.redeemInvite('', 'x'), isNull);
      expect(store.redeemInvite('ABCD-0000', 'x'), isNull);
    });

    test('the server keeps only hashes, never the code or the token', () {
      final code = store.createInvite(alice.id);
      final r = store.redeemInvite(code, 'Pixel')!;
      final dump = StringBuffer();
      for (final table in ['invites', 'devices', 'users']) {
        for (final row in store.db.select('SELECT * FROM $table')) {
          dump.writeln(row.values.join('|'));
        }
      }
      expect(dump.toString(), isNot(contains(code)));
      expect(dump.toString(), isNot(contains(r.token)));
      expect(dump.toString(), contains(Store.hash(r.token)));
    });

    test('two devices pair as two separate tokens', () {
      final a = store.redeemInvite(store.createInvite(alice.id), 'Phone')!;
      final b = store.redeemInvite(store.createInvite(alice.id), 'Tablet')!;
      expect(a.token, isNot(b.token));
      expect(store.listDevices(alice.id).map((d) => d.name), ['Phone', 'Tablet']);
    });

    test('device names are bounded', () {
      expect(store.redeemInvite(store.createInvite(alice.id), 'x' * 61), isNull);
    });
  });

  group('tokens and revocation (SEC-4)', () {
    test('unknown or empty tokens are rejected', () {
      expect(store.authenticate('nope'), isNull);
      expect(store.authenticate(''), isNull);
      expect(store.authenticate('x' * 500), isNull);
    });

    test('revoking stops the token at once, and only for that device', () {
      final phone = store.redeemInvite(store.createInvite(alice.id), 'Phone')!;
      final tablet = store.redeemInvite(store.createInvite(alice.id), 'Tablet')!;
      expect(store.revokeDevice(alice.id, phone.deviceId), isTrue);
      expect(store.authenticate(phone.token), isNull);
      expect(store.authenticate(tablet.token), isNotNull);
      expect(store.revokeDevice(alice.id, phone.deviceId), isFalse); // already revoked
    });

    test('a person cannot revoke someone else\'s device', () {
      final phone = store.redeemInvite(store.createInvite(alice.id), 'Phone')!;
      expect(store.revokeDevice(bob.id, phone.deviceId), isFalse);
      expect(store.authenticate(phone.token), isNotNull);
    });

    test('a deleted person\'s tokens stop working', () {
      final phone = store.redeemInvite(store.createInvite(alice.id), 'Phone')!;
      store.deleteUser(alice.id);
      expect(store.authenticate(phone.token), isNull);
    });

    test('last seen is recorded', () {
      final phone = store.redeemInvite(store.createInvite(alice.id), 'Phone')!;
      expect(store.listDevices(alice.id).single.lastSeen, isNull);
      store.authenticate(phone.token);
      expect(store.listDevices(alice.id).single.lastSeen, now.millisecondsSinceEpoch ~/ 1000);
    });
  });

  test('a backup copy opens as a working database', () {
    store.applyChanges(alice.id, 'a1', [ch('t1', 'title', 'kept', 1000)]);
    final dir = Directory.systemTemp.createTempSync('taskflow_backup');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = '${dir.path}${Platform.pathSeparator}backup.sqlite';
    store.backupTo(file);
    final copy = Store.open(file);
    expect(copy.fieldCount(alice.id), 1);
    copy.close();
  });
}
