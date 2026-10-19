/// SQL that records every local edit as field changes (SRS 6.3), so the sync
/// engine knows what to send without any changes to the code that edits data.
///
/// For each synced table there are triggers on insert, on update of each
/// shared column, and on delete. Each writes one row per changed field to the
/// `outbox` table, stamped with a hybrid logical clock value made in SQL:
/// `13-digit ms`-`10-digit outbox sequence`-`device id`, where the milliseconds are the later of "now" and `hlc_floor` (set above
/// any clock received from another device). The triggers do nothing unless
/// `sync_meta.capture` is `1`, so applying changes that arrive from the
/// server, and local housekeeping, can switch capture off.
library;

import 'package:taskflow_core/sync.dart';

/// Columns a table's primary key is made of, and the SQL that builds the
/// sync row id from `NEW` or `OLD`.
String _rowId(String table, String ref) => table == 'task_labels' ? "$ref.task_id || '|' || $ref.label_id" : '$ref.id';

const _nowMs = "(CAST(strftime('%s', 'now') AS INTEGER) * 1000 + CAST(substr(strftime('%f', 'now'), 4) AS INTEGER))";

const _stampOutbox = '''
UPDATE outbox SET hlc = printf('%013d-%010d-%s',
  max($_nowMs, (SELECT CAST(value AS INTEGER) FROM sync_meta WHERE key = 'hlc_floor')),
  seq,
  (SELECT value FROM sync_meta WHERE key = 'device'))
WHERE hlc = ''
''';

const _captureOn = "(SELECT value FROM sync_meta WHERE key = 'capture') = '1'";

String _insertChange(String table, String rowExpr, String col, String valueExpr) =>
    "INSERT INTO outbox(tbl, row_id, col, value) VALUES ('$table', $rowExpr, '$col', $valueExpr);";

/// The CREATE TRIGGER statements for every synced table.
List<String> syncTriggerStatements() {
  final out = <String>[];
  syncSchema.forEach((table, columns) {
    out.add('''
CREATE TRIGGER sync_${table}_ins AFTER INSERT ON $table WHEN $_captureOn
BEGIN
  ${_insertChange(table, _rowId(table, 'NEW'), presentColumn, "'true'")}
  ${[for (final c in columns) _insertChange(table, _rowId(table, 'NEW'), c, 'json_quote(NEW.$c)')].join('\n  ')}
  $_stampOutbox;
END''');
    for (final c in columns) {
      out.add('''
CREATE TRIGGER sync_${table}_upd_$c AFTER UPDATE OF $c ON $table WHEN $_captureOn AND NEW.$c IS NOT OLD.$c
BEGIN
  ${_insertChange(table, _rowId(table, 'NEW'), c, 'json_quote(NEW.$c)')}
  $_stampOutbox;
END''');
    }
    out.add('''
CREATE TRIGGER sync_${table}_del AFTER DELETE ON $table WHEN $_captureOn
BEGIN
  ${_insertChange(table, _rowId(table, 'OLD'), presentColumn, "'false'")}
  $_stampOutbox;
END''');
  });
  return out;
}

/// DROP statements matching [syncTriggerStatements], used before re-creating them.
List<String> syncTriggerNames() {
  final out = <String>[];
  syncSchema.forEach((table, columns) {
    out.add('sync_${table}_ins');
    for (final c in columns) {
      out.add('sync_${table}_upd_$c');
    }
    out.add('sync_${table}_del');
  });
  return out;
}

/// SQL that copies every existing row into the outbox, for the first sync
/// of a device that already holds data.
List<String> seedOutboxStatements() {
  final out = <String>[];
  syncSchema.forEach((table, columns) {
    final rowExpr = table == 'task_labels' ? "task_id || '|' || label_id" : 'id';
    out.add("INSERT INTO outbox(tbl, row_id, col, value) SELECT '$table', $rowExpr, '$presentColumn', 'true' FROM $table");
    for (final c in columns) {
      out.add("INSERT INTO outbox(tbl, row_id, col, value) SELECT '$table', $rowExpr, '$c', json_quote($c) FROM $table");
    }
  });
  out.add(_stampOutbox);
  return out;
}
