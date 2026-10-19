/// Webhooks: calls the server makes when tasks change (FR-I5), and the signed
/// call that lets another system add a task (FR-I3).
///
/// Every outgoing call is signed. The receiver recomputes
/// `HMAC-SHA256(secret, "<timestamp>.<body>")` and compares it to the
/// `X-TaskFlow-Signature` header (`sha256=<hex>`), and rejects calls whose
/// `X-TaskFlow-Timestamp` is more than five minutes old. Incoming calls are
/// checked the same way.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:taskflow_core/sync.dart';

import 'model.dart';
import 'store.dart';

const maxTimestampSkew = Duration(minutes: 5);

String signPayload(String secret, int timestamp, String body) =>
    'sha256=${Hmac(sha256, utf8.encode(secret)).convert(utf8.encode('$timestamp.$body')).toString()}';

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Checks a signed incoming call. Returns null if it is good, else why not.
String? verifySignedCall({required String secret, required String? timestamp, required String? signature, required String body, required DateTime now}) {
  final ts = int.tryParse(timestamp ?? '');
  if (ts == null) return 'Send X-TaskFlow-Timestamp (seconds since 1970)';
  final skew = now.difference(DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true)).abs();
  if (skew > maxTimestampSkew) return 'The timestamp is too old or too new';
  if (signature == null || !constantTimeEquals(signature.toLowerCase(), signPayload(secret, ts, body))) return 'The signature does not match';
  return null;
}

bool isPrivateAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
  final raw = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    final b = raw;
    if (b[0] == 10 || b[0] == 0) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 169 && b[1] == 254) return true;
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true; // carrier-grade NAT, Tailscale
    return false;
  }
  if (raw.length == 16) {
    if ((raw[0] & 0xfe) == 0xfc) return true; // unique local fc00::/7
    final v4mapped = raw.sublist(0, 10).every((x) => x == 0) && raw[10] == 0xff && raw[11] == 0xff;
    if (v4mapped) return isPrivateAddress(InternetAddress.fromRawAddress(raw.sublist(12)));
  }
  return false;
}

/// Why [url] may not be used as a webhook address, or null if it may. Calls to
/// the server's own network are refused unless [allowPrivate], so a webhook
/// cannot be used to probe machines behind the firewall.
Future<String?> checkWebhookUrl(String url, {required bool allowPrivate, Future<List<InternetAddress>> Function(String host)? lookup}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return 'That is not a web address';
  if (uri.scheme != 'https' && !(allowPrivate && uri.scheme == 'http')) return 'Webhook addresses must start with https://';
  if (uri.userInfo.isNotEmpty) return 'Do not put a name and password in the address';
  if (url.length > 500) return 'That address is too long';
  if (allowPrivate) return null;
  try {
    final addresses = await (lookup ?? (h) => InternetAddress.lookup(h))(uri.host);
    if (addresses.isEmpty) return 'That address could not be found';
    if (addresses.any(isPrivateAddress)) return 'That address points inside a private network, which is not allowed';
  } on SocketException {
    return 'That address could not be found';
  }
  return null;
}

/// Turns a batch of applied changes into events and sends them to the owner's webhooks.
class WebhookDispatcher {
  WebhookDispatcher(
    this.store, {
    this.allowPrivate = false,
    this.timeout = const Duration(seconds: 5),
    this.retryDelays = const [Duration.zero, Duration(seconds: 2), Duration(seconds: 10)],
    this.lookup,
    this.log,
  });

  final Store store;
  final bool allowPrivate;
  final Duration timeout;
  final List<Duration> retryDelays;
  final Future<List<InternetAddress>> Function(String host)? lookup;
  final void Function(String line)? log;

  final _pending = <Future<void>>[];

  /// Completes when every delivery started so far has finished (for tests and shutdown).
  Future<void> flush() async {
    while (_pending.isNotEmpty) {
      await Future.wait(List.of(_pending));
    }
  }

