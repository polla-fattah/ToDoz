/// Shared projects (family sharing, SRS 4.14).
///
/// Each person's data stays in their own space on the server. A shared
/// project's rows exist in every member's space: when a change to one is
/// accepted, the server writes the same change (with the same clock value)
/// into everyone else's space, so each person's phone syncs it like any other
/// edit. Which changes are accepted depends on the person's role. Personal
/// columns (where the project sits in their own tree, what they collapsed) and
/// personal tables (labels, reminders, completions, the activity log) are
/// never copied.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:taskflow_core/sharing.dart';
import 'package:taskflow_core/sync.dart';

import 'store.dart';

class ShareError implements Exception {
  ShareError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class SharePlan {
  /// Changes the person may make; applied to their own space.
  final accepted = <SyncChange>[];

  /// For each other person, the accepted changes to copy to them.
  final fanout = <String, List<SyncChange>>{};

  /// What the person's own space is set back to for changes that were refused.
  final corrections = <SyncChange>[];

  /// Tasks that moved between projects in this batch.
  final moves = <TaskMove>[];

  void copyTo(String userId, SyncChange c) => fanout.putIfAbsent(userId, () => []).add(c);
}

class TaskMove {
  TaskMove(this.row, this.from, this.to, this.hlc);
  final String row;
  final String? from;
  final String? to;
  final String hlc;
}

class Shares {
  Shares(this.store);

  final Store store;

  /// Rows whose fields are cleared (keeping the deletion mark) once the current batch has been written.
  final _toPurge = <String, List<(String, String)>>{};

  /// Called by the store after a batch: clears the fields of rows that were taken away from someone.
  void finishPurges() {
    _toPurge.forEach((user, rows) {
      for (final (t, r) in rows) {
        _purgeFields(user, t, r);
      }
    });
    _toPurge.clear();
  }

  static const inviteTtl = Duration(hours: 24);

  int get _nowSec => store.now.millisecondsSinceEpoch ~/ 1000;
  int get _nowMs => store.now.millisecondsSinceEpoch;

  // ---------------------------------------------------------------------------
  // Who is in a project
  // ---------------------------------------------------------------------------

  /// The role [userId] has in each shared project they take part in.
  Map<String, ShareRole> rolesOf(String userId) => {
        for (final r in store.db.select('SELECT project_id, role FROM shares WHERE user_id = ?', [userId]))
          r['project_id'] as String: ShareRole.parse(r['role'] as String)!,
      };

  ShareRole? roleIn(String projectId, String userId) {
    final r = store.db.select('SELECT role FROM shares WHERE project_id = ? AND user_id = ?', [projectId, userId]);
    return r.isEmpty ? null : ShareRole.parse(r.first['role'] as String);
  }

  List<({String userId, ShareRole role})> participants(String projectId) => [
        for (final r in store.db.select('SELECT user_id, role FROM shares WHERE project_id = ?', [projectId]))
          (userId: r['user_id'] as String, role: ShareRole.parse(r['role'] as String)!),
      ];

  String? ownerOf(String projectId) {
    final r = store.db.select("SELECT user_id FROM shares WHERE project_id = ? AND role = 'owner'", [projectId]);
    return r.isEmpty ? null : r.first['user_id'] as String;
  }

  /// Copies a row's fields to someone who may have had it deleted from their space before (they left
  /// and came back): its `_present` must beat that old deletion, or the project would stay gone.
  List<SyncChange> _revive(String toUser, List<SyncChange> changes) => [
        for (final c in changes)
          if (c.col == presentColumn && c.value == true)
            SyncChange(table: c.table, row: c.row, col: c.col, value: true, hlc: _above(_hlcOf(toUser, c.table, c.row, presentColumn), c.hlc))
          else
            c,
      ];

