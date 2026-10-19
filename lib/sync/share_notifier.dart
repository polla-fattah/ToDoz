import 'dart:convert';

import 'package:drift/drift.dart';

import '../data/repository.dart';

/// Shows a notification on the phone. The real one is the notification service; tests record the calls.
abstract class ShareAlerts {
  Future<void> show({required int id, required String title, required String body, String? taskId});
}

/// Tells this person about what others did in shared projects since they last
/// looked: a new comment, or a task assigned to them (FR-W3). It runs after each
/// sync, so while the app is closed the alert comes with the next background
/// sync (a later release adds a periodic one), not instantly.
class ShareNotifier {
  ShareNotifier(this.repo, this.alerts, {this.maxAlerts = 5, this.window = const Duration(days: 14)});

  final Repo repo;
  final ShareAlerts alerts;

  /// At most this many separate notifications per check; the rest are summarised in one.
  final int maxAlerts;

  /// Only things from this long ago or newer are considered.
  final Duration window;

  static const _seenKey = 'share.seen';

  /// Looks for new activity by others and notifies. The first check only
  /// records what is already there, so joining a project does not buzz about its history.
  /// Returns how many things were reported.
  Future<int> check() async {
    final me = repo.me;
    if (me == null) return 0;
    final shared = [for (final s in await repo.db.select(repo.db.sharedProjects).get()) s.projectId];
    if (shared.isEmpty) return 0;

    final since = repo.now.subtract(window);
    final names = <String, String>{};
    for (final s in await repo.db.select(repo.db.sharedProjects).get()) {
      for (final m in SharedProject.fromRow(s).members) {
        names[m.userId] = m.name;
      }
    }
    String who(String? id) => id == null ? 'Someone' : (names[id] ?? 'Someone');

    final items = <({String key, String title, String body, String taskId})>[];

    // New comments by other people on tasks in shared projects.
    final q = repo.db.select(repo.db.comments).join([
      innerJoin(repo.db.tasks, repo.db.tasks.id.equalsExp(repo.db.comments.taskId)),
    ])
      ..where(repo.db.tasks.projectId.isIn(shared) &
          repo.db.comments.deletedAt.isNull() &
          repo.db.comments.createdAt.isBiggerOrEqualValue(since) &
          repo.db.comments.authorId.isNotNull() &
          repo.db.comments.authorId.equals(me).not());
    for (final r in await q.get()) {
      final c = r.readTable(repo.db.comments);
      final t = r.readTable(repo.db.tasks);
      items.add((key: 'c:${c.id}', title: '${who(c.authorId)} commented on "${t.title}"', body: c.body, taskId: t.id));
    }

    // Tasks given to me by someone else.
    final a = repo.db.select(repo.db.tasks)
      ..where((t) =>
          t.projectId.isIn(shared) &
          t.deletedAt.isNull() &
          t.completedAt.isNull() &
          t.assigneeId.equals(me) &
          t.assignedBy.isNotNull() &
          t.assignedBy.equals(me).not() &
          t.updatedAt.isBiggerOrEqualValue(since));
    for (final t in await a.get()) {
      items.add((key: 'a:${t.id}:${t.assignedBy}', title: '${who(t.assignedBy)} assigned you a task', body: t.title, taskId: t.id));
    }

    final raw = await repo.getSetting(_seenKey);
    final firstTime = raw == null;
    final seen = <String>{};
    if (raw != null) {
      try {
        seen.addAll((jsonDecode(raw) as List).cast<String>());
      } catch (_) {}
    }
    final fresh = [for (final i in items) if (!seen.contains(i.key)) i];
    seen.addAll(items.map((i) => i.key));
    final keep = seen.toList();
    await repo.setSetting(_seenKey, jsonEncode(keep.length > 600 ? keep.sublist(keep.length - 600) : keep));
    if (firstTime || fresh.isEmpty) return 0;

    var id = 7000; // a range of its own, clear of reminder ids
    for (final i in fresh.take(maxAlerts)) {
      await alerts.show(id: id++, title: i.title, body: i.body.length > 120 ? '${i.body.substring(0, 117)}...' : i.body, taskId: i.taskId);
    }
    if (fresh.length > maxAlerts) {
      await alerts.show(id: id, title: '${fresh.length - maxAlerts} more updates in shared projects', body: 'Open ToDoz to see them.');
    }
    return fresh.length;
  }
}
