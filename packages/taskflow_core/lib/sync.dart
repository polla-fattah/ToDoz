/// Sync rules shared by the app and the server (SRS 4.11, 6.3).
///
/// Every edit is recorded as a *field change*: "in table T, row R, column C
/// the value became V at time H". H is a hybrid logical clock. For one field
/// the change with the largest H wins; two devices that edit different
/// fields of one task both keep their edits (FR-S3). A row is deleted or
/// restored through the `_present` pseudo-field, so a later restore beats an
/// earlier delete and the reverse (FR-S4).
///
/// The server stores only (table, row, column, value, clock): it never needs
/// to understand tasks, which keeps it small and keeps the merge rule in one
/// place. Pure Dart.
library;

/// The pseudo-column that says whether a row exists.
const presentColumn = '_present';

/// The tables that sync, and the columns of each that are shared between
/// devices. Anything not listed stays on the device (settings, snooze).
const syncSchema = <String, List<String>>{
  'projects': ['name', 'color', 'parent_id', 'is_favorite', 'is_archived', 'sort_order', 'view_options', 'created_at', 'updated_at', 'deleted_at'],
  'sections': ['project_id', 'name', 'sort_order', 'is_collapsed', 'is_archived', 'created_at', 'updated_at', 'deleted_at'],
  'labels': ['name', 'color', 'is_favorite', 'sort_order', 'created_at', 'updated_at', 'deleted_at'],
  'tasks': [
    'title', 'description', 'project_id', 'section_id', 'parent_id', 'priority', 'due_date', 'due_time',
    'recurrence', 'deadline', 'duration_minutes', 'completed_at', 'sort_order', 'is_collapsed',
    'assignee_id', 'assigned_by', 'created_at', 'updated_at', 'deleted_at',
  ],
  'task_labels': [],
  'comments': ['task_id', 'body', 'author_id', 'created_at', 'updated_at', 'deleted_at'],
  'reactions': ['comment_id', 'user_id', 'emoji', 'created_at'],
  'reminders': ['task_id', 'spec', 'created_at', 'updated_at', 'deleted_at'],
  'places': ['name', 'latitude', 'longitude', 'radius_meters', 'created_at', 'updated_at', 'deleted_at'],
  'location_reminders': ['task_id', 'place_id', 'kind', 'created_at', 'updated_at', 'deleted_at'],
  'attachments': ['comment_id', 'file_name', 'mime_type', 'size_bytes', 'hash', 'created_at', 'updated_at', 'deleted_at'],
  'completions': ['task_id', 'completed_at', 'due_date', 'due_time'],
  'project_comments': ['project_id', 'body', 'created_at', 'updated_at', 'deleted_at'],
  'activity': ['event', 'entity_type', 'entity_id', 'project_id', 'title', 'field', 'old_value', 'new_value', 'at_ms', 'device'],
  'filters': ['name', 'query', 'color', 'is_favorite', 'sort_order', 'view_options', 'created_at', 'updated_at', 'deleted_at'],
};

const maxRowIdLength = 200;
const maxValueBytes = 100 * 1024;
const maxChangesPerRequest = 1000;

// -----------------------------------------------------------------------------
// Clock
// -----------------------------------------------------------------------------

/// A hybrid logical clock value as a string that sorts correctly as text:
/// `<13-digit milliseconds>-<10-digit counter>-<node>`. [node] is the device id.
String formatHlc(int wallMs, int counter, String node) =>
    '${wallMs.toString().padLeft(13, '0')}-${counter.toString().padLeft(10, '0')}-$node';

final _hlcPattern = RegExp(r'^\d{13}-\d{10}-[A-Za-z0-9_-]{1,64}$');

bool isValidHlc(String s) => _hlcPattern.hasMatch(s);

/// The wall-clock part of [hlc] in milliseconds.
int hlcWall(String hlc) => int.parse(hlc.substring(0, 13));

/// The counter part of [hlc].
int hlcCounter(String hlc) => int.parse(hlc.substring(14, 24));

/// A source of increasing clock values for one device.
///
/// [receive] must be called with every remote clock seen, so values issued
/// afterwards sort after it even when this device's own clock is behind
/// (a phone with the wrong time cannot make old edits win).
class HlcClock {
  HlcClock(this.node, {int Function()? wallMs, int lastWall = 0, int lastCounter = 0})
      : _wallMs = wallMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _wall = lastWall,
        _counter = lastCounter;

  final String node;
  final int Function() _wallMs;
  int _wall;
  int _counter;

  String next() {
    final now = _wallMs();
    if (now > _wall) {
      _wall = now;
      _counter = 0;
    } else {
      _counter++;
    }
    return formatHlc(_wall, _counter, node);
  }

  void receive(String remote) {
    final w = hlcWall(remote);
    final c = hlcCounter(remote);
    if (w > _wall) {
      _wall = w;
      _counter = c;
    } else if (w == _wall && c > _counter) {
      _counter = c;
    }
  }

  /// The state to store so the clock can resume after a restart.
  ({int wall, int counter}) get state => (wall: _wall, counter: _counter);
}

/// Whether an incoming change beats what is stored. Clocks are unique per
/// device and change (the counter and node break ties), so equal means the
/// same change arriving twice, which changes nothing.
bool incomingWins(String? currentHlc, String incomingHlc) => currentHlc == null || incomingHlc.compareTo(currentHlc) > 0;

// -----------------------------------------------------------------------------
// Changes and messages
// -----------------------------------------------------------------------------

class SyncFormatException implements FormatException {
  SyncFormatException(this.message);
  @override
  final String message;
  @override
  dynamic get source => null;
  @override
  int? get offset => null;
  @override
  String toString() => message;
}

