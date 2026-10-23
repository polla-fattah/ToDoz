import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:taskflow_core/sharing.dart' show ShareInfo;
import 'package:taskflow_core/sync.dart';

import '../data/database.dart';
import 'sync_triggers.dart';

/// Carries one sync request to the server. The real one is HTTP
/// ([HttpSyncTransport]); tests call the server's code directly.
abstract class SyncTransport {
  Future<SyncResponse> sync(SyncRequest request);
}

class SyncTransportException implements Exception {
  SyncTransportException(this.message, {this.unauthorized = false});
  final String message;

  /// The server no longer accepts this device (revoked, or the account is gone).
  final bool unauthorized;

  @override
  String toString() => message;
}

class SyncReport {
  SyncReport({this.pushed = 0, this.pulled = 0, this.rounds = 0});
  int pushed;
  int pulled;
  int rounds;
}

/// Sends local edits to the server and applies other devices' edits
/// (SRS 4.11, 6.3). Stateless between runs: everything it needs lives in the
/// database, so a crash or a lost connection at any point is safe to retry.
class SyncEngine {
  SyncEngine(this.db, this.transport, {this.maxRounds = 50});

  final AppDatabase db;
  final SyncTransport transport;
  final int maxRounds;

  Future<bool> get enabled async => await db.metaGet('capture') == '1';

  Future<int> pending() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM outbox').getSingle()).read<int>('n');

  // ---------------------------------------------------------------------------
  // Turning sync on and off
  // ---------------------------------------------------------------------------

  /// Starts recording edits and queues everything already on the device, so
  /// the first sync uploads it (a device that has data before it is paired).
  Future<void> enable() async {
    await db.transaction(() async {
      await db.metaSet('capture', '0');
      await db.customStatement('DELETE FROM outbox');
      await db.customStatement('DELETE FROM field_clock');
      await db.metaSet('cursor', '0');
      for (final sql in seedOutboxStatements()) {
        await db.customStatement(sql);
      }
      await db.metaSet('capture', '1');
    });
  }

  /// Stops recording and forgets the sync state. Local data stays.
  Future<void> disable() async {
    await db.transaction(() async {
      await db.metaSet('capture', '0');
      await db.customStatement('DELETE FROM outbox');
      await db.customStatement('DELETE FROM field_clock');
      await db.metaSet('cursor', '0');
    });
  }

  /// Throws away this device's synced data and downloads it again (FR-S7).
  /// Edits not yet sent are lost, which is what the owner asked for.
  Future<SyncReport> resetFromServer() async {
    await db.transaction(() async {
      await db.metaSet('capture', '0');
      for (final table in syncSchema.keys.toList().reversed) {
        await db.customStatement('DELETE FROM $table');
      }
      await db.customStatement('DELETE FROM outbox');
      await db.customStatement('DELETE FROM field_clock');
      await db.metaSet('cursor', '0');
      await db.metaSet('capture', '1');
    });
    await db.ensureInbox();
    // The empty Inbox just created must not overwrite the real one.
    await db.customStatement('DELETE FROM outbox');
    final report = await run();
    return report;
  }

  // ---------------------------------------------------------------------------
  // One sync
  // ---------------------------------------------------------------------------

  /// Sends the queue, pulls what is new, and repeats until both are empty.
  Future<SyncReport> run() async {
    if (!await enabled) throw StateError('Sync is not turned on for this device');
    final report = SyncReport();
    while (report.rounds < maxRounds) {
      report.rounds++;
      final rows = await db
          .customSelect('SELECT seq, tbl, row_id, col, value, hlc FROM outbox ORDER BY seq LIMIT 500')
          .get();
      final queued = [
        for (final r in rows)
          SyncChange(
            table: r.read<String>('tbl'),
            row: r.read<String>('row_id'),
            col: r.read<String>('col'),
            value: jsonDecode(r.read<String>('value')),
            hlc: r.read<String>('hlc'),
          ),
      ];
      final changes = collapseChanges(queued);
      final cursor = int.tryParse(await db.metaGet('cursor')) ?? 0;

      final response = await transport.sync(SyncRequest(cursor: cursor, changes: changes));

      await db.transaction(() async {
        for (final c in changes) {
          await _recordClock(c.table, c.row, c.col, c.hlc);
        }
        if (rows.isNotEmpty) {
          await db.customStatement('DELETE FROM outbox WHERE seq <= ?', [rows.last.read<int>('seq')]);
        }
        await _applyRemote(response.changes);
        final shares = response.shares;
        if (shares != null) {
          await db.saveShares([for (final s in shares) ?ShareInfo.fromJson(s)]);
        }
        await db.metaSet('cursor', '${response.cursor}');
      });
      if (response.changes.isNotEmpty) {
        db.markTablesUpdated(db.allTables);
      }

      report.pushed += changes.length;
      report.pulled += response.changes.length;
      if (!response.more && await pending() == 0) break;
      if (!response.more && rows.isEmpty) break;
    }
    return report;
  }

  // ---------------------------------------------------------------------------
  // Applying changes from the server
  // ---------------------------------------------------------------------------

  Future<void> _recordClock(String table, String row, String col, String hlc) => db.customStatement(
        'INSERT INTO field_clock(tbl, row_id, col, hlc) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(tbl, row_id, col) DO UPDATE SET hlc = excluded.hlc WHERE excluded.hlc > field_clock.hlc',
        [table, row, col, hlc],
      );