  /// Every shared project [userId] takes part in, with its members, as the app shows them.
  List<ShareInfo> infoFor(String userId) {
    final out = <ShareInfo>[];
    for (final mine in rolesOf(userId).entries) {
      final members = <ShareMember>[];
      for (final p in participants(mine.key)) {
        final name = store.db.select('SELECT name FROM users WHERE id = ?', [p.userId]);
        if (name.isEmpty) continue;
        members.add(ShareMember(userId: p.userId, name: name.first['name'] as String, role: p.role));
      }
      final owner = ownerOf(mine.key);
      if (owner == null) continue;
      out.add(ShareInfo(projectId: mine.key, ownerId: owner, myRole: mine.value, members: members));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Reading a person's space
  // ---------------------------------------------------------------------------

  Object? _field(String userId, String table, String row, String col) {
    final r = store.db.select('SELECT value FROM fields WHERE user_id = ? AND tbl = ? AND row_id = ? AND col = ?', [userId, table, row, col]);
    return r.isEmpty ? null : jsonDecode(r.first['value'] as String);
  }

  /// The newest value for a field among [batch] (changes not yet applied), else what is stored.
  Object? _fieldWithBatch(String userId, List<SyncChange> batch, String table, String row, String col) {
    SyncChange? best;
    for (final c in batch) {
      if (c.table == table && c.row == row && c.col == col && (best == null || c.hlc.compareTo(best.hlc) > 0)) best = c;
    }
    return best != null ? best.value : _field(userId, table, row, col);
  }

  /// The project a row belongs to, or null if it belongs to none (or the row is unknown).
  String? projectOf(String userId, String table, String row, List<SyncChange> batch) {
    switch (table) {
      case 'projects':
        return row;
      case 'sections':
      case 'tasks':
      case 'project_comments':
        final p = _fieldWithBatch(userId, batch, table, row, 'project_id');
        return p is String ? p : null;
      case 'comments':
        final t = _fieldWithBatch(userId, batch, 'comments', row, 'task_id');
        return t is String ? projectOf(userId, 'tasks', t, batch) : null;
      case 'attachments':
      case 'reactions':
        final c = _fieldWithBatch(userId, batch, table, row, 'comment_id');
        return c is String ? projectOf(userId, 'comments', c, batch) : null;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Routing a batch of changes
  // ---------------------------------------------------------------------------

  String _bumped(String hlc) => formatHlc((_nowMs > hlcWall(hlc) ? _nowMs : hlcWall(hlc)) + 1, 0, 'srv');

  String? _hlcOf(String userId, String table, String row, String col) {
    final r = store.db.select('SELECT hlc FROM fields WHERE user_id = ? AND tbl = ? AND row_id = ? AND col = ?', [userId, table, row, col]);
    return r.isEmpty ? null : r.first['hlc'] as String;
  }

  /// A clock value above both the one stored for a field and [also], so a server-made change wins over what is there.
  String _above(String? stored, [String? also]) {
    var wall = _nowMs;
    for (final h in [stored, also]) {
      if (h != null && hlcWall(h) >= wall) wall = hlcWall(h) + 1;
    }
    return formatHlc(wall, 0, 'srv');
  }

  /// Decides what to do with [changes] from [userId]: which to accept, which
  /// to copy to others, which to refuse.
  SharePlan route(String userId, List<SyncChange> changes) {
    final plan = SharePlan();
    final roles = rolesOf(userId);
    if (roles.isEmpty) {
      plan.accepted.addAll(changes); // nothing of theirs is shared: the common case
      return plan;
    }
    final partCache = <String, List<({String userId, ShareRole role})>>{};
    List<({String userId, ShareRole role})> parts(String p) => partCache.putIfAbsent(p, () => participants(p));

    for (final c in changes) {
      if (!sharedTables.contains(c.table)) {
        plan.accepted.add(c);
        continue;
      }
      final project = projectOf(userId, c.table, c.row, changes);
      final oldProject = c.table == 'tasks' && c.col == 'project_id' ? _field(userId, 'tasks', c.row, 'project_id') as String? : null;
      final role = project == null ? null : roles[project];

      // Moving a task out of a shared project needs a say in that project too.
      if (c.table == 'tasks' && c.col == 'project_id' && oldProject != null && oldProject != project) {
        final oldRole = roles[oldProject];
        if (oldRole != null && !oldRole.canEditTasks) {
          plan.corrections.add(_correct(userId, c));
          continue;
        }
        plan.moves.add(TaskMove(c.row, oldProject, c.value as String?, c.hlc));
      } else if (c.table == 'tasks' && c.col == 'project_id' && oldProject == null && project != null && roles.containsKey(project) && _field(userId, 'tasks', c.row, presentColumn) == true) {
        // A task that already existed (in a private project) moved into a shared one.
        plan.moves.add(TaskMove(c.row, null, project, c.hlc));
      }

      if (role == null) {
        plan.accepted.add(c); // private to this person
        continue;
      }
      if (!mayWrite(role, c.table, c.col)) {
        plan.corrections.add(_correct(userId, c));
        continue;
      }
      plan.accepted.add(c);
      if (isPersonalColumn(c.table, c.col)) continue;
      for (final p in parts(project!)) {
        if (p.userId != userId) plan.copyTo(p.userId, c);
      }
    }
    return plan;
  }

  /// What to write into the person's space to undo a refused change: the value
  /// the project's owner has, with a clock just above the refused one so it wins.
  SyncChange _correct(String userId, SyncChange c) {
    final project = projectOf(userId, c.table, c.row, const []);
    final owner = project == null ? null : ownerOf(project);
    Object? canonical = owner == null ? null : _field(owner, c.table, c.row, c.col);
    if (c.col == presentColumn) {
      // A row the owner does not have (a new row made by someone who may not) is removed again.
      final owns = owner != null && _field(owner, c.table, c.row, presentColumn) == true;
      canonical = owns;
    }
    return SyncChange(table: c.table, row: c.row, col: c.col, value: canonical, hlc: _bumped(c.hlc));
  }

  // ---------------------------------------------------------------------------
  // After a batch is applied: tasks that changed project
  // ---------------------------------------------------------------------------

  /// For tasks moved between projects: removes the task (and its comments) from
  /// people who no longer share it, and sends it whole to people who now do.
  Map<String, List<SyncChange>> afterApply(String userId, SharePlan plan) {
    final out = <String, List<SyncChange>>{};
    for (final m in plan.moves) {
      final before = m.from == null ? <String>{} : {for (final p in participants(m.from!)) p.userId};
      final after = m.to == null ? <String>{} : {for (final p in participants(m.to!)) p.userId};
      for (final gone in before.difference(after)) {
        if (gone == userId) continue;
        final tomb = _tombstones(userId, 'tasks', m.row, m.hlc);
        out.putIfAbsent(gone, () => []).addAll(tomb);
        // The purge happens after these are written (see Store.applyChangesDetailed): remember what to purge.
        for (final t in tomb) {
          (_toPurge[gone] ??= []).add((t.table, t.row));
        }
      }
      for (final added in after.difference(before)) {
        if (added == userId) continue;
        out.putIfAbsent(added, () => []).addAll(_revive(added, _rowTree(userId, 'tasks', m.row)));
      }
    }
    return out;
  }

  void _purgeFields(String userId, String table, String row) =>
      store.db.execute("DELETE FROM fields WHERE user_id = ? AND tbl = ? AND row_id = ? AND col <> '$presentColumn'", [userId, table, row]);

  /// `_present = false` for a task and everything under it, to make it vanish from someone's copy.
  List<SyncChange> _tombstones(String fromUser, String table, String row, String hlc) {
    final out = <SyncChange>[];
    for (final (t, r) in _tree(fromUser, table, row)) {
      out.add(SyncChange(table: t, row: r, col: presentColumn, value: false, hlc: _above(_hlcOf(fromUser, t, r, presentColumn), hlc)));
    }
    return out;
  }

  /// A row and the comments, files and reactions under it (for a task), as (table, row) pairs.
  List<(String, String)> _tree(String userId, String table, String row) {
    final out = <(String, String)>[(table, row)];
    if (table == 'tasks') {
      final comments = [for (final r in store.db.select("SELECT row_id FROM fields WHERE user_id = ? AND tbl = 'comments' AND col = 'task_id' AND value = ?", [userId, jsonEncode(row)])) r['row_id'] as String];
      for (final c in comments) {
        out.add(('comments', c));
        for (final t in ['attachments', 'reactions']) {
          for (final r in store.db.select('SELECT row_id FROM fields WHERE user_id = ? AND tbl = ? AND col = ? AND value = ?', [userId, t, 'comment_id', jsonEncode(c)])) {
            out.add((t, r['row_id'] as String));
          }
        }
      }
    }
    return out;
  }

  /// All the shared (non-personal) fields of a row and what is under it, with their own clocks.
  List<SyncChange> _rowTree(String fromUser, String table, String row) {
    final out = <SyncChange>[];
    for (final (t, r) in _tree(fromUser, table, row)) {
      out.addAll(_rowFields(fromUser, t, r));
    }
    return out;
  }

  List<SyncChange> _rowFields(String fromUser, String table, String row) {
    final out = <SyncChange>[];
    for (final f in store.db.select('SELECT col, value, hlc FROM fields WHERE user_id = ? AND tbl = ? AND row_id = ?', [fromUser, table, row])) {
      final col = f['col'] as String;
      if (isPersonalColumn(table, col)) continue;
      out.add(SyncChange(table: table, row: row, col: col, value: jsonDecode(f['value'] as String), hlc: f['hlc'] as String));
    }
    return out;
  }

  /// The ids of every row in [projectId]'s scope held in [fromUser]'s space, by table.
  Map<String, List<String>> _scope(String fromUser, String projectId) {
    final out = <String, List<String>>{
      'projects': [projectId],
    };
    List<String> rowsWhere(String table, String col, String value) => [
          for (final r in store.db.select('SELECT row_id FROM fields WHERE user_id = ? AND tbl = ? AND col = ? AND value = ?', [fromUser, table, col, jsonEncode(value)])) r['row_id'] as String,
        ];
    out['sections'] = rowsWhere('sections', 'project_id', projectId);
    out['project_comments'] = rowsWhere('project_comments', 'project_id', projectId);
    out['tasks'] = rowsWhere('tasks', 'project_id', projectId);
    out['comments'] = [for (final t in out['tasks']!) ...rowsWhere('comments', 'task_id', t)];
    out['attachments'] = [for (final c in out['comments']!) ...rowsWhere('attachments', 'comment_id', c)];
    out['reactions'] = [for (final c in out['comments']!) ...rowsWhere('reactions', 'comment_id', c)];
    return out;
  }

  /// Everything in [projectId]'s scope as changes, skipping rows that are deleted outright.
  List<SyncChange> projectContents(String fromUser, String projectId) {
    final out = <SyncChange>[];
    _scope(fromUser, projectId).forEach((table, rows) {
      for (final r in rows) {
        if (_field(fromUser, table, r, presentColumn) == false) continue;
        out.addAll(_rowFields(fromUser, table, r));
      }
    });
    return out;
  }

  // ---------------------------------------------------------------------------
  // Invites, joining, leaving
  // ---------------------------------------------------------------------------

  static String _hash(String s) => sha256.convert(utf8.encode(s)).toString();

  /// Makes a one-time code that lets someone join [projectId] as [role].
  /// Only the owner or an admin may. The first invite starts sharing the project.
  String createInvite(String actorId, String projectId, ShareRole role) {
    if (role == ShareRole.owner) throw ShareError(400, 'There is only one owner');
    var mine = roleIn(projectId, actorId);
    if (mine == null) {
      // Not shared yet: only the person whose project it is can start sharing it.
      final present = _field(actorId, 'projects', projectId, presentColumn);
      if (projectId == 'inbox') throw ShareError(400, 'The Inbox is private and cannot be shared');
      if (present != true || _field(actorId, 'projects', projectId, 'deleted_at') != null) throw ShareError(404, 'No such project');
      store.db.execute('INSERT INTO shares(project_id, user_id, role, owner_id, created_at) VALUES (?, ?, ?, ?, ?)', [projectId, actorId, 'owner', actorId, _nowSec]);
      mine = ShareRole.owner;
    }
    if (!mine.canManageMembers) throw ShareError(403, 'Only an owner or admin can invite people');
    if (role == ShareRole.admin && mine != ShareRole.owner) throw ShareError(403, 'Only the owner can make someone an admin');
    store.db.execute('DELETE FROM share_invites WHERE expires_at < ?', [_nowSec]);
    final pending = store.db.select('SELECT COUNT(*) AS n FROM share_invites WHERE project_id = ? AND used_at IS NULL', [projectId]).first['n'] as int;
    if (pending >= 20) throw ShareError(429, 'There are too many unused invites for this project. Wait for them to expire or be used.');
    final code = store.newPairingCode();
    store.db.execute(
      'INSERT INTO share_invites(code_hash, project_id, owner_id, role, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [_hash(code), projectId, ownerOf(projectId), role.name, actorId, _nowSec, _nowSec + inviteTtl.inSeconds],
    );
    return code;
  }

  /// Lets [userId] join with an invite code. Returns the project id, or null if the code is not valid.
  ({String projectId, ShareRole role})? redeemInvite(String userId, String code) {
    final normalised = normalisePairingCode(code);
    if (!isValidPairingCode(normalised)) return null;
    final rows = store.db.select(
      'SELECT project_id, owner_id, role FROM share_invites WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?',
      [_hash(normalised), _nowSec],
    );
    if (rows.isEmpty) return null;
    final projectId = rows.first['project_id'] as String;
    final ownerId = rows.first['owner_id'] as String;
    final role = ShareRole.parse(rows.first['role'] as String)!;
    if (roleIn(projectId, userId) != null) throw ShareError(409, 'You are already in this project');
    store.db.execute('UPDATE share_invites SET used_at = ?, used_by = ? WHERE code_hash = ?', [_nowSec, userId, _hash(normalised)]);
    store.db.execute('INSERT INTO shares(project_id, user_id, role, owner_id, created_at) VALUES (?, ?, ?, ?, ?)', [projectId, userId, role.name, ownerId, _nowSec]);
    // The new member gets a full copy of the project as it is now.
    store.applyRaw(userId, 'fanout', _revive(userId, projectContents(ownerId, projectId)));
    return (projectId: projectId, role: role);
  }

  /// Changes someone's role. Admins can manage members and viewers; only the owner can make or change admins.
  void setRole(String actorId, String projectId, String targetId, ShareRole role) {
    final mine = roleIn(projectId, actorId);
    final theirs = roleIn(projectId, targetId);
    if (mine == null || !mine.canManageMembers) throw ShareError(403, 'Only an owner or admin can change roles');
    if (theirs == null) throw ShareError(404, 'That person is not in this project');
    if (theirs == ShareRole.owner || role == ShareRole.owner) throw ShareError(400, 'The owner\'s role cannot be changed');
    if ((theirs == ShareRole.admin || role == ShareRole.admin) && mine != ShareRole.owner) throw ShareError(403, 'Only the owner can change an admin');
    store.db.execute('UPDATE shares SET role = ? WHERE project_id = ? AND user_id = ?', [role.name, projectId, targetId]);
  }

  /// Takes [targetId] out of the project (an admin or the owner), or lets them leave ([actorId] == [targetId]).
  /// Their copy of the project is removed; tasks assigned to them become unassigned; the project's data stays.
  void removeMember(String actorId, String projectId, String targetId) {
    final mine = roleIn(projectId, actorId);
    final theirs = roleIn(projectId, targetId);
    if (mine == null) throw ShareError(404, 'No such project');
    if (theirs == null) throw ShareError(404, 'That person is not in this project');
    if (theirs == ShareRole.owner) throw ShareError(400, 'The owner cannot be removed or leave. Stop sharing instead.');
    if (actorId != targetId) {
      if (!mine.canManageMembers) throw ShareError(403, 'Only an owner or admin can remove people');
      if (theirs == ShareRole.admin && mine != ShareRole.owner) throw ShareError(403, 'Only the owner can remove an admin');
    }
    _eject(projectId, targetId);
    _dropIfAlone(projectId);
  }

  /// The owner stops sharing: everyone else's copy is removed; the owner keeps the project.
  void stopSharing(String actorId, String projectId) {
    if (roleIn(projectId, actorId) != ShareRole.owner) throw ShareError(403, 'Only the owner can stop sharing');
    for (final p in participants(projectId)) {
      if (p.userId != actorId) _eject(projectId, p.userId);
    }
    _dropIfAlone(projectId);
  }

  void _eject(String projectId, String targetId) {
    final owner = ownerOf(projectId);
    // Find what is in their copy before anything is removed.
    final scope = _scope(targetId, projectId);
    final assigned = [
      for (final t in scope['tasks']!)
        if (_field(targetId, 'tasks', t, 'assignee_id') == targetId) t,
    ];
    store.db.execute('DELETE FROM shares WHERE project_id = ? AND user_id = ?', [projectId, targetId]);
    store.db.execute('DELETE FROM share_invites WHERE project_id = ? AND created_by = ? AND used_at IS NULL', [projectId, targetId]);
    // Their assigned tasks become unassigned for everyone who stays.
    if (assigned.isNotEmpty && owner != null) {
      store.applyChangesDetailed(owner, 'srv', [
        for (final t in assigned) ...[
          SyncChange(table: 'tasks', row: t, col: 'assignee_id', value: null, hlc: _above(_hlcOf(targetId, 'tasks', t, 'assignee_id'), _hlcOf(owner, 'tasks', t, 'assignee_id'))),
          SyncChange(table: 'tasks', row: t, col: 'assigned_by', value: null, hlc: _above(_hlcOf(targetId, 'tasks', t, 'assigned_by'), _hlcOf(owner, 'tasks', t, 'assigned_by'))),
        ],
      ]);
    }
    // Their own copy of the project goes away.
    final tomb = <SyncChange>[
      for (final entry in scope.entries)
        for (final r in entry.value) SyncChange(table: entry.key, row: r, col: presentColumn, value: false, hlc: _above(_hlcOf(targetId, entry.key, r, presentColumn))),
    ];
    store.applyRaw(targetId, 'srv', tomb);
    // Keep only the deletion marks. If they are invited again, every field is written fresh and so reaches their phone again.
    for (final entry in scope.entries) {
      for (final r in entry.value) {
        _purgeFields(targetId, entry.key, r);
      }
    }
    store.notifyApplied(targetId, tomb);
  }

  void _dropIfAlone(String projectId) {
    final left = participants(projectId);
    if (left.length <= 1) {
      store.db.execute('DELETE FROM shares WHERE project_id = ?', [projectId]);
      store.db.execute('DELETE FROM share_invites WHERE project_id = ?', [projectId]);
    }
  }

  /// When an account is deleted, projects they own that others share pass to
  /// the longest-standing admin, else the longest-standing member, so the
  /// others keep their copies. Projects shared with no one else just end.
  void handOver(String leavingUserId) {
    final owned = [for (final r in store.db.select("SELECT project_id FROM shares WHERE user_id = ? AND role = 'owner'", [leavingUserId])) r['project_id'] as String];
    for (final p in owned) {
      final others = [
        for (final r in store.db.select(
          "SELECT user_id, role FROM shares WHERE project_id = ? AND user_id <> ? ORDER BY CASE role WHEN 'admin' THEN 0 WHEN 'member' THEN 1 ELSE 2 END, created_at",
          [p, leavingUserId],
        ))
          r['user_id'] as String,
      ];
      if (others.isEmpty) {
        store.db.execute('DELETE FROM shares WHERE project_id = ?', [p]);
        continue;
      }
      final heir = others.first;
      store.db.execute("UPDATE shares SET role = 'owner' WHERE project_id = ? AND user_id = ?", [p, heir]);
      store.db.execute('UPDATE shares SET owner_id = ? WHERE project_id = ?', [heir, p]);
      store.db.execute('UPDATE share_invites SET owner_id = ? WHERE project_id = ?', [heir, p]);
    }
    store.db.execute('DELETE FROM shares WHERE user_id = ?', [leavingUserId]);
  }
}
