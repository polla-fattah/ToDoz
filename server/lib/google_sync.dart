/// Keeps a person's tasks and a Google calendar in step, both ways (like
/// Todoist's Google Calendar integration):
///
///  * every open task with a due date is an event in a calendar called
///    "TaskFlow" (at its time, or all day), kept up to date as the task changes;
///  * finishing, deleting or un-dating a task removes its event;
///  * dragging an event to another time in Google moves the task.
///
/// Titles, notes and everything else are one way: a change made to the task
/// overwrites the event. Only the date, the time and the length come back.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:taskflow_core/date_parser.dart';

import 'google_api.dart';
import 'model.dart';
import 'store.dart';

const defaultEventMinutes = 30;

class GoogleSyncReport {
  int created = 0;
  int updated = 0;
  int deleted = 0;
  int pulled = 0;
  String? error;
  bool needsReconnect = false;

  @override
  String toString() => 'created $created, updated $updated, deleted $deleted, moved in TaskFlow $pulled${error == null ? '' : ', error: $error'}';
}

/// The date, time and length an event or task describes.
class When {
  const When(this.date, this.time, this.minutes);
  final String date;
  final String? time;

  /// Length in minutes for a timed event; null for all day.
  final int? minutes;

  @override
  bool operator ==(Object other) => other is When && other.date == date && other.time == time && other.minutes == minutes;
  @override
  int get hashCode => Object.hash(date, time, minutes);
  @override
  String toString() => 'When($date $time $minutes)';
}

String _hash(Map<String, Object?> spec) => sha256.convert(utf8.encode(jsonEncode(spec))).toString().substring(0, 32);

String _wall(DateTime d) => '${formatDate(d)}T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:00';

/// How a task looks as a Google event: the parts we write.
Map<String, Object?> eventSpec(Map<String, Object?> task, String timeZone, {String? projectName}) {
  final due = task['due'] as Map<String, Object?>;
  final date = parseIsoDate(due['date'] as String)!;
  final time = due['time'] as String?;
  final priority = task['priority'] as int? ?? 4;
  final notes = [
    if ((task['description'] as String? ?? '').isNotEmpty) task['description'] as String,
    if (due['recurrence'] != null) 'Repeats: ${due['recurrence']}',
    if (projectName != null && projectName != 'Inbox') 'Project: $projectName',
    if (priority < 4) 'Priority: p$priority',
  ].join('\n');
  final Map<String, Object?> start, end;
  if (time != null && parseClock(time) != null) {
    final m = parseClock(time)!;
    final s = DateTime(date.year, date.month, date.day, m ~/ 60, m % 60);
    final len = (task['duration_minutes'] as int?) ?? defaultEventMinutes;
    start = {'dateTime': _wall(s), 'timeZone': timeZone};
    end = {'dateTime': _wall(s.add(Duration(minutes: len))), 'timeZone': timeZone};
  } else {
    start = {'date': formatDate(date)};
    end = {'date': formatDate(DateTime(date.year, date.month, date.day + 1))};
  }
  return {
    'summary': task['title'],
    'description': notes,
    'start': start,
    'end': end,
    // Red, orange, blue for p1, p2, p3 (Google's event colours 11, 6 and 9); p4 uses the calendar's own.
    if (priority >= 1 && priority <= 3) 'colorId': const {1: '11', 2: '6', 3: '9'}[priority],
    'transparency': 'transparent',
  };
}

/// Reads when an event (or a stored spec) happens, in the wall-clock time of
/// [timeZone]. Returns null if it cannot be read that way (an event the person
/// moved to another time zone, say): those are left alone rather than guessed.
When? readWhen(Map<String, Object?> event, String timeZone) {
  final start = event['start'];
  final end = event['end'];
  if (start is! Map) return null;
  final startDate = start['date'];
  if (startDate is String) {
    return parseIsoDate(startDate) == null ? null : When(startDate, null, null);
  }
  final dt = start['dateTime'];
  if (dt is! String) return null;
  final zone = start['timeZone'];
  if (zone is String ? zone != timeZone : dt.endsWith('Z')) return null;
  final m = RegExp(r'^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})').firstMatch(dt);
  if (m == null || parseIsoDate(m[1]!) == null) return null;
  int? minutes;
  if (end is Map && end['dateTime'] is String) {
    final e = RegExp(r'^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})').firstMatch(end['dateTime'] as String);
    if (e != null && parseIsoDate(e[1]!) != null) {
      final a = DateTime.utc(int.parse(m[1]!.substring(0, 4)), int.parse(m[1]!.substring(5, 7)), int.parse(m[1]!.substring(8)), int.parse(m[2]!), int.parse(m[3]!));
      final b = DateTime.utc(int.parse(e[1]!.substring(0, 4)), int.parse(e[1]!.substring(5, 7)), int.parse(e[1]!.substring(8)), int.parse(e[2]!), int.parse(e[3]!));
      minutes = b.difference(a).inMinutes;
    }
  }
  return When(m[1]!, '${m[2]}:${m[3]}', minutes);
}