  /// Derives events from [changes] (already applied for [userId]) and sends them.
  void onChanges(String userId, List<SyncChange> changes) {
    if (changes.isEmpty) return;
    final byRow = <String, List<SyncChange>>{};
    for (final c in changes) {
      if (c.table == 'tasks' || c.table == 'projects' || c.table == 'comments') {
        byRow.putIfAbsent('${c.table}/${c.row}', () => []).add(c);
      }
    }
    if (byRow.isEmpty) return;
    final model = UserModel(store, userId);
    final events = <(String, Map<String, Object?>)>[];
    for (final cs in byRow.values) {
      final table = cs.first.table, row = cs.first.row;
      final noun = switch (table) { 'tasks' => 'task', 'projects' => 'project', _ => 'comment' };
      final added = cs.any((c) => c.col == presentColumn && c.value == true);
      final removed = cs.any((c) => c.col == presentColumn && c.value == false) || cs.any((c) => c.col == 'deleted_at' && c.value != null);
      final completed = cs.any((c) => c.col == 'completed_at' && c.value != null);
      final reopened = cs.any((c) => c.col == 'completed_at' && c.value == null);
      final String kind;
      if (added) {
        kind = 'added';
      } else if (removed) {
        kind = 'deleted';
      } else if (table == 'tasks' && completed) {
        kind = 'completed';
      } else if (table == 'tasks' && reopened) {
        kind = 'uncompleted';
      } else if (table == 'comments') {
        continue; // an edited comment is not an event worth sending
      } else {
        kind = 'updated';
      }
      final current = model.table(table)[row];
      final Map<String, Object?> data;
      if (current == null) {
        data = {'id': row};
      } else {
        data = switch (table) {
          'tasks' => model.taskView(row),
          'projects' => model.projectView(row),
          _ => {'id': row, 'task_id': current['task_id'], 'content': current['body']},
        };
      }
      events.add(('$noun.$kind', data));
    }
    for (final (event, data) in events) {
      for (final h in store.webhooksFor(userId, event)) {
        final body = jsonEncode({'event': event, 'time': store.now.toUtc().toIso8601String(), 'data': data});
        unawaited(_send(h.id, h.url, h.secret, event, body));
      }
    }
  }

  Future<void> _send(String id, String url, String secret, String event, String body) async {
    final self = Future<void>(() async {
      var status = 'not sent';
      var ok = false;
      for (var attempt = 0; attempt < retryDelays.length; attempt++) {
        if (retryDelays[attempt] > Duration.zero) await Future<void>.delayed(retryDelays[attempt]);
        final why = await checkWebhookUrl(url, allowPrivate: allowPrivate, lookup: lookup);
        if (why != null) {
          status = 'blocked: $why';
          break; // not worth retrying
        }
        final client = HttpClient()..connectionTimeout = timeout;
        try {
          final ts = store.now.millisecondsSinceEpoch ~/ 1000;
          final req = await client.postUrl(Uri.parse(url)).timeout(timeout);
          req.followRedirects = false; // a redirect could point somewhere that was never checked
          req.headers
            ..contentType = ContentType('application', 'json', charset: 'utf-8')
            ..set('x-taskflow-event', event)
            ..set('x-taskflow-timestamp', '$ts')
            ..set('x-taskflow-signature', signPayload(secret, ts, body))
            ..set('user-agent', 'TaskFlow-Webhook/1');
          req.write(body);
          final res = await req.close().timeout(timeout);
          await res.drain<void>().timeout(timeout);
          status = '${res.statusCode}';
          if (res.statusCode >= 200 && res.statusCode < 300) {
            ok = true;
            break;
          }
          if (res.statusCode >= 400 && res.statusCode < 500 && res.statusCode != 429) break; // the receiver refused it; retrying will not help
        } on Exception catch (e) {
          status = 'error: ${e.runtimeType}';
        } finally {
          client.close(force: true);
        }
      }
      try {
        store.recordWebhookResult(id, ok: ok, status: status);
      } catch (_) {
        // The webhook was deleted meanwhile.
      }
      log?.call('webhook $id $event -> $status');
    });
    _pending.add(self);
    try {
      await self;
    } finally {
      _pending.remove(self);
    }
  }
}
