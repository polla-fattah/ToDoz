/// The server's database: accounts, devices, pairing codes, and every
/// person's synced fields. Every read and write is scoped by user id, which
/// comes from the authenticated device and never from the request (SEC-5).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:taskflow_core/sync.dart';

import 'shares.dart';

const pairingCodeTtl = Duration(minutes: 10);

class Account {
  Account(this.id, this.name);
  final String id;
  final String name;
}

class DeviceInfo {
  DeviceInfo({required this.id, required this.userId, required this.name, required this.createdAt, this.lastSeen, this.revokedAt});
  final String id;
  final String userId;
  final String name;
  final int createdAt;
  final int? lastSeen;
  final int? revokedAt;
  bool get revoked => revokedAt != null;
}

class PairResult {
  PairResult({required this.token, required this.deviceId, required this.userId, required this.userName});

  /// The only time the token exists in clear: the server keeps just its hash (SEC-3).
  final String token;
  final String deviceId;
  final String userId;
  final String userName;
}

class GoogleAccount {
  GoogleAccount({
    required this.userId,
    required this.refreshToken,
    required this.calendarId,
    required this.timeZone,
    required this.connectedAt,
    this.lastSync,
    this.lastError,
    this.needsReconnect = false,
  });
  final String userId;
  final String refreshToken;
  final String? calendarId;
  final String timeZone;
  final int connectedAt;
  final int? lastSync;
  final String? lastError;
  final bool needsReconnect;
}

/// Which Google event shows a task, and what it looked like when we last wrote or read it.
class GoogleEventLink {
  GoogleEventLink({required this.taskId, required this.eventId, required this.specHash, required this.spec, this.state = 'linked'});
  final String taskId;
  final String eventId;
  final String specHash;
  final Map<String, Object?> spec;

  /// `linked`, or `orphaned` when the person deleted the event in Google.
  final String state;

  GoogleEventLink copyWith({String? eventId, String? specHash, Map<String, Object?>? spec, String? state}) =>
      GoogleEventLink(taskId: taskId, eventId: eventId ?? this.eventId, specHash: specHash ?? this.specHash, spec: spec ?? this.spec, state: state ?? this.state);
}

/// One field to write: a value for [col] of row [row] in [table].
class FieldEdit {
  const FieldEdit(this.table, this.row, this.col, this.value);
  final String table;
  final String row;
  final String col;
  final Object? value;
}

class SyncPage {
  SyncPage({required this.changes, required this.cursor, required this.more});
  final List<SyncChange> changes;
  final int cursor;
  final bool more;
}

class Store {
  Store._(this.db, this._now, this._random);

  final Database db;

  /// Told after changes are written (by any route: sync, the API, a webhook), so webhooks can fire.
  /// A failure here never affects the write.
  void Function(String userId, List<SyncChange> applied)? onApplied;
  final DateTime Function() _now;
  final Random _random;