class GoogleSyncer {
  GoogleSyncer(this.store, this.api, {this.log});

  final Store store;
  final GoogleApi api;
  final void Function(String line)? log;
  final _running = <String>{};

  bool isRunning(String userId) => _running.contains(userId);

  final _inflight = <Future<void>>{};

  /// Completes when every sync started so far has finished (for tests and a clean shutdown).
  Future<void> flush() async {
    while (_inflight.isNotEmpty) {
      await Future.wait(List.of(_inflight));
    }
  }

  /// Starts a sync without waiting for it; [flush] waits for it.
  void syncInBackground(String userId) {
    late Future<void> f;
    f = syncUser(userId).then<void>((_) {}).whenComplete(() => _inflight.remove(f));
    _inflight.add(f);
  }

  /// Runs one sync for [userId]. Returns what it did; problems are in [GoogleSyncReport.error]
  /// and saved for the app to show.
  Future<GoogleSyncReport> syncUser(String userId) async {
    final report = GoogleSyncReport();
    if (!_running.add(userId)) {
      report.error = 'A sync is already running';
      return report;
    }
    final started = store.now;
    try {
      final account = store.googleAccount(userId);
      if (account == null) {
        report.error = 'Google Calendar is not connected';
        return report;
      }
      final access = await api.accessToken(account.refreshToken);
      var calendar = account.calendarId;
      if (calendar == null || !await api.calendarExists(access, calendar)) {
        // First time, or the person deleted the calendar in Google: make a fresh one and start over.
        calendar = await api.createCalendar(access, 'TaskFlow', account.timeZone);
        store.setGoogleCalendar(userId, calendar);
        for (final taskId in store.googleEvents(userId).keys) {
          store.deleteGoogleEvent(userId, taskId);
        }
      }
      await _sync(userId, account, access, calendar, report);
      store.recordGoogleSync(userId, startedAt: started);
    } on GoogleAuthError catch (e) {
      report.error = 'Google no longer accepts the saved sign-in (${e.message}). Connect again.';
      report.needsReconnect = true;
      store.recordGoogleSync(userId, startedAt: started, error: report.error, needsReconnect: true);
    } on GoogleApiError catch (e) {
      report.error = e.toString();
      store.recordGoogleSync(userId, startedAt: started, error: report.error);
    } catch (e) {
      report.error = 'Sync failed: ${e.runtimeType}';
      store.recordGoogleSync(userId, startedAt: started, error: report.error);
      log?.call('google sync for ${userId.substring(0, 8)} failed: $e');
    } finally {
      _running.remove(userId);
    }
    return report;
  }