  /// The newest clock known for a field, counting edits still waiting to be sent.
  Future<String?> _localHlc(String table, String row, String col) async {
    final r = await db
        .customSelect(
          'SELECT MAX(h) AS h FROM (SELECT hlc AS h FROM field_clock WHERE tbl = ? AND row_id = ? AND col = ? '
          'UNION ALL SELECT hlc FROM outbox WHERE tbl = ? AND row_id = ? AND col = ?)',
          variables: [for (var i = 0; i < 2; i++) ...[Variable<String>(table), Variable<String>(row), Variable<String>(col)]],
        )
        .getSingle();
    return r.readNullable<String>('h');
  }

  final _placeholders = <String, ({List<String> cols, List<Object?> values})>{};

  Future<({List<String> cols, List<Object?> values})> _placeholder(String table) async {
    final cached = _placeholders[table];
    if (cached != null) return cached;
    final info = await db.customSelect('PRAGMA table_info($table)').get();
    final cols = <String>[];
    final values = <Object?>[];
    for (final r in info) {
      final name = r.read<String>('name');
      final notNull = r.read<int>('notnull') == 1;
      final hasDefault = r.readNullable<String>('dflt_value') != null;
      final isPk = r.read<int>('pk') > 0;
      if (notNull && !hasDefault && !isPk) {
        cols.add(name);
        values.add(r.read<String>('type').toUpperCase().contains('TEXT') ? '' : 0);
      }
    }
    return _placeholders[table] = (cols: cols, values: values);
  }

  /// The WHERE clause and its values for a row id.
  (String, List<Object?>) _where(String table, String row) {
    if (table == 'task_labels') {
      final i = row.indexOf('|');
      return ('task_id = ? AND label_id = ?', [row.substring(0, i), row.substring(i + 1)]);
    }
    return ('id = ?', [row]);
  }

  Future<bool> _exists(String table, String row) async {
    final (where, args) = _where(table, row);
    final r = await db.customSelect('SELECT 1 AS x FROM $table WHERE $where', variables: [for (final a in args) Variable<String>(a! as String)]).get();
    return r.isNotEmpty;
  }

  Future<void> _ensureRow(String table, String row) async {
    if (await _exists(table, row)) return;
    if (table == 'task_labels') {
      final (_, args) = _where(table, row);
      await db.customStatement('INSERT OR IGNORE INTO task_labels(task_id, label_id) VALUES (?, ?)', args);
      return;
    }
    final p = await _placeholder(table);
    final cols = ['id', ...p.cols];
    await db.customStatement(
      'INSERT OR IGNORE INTO $table(${cols.join(', ')}) VALUES (${List.filled(cols.length, '?').join(', ')})',
      [row, ...p.values],
    );
  }

  Future<void> _applyRemote(List<SyncChange> changes) async {
    if (changes.isEmpty) return;
    // These writes must not be queued as if the owner had made them.
    await db.metaSet('capture', '0');
    await db.metaSet('log', '0'); // the other device logged these actions already
    var maxWall = int.tryParse(await db.metaGet('hlc_floor')) ?? 0;
    try {
      for (final c in changes) {
        final w = hlcWall(c.hlc) + 1;
        if (w > maxWall) maxWall = w;
        final local = await _localHlc(c.table, c.row, c.col);
        if (!incomingWins(local, c.hlc)) continue;
        await _applyOne(c);
        await _recordClock(c.table, c.row, c.col, c.hlc);
      }
      // A task that was taken away (someone left a shared project, or removed me) leaves
      // my own labels and reminders on it behind: clear them.
      if (changes.any((c) => c.table == 'tasks' && c.col == presentColumn && c.value == false)) {
        await db.customStatement('DELETE FROM task_labels WHERE task_id NOT IN (SELECT id FROM tasks)');
        await db.customStatement('DELETE FROM reminders WHERE task_id NOT IN (SELECT id FROM tasks)');
        await db.customStatement('DELETE FROM location_reminders WHERE task_id NOT IN (SELECT id FROM tasks)');
      }
    } finally {
      await db.metaSet('capture', '1');
      await db.metaSet('log', '1');
    }
    // New local edits must sort after everything received (hybrid logical clock).
    await db.metaSet('hlc_floor', '$maxWall');
  }

  Future<void> _applyOne(SyncChange c) async {
    final (where, args) = _where(c.table, c.row);
    if (c.col == presentColumn) {
      if (c.value == false) {
        await db.customStatement('DELETE FROM ${c.table} WHERE $where', args);
        // Forget the clocks of the row's other fields: if the row ever comes back (someone leaves a
        // shared project and is invited again), its fields must be accepted afresh.
        await db.customStatement("DELETE FROM field_clock WHERE tbl = ? AND row_id = ? AND col <> '$presentColumn'", [c.table, c.row]);
      } else {
        await _ensureRow(c.table, c.row);
      }
      return;
    }
    if (!await _exists(c.table, c.row)) {
      // A row that is gone was deleted after this change was made: keep it deleted.
      final present = await _localHlc(c.table, c.row, presentColumn);
      if (present != null && present.compareTo(c.hlc) > 0) return;
      await _ensureRow(c.table, c.row);
    }
    await db.customStatement('UPDATE ${c.table} SET ${c.col} = ? WHERE $where', [_bind(c.value), ...args]);
  }

  Object? _bind(Object? v) => v is bool ? (v ? 1 : 0) : v;
}