  /// Opens (and creates) the database at [path]; `:memory:` for tests.
  static Store open(String path, {DateTime Function()? clock, Random? random}) {
    final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);
    final store = Store._(db, clock ?? DateTime.now, random ?? Random.secure());
    store._migrate();
    return store;
  }

  void close() => db.close();

  int get _nowSec => _now().millisecondsSinceEpoch ~/ 1000;

  /// The server's clock (injected in tests).
  DateTime get now => _now();

  void _migrate() {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 5000');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version < 1) {
      db.execute('''
        CREATE TABLE users (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE COLLATE NOCASE,
          created_at INTEGER NOT NULL,
          seq INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE devices (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          created_at INTEGER NOT NULL,
          last_seen INTEGER,
          revoked_at INTEGER
        );
        CREATE INDEX devices_user ON devices(user_id);
        CREATE TABLE invites (
          code_hash TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL,
          used_at INTEGER
        );
        CREATE TABLE fields (
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          tbl TEXT NOT NULL,
          row_id TEXT NOT NULL,
          col TEXT NOT NULL,
          value TEXT NOT NULL,
          hlc TEXT NOT NULL,
          device_id TEXT NOT NULL,
          seq INTEGER NOT NULL,
          PRIMARY KEY (user_id, tbl, row_id, col)
        ) WITHOUT ROWID;
        CREATE INDEX fields_seq ON fields(user_id, seq);
        PRAGMA user_version = 1;
      ''');
    }
    if (version < 2) {
      // R5: tokens for the owner's own scripts, outgoing and incoming webhooks, the calendar feed.
      db.execute('''
        CREATE TABLE api_tokens (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          read_only INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          last_used INTEGER,
          revoked_at INTEGER
        );
        CREATE INDEX api_tokens_user ON api_tokens(user_id);
        CREATE TABLE webhooks (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          url TEXT NOT NULL,
          secret TEXT NOT NULL,
          events TEXT NOT NULL DEFAULT '*',
          active INTEGER NOT NULL DEFAULT 1,
          failures INTEGER NOT NULL DEFAULT 0,
          last_status TEXT,
          created_at INTEGER NOT NULL
        );
        CREATE INDEX webhooks_user ON webhooks(user_id);
        CREATE TABLE inbound_hooks (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          secret TEXT NOT NULL,
          project_id TEXT NOT NULL DEFAULT 'inbox',
          created_at INTEGER NOT NULL,
          last_used INTEGER
        );
        CREATE INDEX inbound_hooks_user ON inbound_hooks(user_id);
        CREATE TABLE calendar_feeds (
          user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
          token_hash TEXT NOT NULL UNIQUE,
          created_at INTEGER NOT NULL
        );
        PRAGMA user_version = 2;
      ''');
    }
    if (version < 3) {
      // R5: the Google Calendar connection and which task each event belongs to.
      db.execute('''
        CREATE TABLE google_accounts (
          user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
          refresh_token TEXT NOT NULL,
          calendar_id TEXT,
          time_zone TEXT NOT NULL DEFAULT 'UTC',
          connected_at INTEGER NOT NULL,
          last_sync INTEGER,
          last_error TEXT,
          needs_reconnect INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE google_events (
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          task_id TEXT NOT NULL,
          event_id TEXT NOT NULL,
          spec_hash TEXT NOT NULL,
          spec TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'linked',
          PRIMARY KEY (user_id, task_id)
        ) WITHOUT ROWID;
        CREATE TABLE google_states (
          state_hash TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          time_zone TEXT NOT NULL,
          expires_at INTEGER NOT NULL,
          used_at INTEGER
        );
        PRAGMA user_version = 3;
      ''');
    }
    if (version < 4) {
      // R6: shared projects, their members, and invitations.
      db.execute('''
        CREATE TABLE shares (
          project_id TEXT NOT NULL,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
          owner_id TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          PRIMARY KEY (project_id, user_id)
        ) WITHOUT ROWID;
        CREATE INDEX shares_user ON shares(user_id);
        CREATE TABLE share_invites (
          code_hash TEXT PRIMARY KEY,
          project_id TEXT NOT NULL,
          owner_id TEXT NOT NULL,
          role TEXT NOT NULL,
          created_by TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL,
          used_at INTEGER,
          used_by TEXT
        );
        CREATE INDEX share_invites_project ON share_invites(project_id);
        PRAGMA user_version = 4;
      ''');
    }
  }

  /// Runs [body] as one all-or-nothing step. Steps can be nested.
  T transaction<T>(T Function() body) {
    final name = 'tx${_txDepth++}';
    db.execute('SAVEPOINT $name');
    try {
      final r = body();
      db.execute('RELEASE $name');
      return r;
    } catch (_) {
      db.execute('ROLLBACK TO $name');
      db.execute('RELEASE $name');
      rethrow;
    } finally {
      _txDepth--;
    }
  }

  var _txDepth = 0;

  /// Shared projects: who is in them, and routing changes between members.
  late final Shares shares = Shares(this);


  // ---------------------------------------------------------------------------
  // Tokens and codes
  // ---------------------------------------------------------------------------

  static String hash(String secret) => sha256.convert(utf8.encode(secret)).toString();

  String _randomId() => _randomBytes(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List _randomBytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) _random.nextInt(256)]);

  String _newToken() => base64Url.encode(_randomBytes(32)).replaceAll('=', '');

  String newPairingCode() => _newCode();

  String _newCode() => List.generate(8, (_) => pairingAlphabet[_random.nextInt(pairingAlphabet.length)]).join();

  // ---------------------------------------------------------------------------
  // Accounts (made by the owner, on the server's command line: SEC-1)
  // ---------------------------------------------------------------------------

  Account createUser(String name) {
    final n = name.trim();
    if (!RegExp(r'^[\p{L}\p{N} ._-]{1,40}$', unicode: true).hasMatch(n)) {
      throw ArgumentError('A name is 1 to 40 letters, digits, spaces, dots, dashes or underscores');
    }
    final id = _randomId();
    try {
      db.execute('INSERT INTO users(id, name, created_at) VALUES (?, ?, ?)', [id, n, _nowSec]);
    } on SqliteException {
      throw ArgumentError('There is already a user called "$n"');
    }
    return Account(id, n);
  }

  Account? findUser(String name) {
    final r = db.select('SELECT id, name FROM users WHERE name = ?', [name.trim()]);
    return r.isEmpty ? null : Account(r.first['id'] as String, r.first['name'] as String);
  }

  List<Account> listUsers() =>
      [for (final r in db.select('SELECT id, name FROM users ORDER BY name')) Account(r['id'] as String, r['name'] as String)];

  /// Removes the person, their devices, codes and every stored field (SEC-17).
  void deleteUser(String userId) {
    shares.handOver(userId); // projects others share pass to someone else; the rest end
    db.execute('DELETE FROM users WHERE id = ?', [userId]);
  }

  /// Erases a person's synced data but keeps the account and devices.
  void wipeData(String userId) {
    db.execute('DELETE FROM fields WHERE user_id = ?', [userId]);
    db.execute('UPDATE users SET seq = 0 WHERE id = ?', [userId]);
  }

  /// Makes a one-time pairing code for [userId]. Only its hash is stored.
  String createInvite(String userId, {Duration ttl = pairingCodeTtl}) {
    final code = _newCode();
    db.execute(
      'INSERT INTO invites(code_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
      [hash(code), userId, _nowSec, _nowSec + ttl.inSeconds],
    );
    return code;
  }

  /// Swaps a valid, unused, unexpired code for a device token (SEC-2). The
  /// code is spent in the same transaction, so it works once.
  PairResult? redeemInvite(String code, String deviceName) {
    final normalised = normalisePairingCode(code);
    if (!isValidPairingCode(normalised)) return null;
    final name = deviceName.trim().isEmpty ? 'Device' : deviceName.trim();
    if (name.length > 60) return null;
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT i.user_id, u.name FROM invites i JOIN users u ON u.id = i.user_id '
        'WHERE i.code_hash = ? AND i.used_at IS NULL AND i.expires_at > ?',
        [hash(normalised), _nowSec],
      );
      if (rows.isEmpty) {
        db.execute('ROLLBACK');
        return null;
      }
      final userId = rows.first['user_id'] as String;
      final userName = rows.first['name'] as String;
      db.execute('UPDATE invites SET used_at = ? WHERE code_hash = ?', [_nowSec, hash(normalised)]);
      final deviceId = _randomId();
      final token = _newToken();
      db.execute(
        'INSERT INTO devices(id, user_id, name, token_hash, created_at) VALUES (?, ?, ?, ?, ?)',
        [deviceId, userId, name, hash(token), _nowSec],
      );
      db.execute('COMMIT');
      return PairResult(token: token, deviceId: deviceId, userId: userId, userName: userName);
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// The device a token belongs to, or null if it is unknown or revoked.
  DeviceInfo? authenticate(String token) {
    if (token.isEmpty || token.length > 200) return null;
    final r = db.select(
      'SELECT id, user_id, name, created_at, last_seen, revoked_at FROM devices WHERE token_hash = ?',
      [hash(token)],
    );
    if (r.isEmpty || r.first['revoked_at'] != null) return null;
    final row = r.first;
    final last = row['last_seen'] as int?;
    if (last == null || _nowSec - last > 60) {
      db.execute('UPDATE devices SET last_seen = ? WHERE id = ?', [_nowSec, row['id']]);
    }
    return _device(row);
  }

  DeviceInfo _device(Row r) => DeviceInfo(
        id: r['id'] as String,
        userId: r['user_id'] as String,
        name: r['name'] as String,
        createdAt: r['created_at'] as int,
        lastSeen: r['last_seen'] as int?,
        revokedAt: r['revoked_at'] as int?,
      );

  List<DeviceInfo> listDevices(String userId) => [
        for (final r in db.select(
          'SELECT id, user_id, name, created_at, last_seen, revoked_at FROM devices WHERE user_id = ? ORDER BY created_at',
          [userId],
        ))
          _device(r),
      ];

  /// Revokes one of [userId]'s devices. Returns false if it is not theirs.
  bool revokeDevice(String userId, String deviceId) {
    db.execute('UPDATE devices SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL', [_nowSec, deviceId, userId]);
    return db.updatedRows > 0;
  }

  // ---------------------------------------------------------------------------
  // Sync
  // ---------------------------------------------------------------------------

  /// Merges [changes] from [deviceId] into [userId]'s data. A change wins only
  /// if its clock is larger than the stored one, so replays and old edits do
  /// nothing. Returns how many changes were new.
  int applyChanges(String userId, String deviceId, List<SyncChange> changes) => applyChangesDetailed(userId, deviceId, changes).length;

  /// Like [applyChanges], but returns the changes that were new (the rest lost to a newer value).
  List<SyncChange> applyChangesDetailed(String userId, String deviceId, List<SyncChange> changes) {
    if (changes.isEmpty) return const [];
    final touched = <String, List<SyncChange>>{};
    var mine = <SyncChange>[];
    transaction(() {
      final plan = shares.route(userId, changes);
      mine = applyRaw(userId, deviceId, plan.accepted);
      if (plan.corrections.isNotEmpty) {
        // Refused changes are undone in the person's own copy, so their phone does not keep them.
        applyRaw(userId, 'srv', plan.corrections);
      }
      final copies = {...plan.fanout};
      if (plan.moves.isNotEmpty) {
        shares.afterApply(userId, plan).forEach((other, list) => copies.putIfAbsent(other, () => []).addAll(list));
      }
      copies.forEach((other, list) {
        final a = applyRaw(other, 'fanout', list);
        if (a.isNotEmpty) touched[other] = a;
      });
      shares.finishPurges();
    });
    if (mine.isNotEmpty) touched[userId] = mine;
    touched.forEach(notifyApplied);
    return mine;
  }

  /// Writes [changes] into [userId]'s space (those whose clock beats what is stored there), with
  /// no sharing rules and no transaction of its own. Returns the changes that were new.
  List<SyncChange> applyRaw(String userId, String deviceId, List<SyncChange> changes) {
    final applied = <SyncChange>[];
    if (changes.isEmpty) return applied;
    final select = db.prepare('SELECT hlc FROM fields WHERE user_id = ? AND tbl = ? AND row_id = ? AND col = ?');
    final bump = db.prepare('UPDATE users SET seq = seq + 1 WHERE id = ? RETURNING seq');
    final upsert = db.prepare(
      'INSERT OR REPLACE INTO fields(user_id, tbl, row_id, col, value, hlc, device_id, seq) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    );
    try {
      for (final c in changes) {
        final cur = select.select([userId, c.table, c.row, c.col]);
        final curHlc = cur.isEmpty ? null : cur.first['hlc'] as String;
        if (!incomingWins(curHlc, c.hlc)) continue;
        final seq = bump.select([userId]).first['seq'] as int;
        upsert.execute([userId, c.table, c.row, c.col, jsonEncode(c.value), c.hlc, deviceId, seq]);
        applied.add(c);
      }
    } finally {
      select.close();
      bump.close();
      upsert.close();
    }
    return applied;
  }

  /// Tells the webhook and Google machinery that [applied] was written for [userId]. A failure here never affects the write.
  void notifyApplied(String userId, List<SyncChange> applied) {
    if (applied.isEmpty) return;
    try {
      onApplied?.call(userId, applied);
    } catch (_) {}
  }

  /// Writes edits made by the server itself on a person's behalf (the REST API,
  /// webhooks, the calendar link). Each gets a clock value just above the one
  /// stored for that field, so it wins over older edits from the person's devices
  /// and is itself overridden by any later edit they make. [source] names who
  /// made them, for the change log; it is never a real device, so every device
  /// of the person receives these edits. Returns how many were applied.
  int applyEdits(String userId, String source, List<FieldEdit> edits) => applyEditsDetailed(userId, source, edits).length;

  /// Like [applyEdits], returning the changes that were written.
  List<SyncChange> applyEditsDetailed(String userId, String source, List<FieldEdit> edits) {
    if (edits.isEmpty) return const [];
    final nowMs = _now().millisecondsSinceEpoch;
    final select = db.prepare('SELECT hlc FROM fields WHERE user_id = ? AND tbl = ? AND row_id = ? AND col = ?');
    final changes = <SyncChange>[];
    var counter = 0;
    try {
      for (final e in edits) {
        final cur = select.select([userId, e.table, e.row, e.col]);
        var wall = nowMs;
        var count = 0;
        if (cur.isNotEmpty) {
          final h = cur.first['hlc'] as String;
          final w = hlcWall(h);
          if (w >= wall) {
            wall = w;
            count = hlcCounter(h) + 1;
          }
        }
        counter++;
        changes.add(SyncChange(table: e.table, row: e.row, col: e.col, value: e.value, hlc: formatHlc(wall, count + (wall == nowMs ? counter : 0), 'srv')));
      }
    } finally {
      select.close();
    }
    return applyChangesDetailed(userId, source, changes);
  }

  /// Every field of [userId] except the activity log, as table -> row -> column -> value.
  /// Rows whose `_present` is false (deleted) are left out.
  Map<String, Map<String, Map<String, Object?>>> snapshot(String userId, {bool withActivity = false}) {
    final out = <String, Map<String, Map<String, Object?>>>{};
    final rows = db.select(
      withActivity
          ? 'SELECT tbl, row_id, col, value FROM fields WHERE user_id = ?'
          : "SELECT tbl, row_id, col, value FROM fields WHERE user_id = ? AND tbl <> 'activity'",
      [userId],
    );
    for (final r in rows) {
      out.putIfAbsent(r['tbl'] as String, () => {}).putIfAbsent(r['row_id'] as String, () => {})[r['col'] as String] = jsonDecode(r['value'] as String);
    }
    for (final t in out.values) {
      t.removeWhere((_, cols) => cols[presentColumn] == false);
    }
    return out;
  }

  /// The fields of [userId] changed after [cursor] by devices other than
  /// [deviceId], oldest first. [SyncPage.cursor] advances past the device's
  /// own changes too, so they are never scanned again.
  SyncPage changesSince(String userId, String deviceId, int cursor, {int limit = 500}) {
    final rows = db.select(
      'SELECT tbl, row_id, col, value, hlc, device_id, seq FROM fields WHERE user_id = ? AND seq > ? ORDER BY seq LIMIT ?',
      [userId, cursor, limit + 1],
    );
    final more = rows.length > limit;
    final page = more ? rows.take(limit).toList() : rows.toList();
    final out = <SyncChange>[];
    var next = cursor;
    for (final r in page) {
      next = r['seq'] as int;
      if (r['device_id'] == deviceId) continue;
      out.add(SyncChange(
        table: r['tbl'] as String,
        row: r['row_id'] as String,
        col: r['col'] as String,
        value: jsonDecode(r['value'] as String),
        hlc: r['hlc'] as String,
      ));
    }
    return SyncPage(changes: out, cursor: next, more: more);
  }

  /// Everything [userId] has stored, for their own export (SEC-17).
  List<SyncChange> exportAll(String userId) => [
        for (final r in db.select('SELECT tbl, row_id, col, value, hlc FROM fields WHERE user_id = ? ORDER BY seq', [userId]))
          SyncChange(
            table: r['tbl'] as String,
            row: r['row_id'] as String,
            col: r['col'] as String,
            value: jsonDecode(r['value'] as String),
            hlc: r['hlc'] as String,
          ),
      ];

  int fieldCount(String userId) => db.select('SELECT COUNT(*) AS n FROM fields WHERE user_id = ?', [userId]).first['n'] as int;

  // ---------------------------------------------------------------------------
  // Tokens for the owner's own scripts (REST API, FR-I4)
  // ---------------------------------------------------------------------------

  /// Makes an API token. It is returned once; only its hash is kept.
  ({String id, String token}) createApiToken(String userId, String name, {bool readOnly = false}) {
    final n = name.trim();
    if (n.isEmpty || n.length > 60) throw ArgumentError('A token name is 1 to 60 characters');
    final count = db.select('SELECT COUNT(*) AS n FROM api_tokens WHERE user_id = ? AND revoked_at IS NULL', [userId]).first['n'] as int;
    if (count >= 20) throw ArgumentError('Revoke an old token first: at most 20 are allowed');
    final id = _randomId();
    final token = 'tf_${_newToken()}';
    db.execute(
      'INSERT INTO api_tokens(id, user_id, name, token_hash, read_only, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      [id, userId, n, hash(token), readOnly ? 1 : 0, _nowSec],
    );
    return (id: id, token: token);
  }

  /// The person and rights an API token stands for, or null if unknown or revoked.
  ({String userId, String tokenId, bool readOnly})? authenticateApiToken(String token) {
    if (token.isEmpty || token.length > 200 || !token.startsWith('tf_')) return null;
    final r = db.select('SELECT id, user_id, read_only, last_used, revoked_at FROM api_tokens WHERE token_hash = ?', [hash(token)]);
    if (r.isEmpty || r.first['revoked_at'] != null) return null;
    final last = r.first['last_used'] as int?;
    if (last == null || _nowSec - last > 60) db.execute('UPDATE api_tokens SET last_used = ? WHERE id = ?', [_nowSec, r.first['id']]);
    return (userId: r.first['user_id'] as String, tokenId: r.first['id'] as String, readOnly: r.first['read_only'] == 1);
  }

  List<Map<String, Object?>> listApiTokens(String userId) => [
        for (final r in db.select('SELECT id, name, read_only, created_at, last_used, revoked_at FROM api_tokens WHERE user_id = ? ORDER BY created_at', [userId]))
          {
            'id': r['id'],
            'name': r['name'],
            'readOnly': r['read_only'] == 1,
            'createdAt': r['created_at'],
            'lastUsed': r['last_used'],
            'revoked': r['revoked_at'] != null,
          },
      ];

  bool revokeApiToken(String userId, String id) {
    db.execute('UPDATE api_tokens SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL', [_nowSec, id, userId]);
    return db.updatedRows > 0;
  }

  // ---------------------------------------------------------------------------
  // Webhooks (FR-I3, FR-I5)
  // ---------------------------------------------------------------------------

  /// A secret for signing webhook calls.
  String newSecret() => _newToken();

  ({String id, String secret}) createWebhook(String userId, String url, {String events = '*'}) {
    final count = db.select('SELECT COUNT(*) AS n FROM webhooks WHERE user_id = ?', [userId]).first['n'] as int;
    if (count >= 10) throw ArgumentError('At most 10 webhooks are allowed');
    final id = _randomId();
    final secret = newSecret();
    db.execute('INSERT INTO webhooks(id, user_id, url, secret, events, created_at) VALUES (?, ?, ?, ?, ?, ?)', [id, userId, url, secret, events, _nowSec]);
    return (id: id, secret: secret);
  }

  List<Map<String, Object?>> listWebhooks(String userId, {bool withSecrets = false}) => [
        for (final r in db.select('SELECT id, url, secret, events, active, failures, last_status, created_at FROM webhooks WHERE user_id = ? ORDER BY created_at', [userId]))
          {
            'id': r['id'],
            'url': r['url'],
            'events': r['events'],
            'active': r['active'] == 1,
            'failures': r['failures'],
            'lastStatus': r['last_status'],
            'createdAt': r['created_at'],
            if (withSecrets) 'secret': r['secret'],
          },
      ];

  bool deleteWebhook(String userId, String id) {
    db.execute('DELETE FROM webhooks WHERE id = ? AND user_id = ?', [id, userId]);
    return db.updatedRows > 0;
  }

  void recordWebhookResult(String id, {required bool ok, required String status}) {
    if (ok) {
      db.execute('UPDATE webhooks SET failures = 0, last_status = ? WHERE id = ?', [status, id]);
    } else {
      // Twenty failures in a row switch it off, so a dead address is not tried for ever.
      db.execute('UPDATE webhooks SET failures = failures + 1, last_status = ?, active = CASE WHEN failures + 1 >= 20 THEN 0 ELSE active END WHERE id = ?', [status, id]);
    }
  }

  bool reactivateWebhook(String userId, String id) {
    db.execute('UPDATE webhooks SET active = 1, failures = 0 WHERE id = ? AND user_id = ?', [id, userId]);
    return db.updatedRows > 0;
  }

  ({String id, String url, String secret, Set<String> events})? webhookRow(Row r) => (
        id: r['id'] as String,
        url: r['url'] as String,
        secret: r['secret'] as String,
        events: (r['events'] as String).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet(),
      );

  /// Active webhooks of [userId] that want [event] (`task.completed`, ...).
  List<({String id, String url, String secret, Set<String> events})> webhooksFor(String userId, String event) {
    final out = <({String id, String url, String secret, Set<String> events})>[];
    for (final r in db.select('SELECT id, url, secret, events FROM webhooks WHERE user_id = ? AND active = 1', [userId])) {
      final w = webhookRow(r)!;
      if (w.events.contains('*') || w.events.contains(event)) out.add(w);
    }
    return out;
  }

  ({String id, String secret}) createInboundHook(String userId, String name, {String projectId = 'inbox'}) {
    final n = name.trim();
    if (n.isEmpty || n.length > 60) throw ArgumentError('A name is 1 to 60 characters');
    final count = db.select('SELECT COUNT(*) AS n FROM inbound_hooks WHERE user_id = ?', [userId]).first['n'] as int;
    if (count >= 10) throw ArgumentError('At most 10 incoming webhooks are allowed');
    final id = _randomId();
    final secret = newSecret();
    db.execute('INSERT INTO inbound_hooks(id, user_id, name, secret, project_id, created_at) VALUES (?, ?, ?, ?, ?, ?)', [id, userId, n, secret, projectId, _nowSec]);
    return (id: id, secret: secret);
  }

  List<Map<String, Object?>> listInboundHooks(String userId) => [
        for (final r in db.select('SELECT id, name, project_id, created_at, last_used FROM inbound_hooks WHERE user_id = ? ORDER BY created_at', [userId]))
          {'id': r['id'], 'name': r['name'], 'projectId': r['project_id'], 'createdAt': r['created_at'], 'lastUsed': r['last_used']},
      ];

  bool deleteInboundHook(String userId, String id) {
    db.execute('DELETE FROM inbound_hooks WHERE id = ? AND user_id = ?', [id, userId]);
    return db.updatedRows > 0;
  }

  ({String userId, String secret, String projectId})? inboundHook(String id) {
    final r = db.select('SELECT user_id, secret, project_id FROM inbound_hooks WHERE id = ?', [id]);
    if (r.isEmpty) return null;
    db.execute('UPDATE inbound_hooks SET last_used = ? WHERE id = ?', [_nowSec, id]);
    return (userId: r.first['user_id'] as String, secret: r.first['secret'] as String, projectId: r.first['project_id'] as String);
  }

  // ---------------------------------------------------------------------------
  // Google Calendar connection
  // ---------------------------------------------------------------------------

  /// A one-time value that travels through Google's sign-in page and back, tying the answer to this person.
  String createGoogleState(String userId, String timeZone) {
    final token = _newToken();
    db.execute('DELETE FROM google_states WHERE expires_at < ?', [_nowSec]);
    db.execute('INSERT INTO google_states(state_hash, user_id, time_zone, expires_at) VALUES (?, ?, ?, ?)', [hash(token), userId, timeZone, _nowSec + 600]);
    return token;
  }

  ({String userId, String timeZone})? consumeGoogleState(String token) {
    if (token.isEmpty || token.length > 200) return null;
    final r = db.select('SELECT user_id, time_zone FROM google_states WHERE state_hash = ? AND used_at IS NULL AND expires_at > ?', [hash(token), _nowSec]);
    if (r.isEmpty) return null;
    db.execute('UPDATE google_states SET used_at = ? WHERE state_hash = ?', [_nowSec, hash(token)]);
    return (userId: r.first['user_id'] as String, timeZone: r.first['time_zone'] as String);
  }

  void saveGoogleAccount(String userId, String refreshToken, String timeZone) {
    db.execute('DELETE FROM google_events WHERE user_id = ?', [userId]);
    db.execute(
      'INSERT OR REPLACE INTO google_accounts(user_id, refresh_token, calendar_id, time_zone, connected_at) VALUES (?, ?, NULL, ?, ?)',
      [userId, refreshToken, timeZone, _nowSec],
    );
  }

  GoogleAccount? googleAccount(String userId) {
    final r = db.select('SELECT * FROM google_accounts WHERE user_id = ?', [userId]);
    if (r.isEmpty) return null;
    final x = r.first;
    return GoogleAccount(
      userId: userId,
      refreshToken: x['refresh_token'] as String,
      calendarId: x['calendar_id'] as String?,
      timeZone: x['time_zone'] as String,
      connectedAt: x['connected_at'] as int,
      lastSync: x['last_sync'] as int?,
      lastError: x['last_error'] as String?,
      needsReconnect: x['needs_reconnect'] == 1,
    );
  }

  List<String> googleUsers() => [for (final r in db.select('SELECT user_id FROM google_accounts WHERE needs_reconnect = 0')) r['user_id'] as String];

  void setGoogleCalendar(String userId, String calendarId) => db.execute('UPDATE google_accounts SET calendar_id = ? WHERE user_id = ?', [calendarId, userId]);

  void setGoogleTimeZone(String userId, String timeZone) => db.execute('UPDATE google_accounts SET time_zone = ? WHERE user_id = ?', [timeZone, userId]);

  void recordGoogleSync(String userId, {required DateTime startedAt, String? error, bool needsReconnect = false}) {
    db.execute(
      'UPDATE google_accounts SET last_sync = ?, last_error = ?, needs_reconnect = ? WHERE user_id = ?',
      [error == null ? startedAt.millisecondsSinceEpoch ~/ 1000 : (googleAccount(userId)?.lastSync), error, needsReconnect ? 1 : 0, userId],
    );
  }

  void deleteGoogleAccount(String userId) {
    db.execute('DELETE FROM google_events WHERE user_id = ?', [userId]);
    db.execute('DELETE FROM google_accounts WHERE user_id = ?', [userId]);
  }

  Map<String, GoogleEventLink> googleEvents(String userId) => {
        for (final r in db.select('SELECT task_id, event_id, spec_hash, spec, state FROM google_events WHERE user_id = ?', [userId]))
          r['task_id'] as String: GoogleEventLink(
            taskId: r['task_id'] as String,
            eventId: r['event_id'] as String,
            specHash: r['spec_hash'] as String,
            spec: (jsonDecode(r['spec'] as String) as Map).cast<String, Object?>(),
            state: r['state'] as String,
          ),
      };

  void saveGoogleEvent(String userId, GoogleEventLink link) => db.execute(
        'INSERT OR REPLACE INTO google_events(user_id, task_id, event_id, spec_hash, spec, state) VALUES (?, ?, ?, ?, ?, ?)',
        [userId, link.taskId, link.eventId, link.specHash, jsonEncode(link.spec), link.state],
      );

  void deleteGoogleEvent(String userId, String taskId) => db.execute('DELETE FROM google_events WHERE user_id = ? AND task_id = ?', [userId, taskId]);

  // ---------------------------------------------------------------------------
  // Calendar feed (FR-X8)
  // ---------------------------------------------------------------------------

  /// Makes (or replaces) the secret link token for [userId]'s calendar feed. Returned once.
  String createCalendarToken(String userId) {
    final token = _newToken();
    db.execute('INSERT OR REPLACE INTO calendar_feeds(user_id, token_hash, created_at) VALUES (?, ?, ?)', [userId, hash(token), _nowSec]);
    return token;
  }

  String? userForCalendarToken(String token) {
    if (token.isEmpty || token.length > 100) return null;
    final r = db.select('SELECT user_id FROM calendar_feeds WHERE token_hash = ?', [hash(token)]);
    return r.isEmpty ? null : r.first['user_id'] as String;
  }

  bool hasCalendarFeed(String userId) => db.select('SELECT 1 FROM calendar_feeds WHERE user_id = ?', [userId]).isNotEmpty;

  void deleteCalendarFeed(String userId) => db.execute('DELETE FROM calendar_feeds WHERE user_id = ?', [userId]);

  /// A consistent copy of the database file, safe to take while the server runs.
  void backupTo(String path) => db.execute('VACUUM INTO ?', [path]);
}