/// One field change. [value] is any JSON value (null, bool, number, string).
class SyncChange {
  const SyncChange({required this.table, required this.row, required this.col, required this.value, required this.hlc});

  final String table;
  final String row;
  final String col;
  final Object? value;
  final String hlc;

  Map<String, Object?> toJson() => {'t': table, 'r': row, 'c': col, 'v': value, 'h': hlc};

  /// Checks a change from the outside world (SEC-9): known table, allowed
  /// column, sane row id and clock, JSON-shaped value of bounded size.
  factory SyncChange.fromJson(Object? json) {
    if (json is! Map) throw SyncFormatException('A change must be an object');
    final t = json['t'], r = json['r'], c = json['c'], h = json['h'];
    if (t is! String || !syncSchema.containsKey(t)) throw SyncFormatException('Unknown table');
    if (r is! String || r.isEmpty || r.length > maxRowIdLength || r.contains(RegExp(r'[\x00-\x1f]'))) {
      throw SyncFormatException('Bad row id');
    }
    if (c is! String || !(c == presentColumn || syncSchema[t]!.contains(c))) throw SyncFormatException('Unknown column');
    if (h is! String || !isValidHlc(h)) throw SyncFormatException('Bad clock');
    final v = json['v'];
    if (!_isJsonValue(v)) throw SyncFormatException('Bad value');
    if (c == presentColumn && v is! bool) throw SyncFormatException('_present must be true or false');
    if (_approxSize(v) > maxValueBytes) throw SyncFormatException('Value too large');
    return SyncChange(table: t, row: r, col: c, value: v, hlc: h);
  }

  @override
  bool operator ==(Object other) =>
      other is SyncChange && other.table == table && other.row == row && other.col == col && other.hlc == hlc && other.value == value;

  @override
  int get hashCode => Object.hash(table, row, col, hlc, value);

  @override
  String toString() => 'SyncChange($table/$row.$col=$value @$hlc)';
}

bool _isJsonValue(Object? v) => v == null || v is bool || v is num || v is String;

int _approxSize(Object? v) => v is String ? v.length * 3 : 16;

class SyncRequest {
  const SyncRequest({required this.cursor, required this.changes, this.limit = 500});

  /// The last server sequence number this device has received.
  final int cursor;
  final List<SyncChange> changes;

  /// The most changes to send back.
  final int limit;

  Map<String, Object?> toJson() => {'cursor': cursor, 'limit': limit, 'changes': [for (final c in changes) c.toJson()]};

  factory SyncRequest.fromJson(Object? json) {
    if (json is! Map) throw SyncFormatException('Request must be an object');
    final cursor = json['cursor'];
    if (cursor is! int || cursor < 0) throw SyncFormatException('Bad cursor');
    final limit = json['limit'] ?? 500;
    if (limit is! int || limit < 1 || limit > 2000) throw SyncFormatException('Bad limit');
    final raw = json['changes'] ?? const [];
    if (raw is! List) throw SyncFormatException('changes must be a list');
    if (raw.length > maxChangesPerRequest) throw SyncFormatException('Too many changes in one request');
    return SyncRequest(cursor: cursor, limit: limit, changes: [for (final c in raw) SyncChange.fromJson(c)]);
  }
}

class SyncResponse {
  const SyncResponse({required this.cursor, required this.changes, required this.more, this.shares});

  /// The shared projects this person takes part in, with their members (null from a server that has no sharing).
  final List<Object?>? shares;

  /// The sequence number to send next time.
  final int cursor;
  final List<SyncChange> changes;

  /// True if there is more waiting; ask again straight away.
  final bool more;

  Map<String, Object?> toJson() => {'cursor': cursor, 'more': more, 'changes': [for (final c in changes) c.toJson()], 'shares': ?shares};

  factory SyncResponse.fromJson(Object? json) {
    if (json is! Map) throw SyncFormatException('Response must be an object');
    final cursor = json['cursor'];
    if (cursor is! int) throw SyncFormatException('Bad cursor');
    final raw = json['changes'];
    if (raw is! List) throw SyncFormatException('changes must be a list');
    final shares = json['shares'];
    return SyncResponse(cursor: cursor, more: json['more'] == true, changes: [for (final c in raw) SyncChange.fromJson(c)], shares: shares is List ? shares.cast<Object?>() : null);
  }
}

/// Keeps only the newest change for each field, in clock order. Used before
/// sending, so ten edits to one title travel as one.
List<SyncChange> collapseChanges(Iterable<SyncChange> changes) {
  final latest = <String, SyncChange>{};
  for (final c in changes) {
    final key = '${c.table}\u0000${c.row}\u0000${c.col}';
    final cur = latest[key];
    if (cur == null || incomingWins(cur.hlc, c.hlc)) latest[key] = c;
  }
  final out = latest.values.toList()..sort((a, b) => a.hlc.compareTo(b.hlc));
  return out;
}

// -----------------------------------------------------------------------------
// Pairing messages
// -----------------------------------------------------------------------------

/// A pairing code is 8 characters from an alphabet without look-alikes,
/// shown as XXXX-XXXX.
const pairingAlphabet = '23456789ABCDEFGHJKMNPQRSTVWXYZ';

String normalisePairingCode(String input) => input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

bool isValidPairingCode(String input) {
  final c = normalisePairingCode(input);
  return c.length == 8 && c.split('').every(pairingAlphabet.contains);
}

String formatPairingCode(String code) => '${code.substring(0, 4)}-${code.substring(4)}';