  Future<void> _sync(String userId, GoogleAccount account, String access, String calendar, GoogleSyncReport report) async {
    final tz = account.timeZone;
    final model = UserModel(store, userId, source: 'google');
    final links = store.googleEvents(userId);

    Map<String, ({Map<String, Object?> task, Map<String, Object?> spec, String hash})> desired() {
      final projects = {for (final p in model.projects()) p['id'] as String: p['name'] as String};
      final out = <String, ({Map<String, Object?> task, Map<String, Object?> spec, String hash})>{};
      for (final t in model.tasks()) {
        if (t['due'] == null) continue;
        final spec = eventSpec(t, tz, projectName: projects[t['project_id']]);
        out[t['id'] as String] = (task: t, spec: spec, hash: _hash(spec));
      }
      return out;
    }

    var want = desired();

    // 1. What changed in Google since last time.
    final since = account.lastSync == null ? null : DateTime.fromMillisecondsSinceEpoch(account.lastSync! * 1000 - 120000, isUtc: true);
    final events = await api.listChanged(access, calendar, updatedMin: since);
    for (final e in events) {
      final props = (e['extendedProperties'] as Map?)?['private'] as Map?;
      final taskId = props?['taskflowId'] as String?;
      if (taskId == null) continue;
      final link = links[taskId];
      if (link == null || link.eventId != e['id']) continue;
      if (e['status'] == 'cancelled') {
        // The person deleted the event. The task stays; the event is not recreated unless the task changes.
        if (want.containsKey(taskId)) {
          final orphan = link.copyWith(state: 'orphaned');
          links[taskId] = orphan;
          store.saveGoogleEvent(userId, orphan);
        } else {
          links.remove(taskId);
          store.deleteGoogleEvent(userId, taskId);
        }
        continue;
      }
      if (link.state != 'linked') continue;
      final nowWhen = readWhen(e, tz);
      final thenWhen = readWhen(link.spec, tz);
      if (nowWhen == null || nowWhen == thenWhen) continue;
      final current = want[taskId];
      if (current == null) continue;
      if (current.hash != link.specHash) {
        // Both sides changed: the later change wins.
        final eventUpdated = DateTime.tryParse('${e['updated']}');
        final taskUpdated = model.table('tasks')[taskId]?['updated_at'];
        if (eventUpdated != null && taskUpdated is int && taskUpdated * 1000 > eventUpdated.millisecondsSinceEpoch) continue;
      }
      try {
        model.updateTask(taskId, {
          'due_date': nowWhen.date,
          'due_time': nowWhen.time,
          if (nowWhen.time != null && nowWhen.minutes != null && nowWhen.minutes! > 0) 'duration_minutes': nowWhen.minutes == defaultEventMinutes && (current.task['duration_minutes'] == null) ? null : nowWhen.minutes,
        });
      } on ModelError catch (err) {
        log?.call('google: could not move task ${taskId.substring(0, 8)}: ${err.message}');
        continue;
      }
      report.pulled++;
      want = desired();
      final fresh = want[taskId];
      if (fresh != null) {
        final moved = link.copyWith(spec: fresh.spec, specHash: fresh.hash);
        links[taskId] = moved;
        store.saveGoogleEvent(userId, moved);
      }
    }

    // 2. Push tasks that are new or changed.
    for (final entry in want.entries) {
      final taskId = entry.key;
      final spec = entry.value.spec;
      final hash = entry.value.hash;
      final link = links[taskId];
      if (link != null && link.state == 'linked' && link.specHash == hash) continue;
      if (link != null && link.state == 'orphaned' && link.specHash == hash) continue;
      final body = {
        ...spec,
        'extendedProperties': {
          'private': {'taskflowId': taskId},
        },
      };
      if (link != null && link.state == 'linked') {
        try {
          await api.patchEvent(access, calendar, link.eventId, {
            ...spec,
            // A removed colour or length must be cleared, which a patch only does when told.
            if (!spec.containsKey('colorId')) 'colorId': null,
          });
          final next = link.copyWith(spec: spec, specHash: hash);
          links[taskId] = next;
          store.saveGoogleEvent(userId, next);
          report.updated++;
          continue;
        } on GoogleApiError catch (e) {
          if (e.status != 404 && e.status != 410) rethrow; // the event vanished: make it again below
        }
      }
      final made = await api.insertEvent(access, calendar, body);
      final next = GoogleEventLink(taskId: taskId, eventId: made['id'] as String, specHash: hash, spec: spec);
      links[taskId] = next;
      store.saveGoogleEvent(userId, next);
      report.created++;
    }

    // 3. Remove events whose task is done, deleted or no longer has a date.
    for (final taskId in links.keys.toList()) {
      if (want.containsKey(taskId)) continue;
      final link = links[taskId]!;
      if (link.state == 'linked') await api.deleteEvent(access, calendar, link.eventId);
      store.deleteGoogleEvent(userId, taskId);
      links.remove(taskId);
      report.deleted++;
    }
  }

  /// Syncs every connected person (the scheduler calls this).
  Future<void> syncAll() async {
    for (final u in store.googleUsers()) {
      await syncUser(u);
    }
  }
}
