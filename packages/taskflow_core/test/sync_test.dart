import 'package:taskflow_core/sync.dart';
import 'package:test/test.dart';

SyncChange change({String table = 'tasks', String row = 'r1', String col = 'title', Object? value = 'x', String? hlc}) =>
    SyncChange(table: table, row: row, col: col, value: value, hlc: hlc ?? formatHlc(1000, 0, 'dev1'));

void main() {
  group('clock values', () {
    test('sort as text in time order, then counter, then node', () {
      final a = formatHlc(999, 5, 'b');
      final b = formatHlc(1000, 0, 'a');
      final c = formatHlc(1000, 1, 'a');
      final d = formatHlc(1000, 1, 'b');
      final sorted = [d, b, c, a]..sort();
      expect(sorted, [a, b, c, d]);
    });

    test('are recognised and rejected when malformed', () {
      expect(isValidHlc(formatHlc(1, 2, 'dev-1_x')), isTrue);
      expect(isValidHlc('1-2-x'), isFalse);
      expect(isValidHlc('${formatHlc(1, 2, 'x')}\n'), isFalse);
      expect(isValidHlc(formatHlc(1, 2, 'a b')), isFalse);
      expect(isValidHlc(''), isFalse);
    });

    test('hlcWall and hlcCounter read the parts', () {
      expect(hlcWall(formatHlc(1792359900000, 3, 'x')), 1792359900000);
      expect(hlcCounter(formatHlc(1792359900000, 3, 'x')), 3);
    });
  });

  group('HlcClock', () {
    test('issues strictly increasing values even when the wall clock stalls or goes back', () {
      var wall = 1000;
      final clock = HlcClock('dev', wallMs: () => wall);
      final a = clock.next();
      final b = clock.next(); // same millisecond
      wall = 900; // the phone clock jumps back
      final c = clock.next();
      expect([a, b, c], orderedEquals([...[a, b, c]]..sort()));
      expect({a, b, c}, hasLength(3));
      wall = 2000;
      expect(clock.next().compareTo(c), greaterThan(0));
    });

    test('after receiving a later remote clock, new values sort after it', () {
      final clock = HlcClock('dev', wallMs: () => 1000); // this device is far behind
      final remote = formatHlc(5000, 7, 'other');
      clock.receive(remote);
      expect(clock.next().compareTo(remote), greaterThan(0));
    });

    test('a remote clock in the same millisecond with a higher counter is also passed', () {
      final clock = HlcClock('dev', wallMs: () => 5000);
      clock.next();
      final remote = formatHlc(5000, 9, 'other');
      clock.receive(remote);
      expect(clock.next().compareTo(remote), greaterThan(0));
    });

    test('an older remote clock does not move it backwards', () {
      final clock = HlcClock('dev', wallMs: () => 5000);
      final first = clock.next();
      clock.receive(formatHlc(100, 0, 'other'));
      expect(clock.next().compareTo(first), greaterThan(0));
    });

    test('can resume from stored state', () {
      final clock = HlcClock('dev', wallMs: () => 1000, lastWall: 1000, lastCounter: 4);
      expect(hlcWall(clock.next()), 1000);
      expect(clock.next().substring(14, 24), '0000000006');
    });
  });

  group('who wins', () {
    test('the larger clock wins; a missing value always loses', () {
      final old = formatHlc(1000, 0, 'a');
      final newer = formatHlc(2000, 0, 'b');
      expect(incomingWins(null, old), isTrue);
      expect(incomingWins(old, newer), isTrue);
      expect(incomingWins(newer, old), isFalse);
    });
    test('the same change twice changes nothing', () {
      final h = formatHlc(1000, 0, 'a');
      expect(incomingWins(h, h), isFalse);
    });
    test('equal times on two devices are still ordered, the same way on both', () {
      final a = formatHlc(1000, 0, 'phone');
      final b = formatHlc(1000, 0, 'tablet');
      expect(incomingWins(a, b), isNot(incomingWins(b, a)));
    });
  });

  group('validating changes from outside (SEC-9)', () {
    Map<String, Object?> good() => change().toJson();

    test('a good change round trips', () {
      final c = change(value: 'Buy milk');
      expect(SyncChange.fromJson(c.toJson()), c);
    });

    test('values may be null, bool, number or string only', () {
      for (final v in [null, true, 3, 2.5, 'text']) {
        expect(() => SyncChange.fromJson({...good(), 'v': v}), returnsNormally, reason: '$v');
      }
      for (final v in [<Object?>[], <String, Object?>{}, DateTime(2026)]) {
        expect(() => SyncChange.fromJson({...good(), 'v': v}), throwsA(isA<SyncFormatException>()), reason: '$v');
      }
    });

    test('unknown tables and columns are refused', () {
      expect(() => SyncChange.fromJson({...good(), 't': 'users'}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncChange.fromJson({...good(), 't': 'settings'}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncChange.fromJson({...good(), 'c': 'password'}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncChange.fromJson({...good(), 'c': 'snoozed_until'}), throwsA(isA<SyncFormatException>())); // device-local
      expect(() => SyncChange.fromJson({...good(), 'c': "title'; DROP TABLE tasks;--"}), throwsA(isA<SyncFormatException>()));
    });

    test('row ids and clocks are checked', () {
      expect(() => SyncChange.fromJson({...good(), 'r': ''}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncChange.fromJson({...good(), 'r': 'x' * 201}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncChange.fromJson({...good(), 'r': 'a\nb'}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncChange.fromJson({...good(), 'h': 'now'}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncChange.fromJson({...good(), 'h': 5}), throwsA(isA<SyncFormatException>()));
    });

    test('_present must be a boolean and is allowed on every table', () {
      for (final t in syncSchema.keys) {
        expect(() => SyncChange.fromJson({...good(), 't': t, 'c': presentColumn, 'v': true}), returnsNormally, reason: t);
      }
      expect(() => SyncChange.fromJson({...good(), 'c': presentColumn, 'v': 'yes'}), throwsA(isA<SyncFormatException>()));
    });

    test('oversized values are refused', () {
      expect(() => SyncChange.fromJson({...good(), 'v': 'x' * (maxValueBytes)}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncChange.fromJson({...good(), 'v': 'x' * 1000}), returnsNormally);
    });

    test('not an object', () {
      expect(() => SyncChange.fromJson('x'), throwsA(isA<SyncFormatException>()));
      expect(() => SyncChange.fromJson(null), throwsA(isA<SyncFormatException>()));
    });

    test('the schema never exposes device-local columns', () {
      expect(syncSchema['tasks'], isNot(contains('snoozed_until')));
      expect(syncSchema.containsKey('settings'), isFalse);
    });
  });

  group('requests and responses', () {
    test('a request round trips and rejects bad cursors, limits and sizes', () {
      final r = SyncRequest(cursor: 7, limit: 100, changes: [change(), change(col: 'description', value: 'd')]);
      final back = SyncRequest.fromJson(r.toJson());
      expect((back.cursor, back.limit, back.changes.length), (7, 100, 2));
      expect(() => SyncRequest.fromJson({'cursor': -1, 'changes': []}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncRequest.fromJson({'cursor': 'a', 'changes': []}), throwsA(isA<SyncFormatException>()));
      expect(() => SyncRequest.fromJson({'cursor': 0, 'limit': 5000, 'changes': []}), throwsA(isA<SyncFormatException>()));
      final tooMany = [for (var i = 0; i < maxChangesPerRequest + 1; i++) change(row: 'r$i').toJson()];
      expect(() => SyncRequest.fromJson({'cursor': 0, 'changes': tooMany}), throwsA(isA<SyncFormatException>()));
      expect(SyncRequest.fromJson({'cursor': 0}).changes, isEmpty);
    });

    test('a response round trips', () {
      final r = SyncResponse(cursor: 9, more: true, changes: [change()]);
      final back = SyncResponse.fromJson(r.toJson());
      expect((back.cursor, back.more, back.changes.single), (9, true, change()));
    });
  });

  group('collapseChanges', () {
    test('keeps the newest change per field and sorts by clock', () {
      final out = collapseChanges([
        change(value: 'one', hlc: formatHlc(1000, 0, 'd')),
        change(value: 'three', hlc: formatHlc(3000, 0, 'd')),
        change(value: 'two', hlc: formatHlc(2000, 0, 'd')),
        change(col: 'description', value: 'desc', hlc: formatHlc(1500, 0, 'd')),
        change(row: 'r2', value: 'other row', hlc: formatHlc(500, 0, 'd')),
      ]);
      expect(out.map((c) => '${c.row}.${c.col}=${c.value}'), ['r2.title=other row', 'r1.description=desc', 'r1.title=three']);
    });
    test('does not confuse fields whose names run together', () {
      final out = collapseChanges([
        change(row: 'a', col: 'title', hlc: formatHlc(1, 0, 'd')),
        change(row: 'a', col: 'description', hlc: formatHlc(2, 0, 'd')),
      ]);
      expect(out, hasLength(2));
    });
  });

  group('pairing codes', () {
    test('accept the typed forms people use', () {
      expect(isValidPairingCode('ABCD-2345'), isTrue);
      expect(isValidPairingCode('abcd 2345'), isTrue);
      expect(normalisePairingCode('abcd-2345'), 'ABCD2345');
    });
    test('reject look-alike characters and wrong lengths', () {
      expect(isValidPairingCode('ABCD-2340'), isFalse); // 0
      expect(isValidPairingCode('ABCD-2O45'), isFalse); // O
      expect(isValidPairingCode('ABCD-234'), isFalse);
      expect(isValidPairingCode(''), isFalse);
    });
    test('format groups of four', () => expect(formatPairingCode('ABCD2345'), 'ABCD-2345'));
  });
}
