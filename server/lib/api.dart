/// The HTTP API (SRS 6.4). Every route except `/health` and `/v1/pair`
/// needs a device token; the user is always taken from that token.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:taskflow_core/sharing.dart';
import 'package:taskflow_core/sync.dart';

import 'blobs.dart';
import 'shares.dart';
import 'google_api.dart';
import 'google_sync.dart';
import 'hooks.dart';
import 'ical.dart';
import 'model.dart';
import 'rest.dart';
import 'web.dart';
import 'limits.dart';
import 'store.dart';

typedef LogSink = void Function(String line);

class ApiConfig {
  const ApiConfig({
    this.trustProxy = false,
    this.maxBodyBytes = 2 * 1024 * 1024,
    this.syncPerMinute = 120,
    this.pairPerMinute = 20,
    this.blobsPerMinute = 600,
    this.apiPerMinute = 300,
    this.inboundPerMinute = 60,
    this.feedPerMinute = 30,
    this.allowPrivateWebhooks = false,
    this.webClient = true,
  });

  /// Read the caller's address from X-Forwarded-For. Only turn on behind a
  /// reverse proxy you control (Caddy), otherwise anyone can fake it.
  final bool trustProxy;
  final int maxBodyBytes;
  final int syncPerMinute;
  final int pairPerMinute;
  final int blobsPerMinute;
  final int apiPerMinute;
  final int inboundPerMinute;
  final int feedPerMinute;

  /// Let webhooks call addresses on the server's own network (off by default: see hooks.dart).
  final bool allowPrivateWebhooks;

  /// Serve the web client at `/app` and allow signing in from a browser. Switch off with `--no-web`.
  final bool webClient;
}

class _HttpError implements Exception {
  _HttpError(this.status, this.code, this.message, {this.headers = const {}});
  final int status;
  final String code;
  final String message;
  final Map<String, String> headers;
}

Response _json(int status, Object? body, {Map<String, String> headers = const {}}) => Response(
      status,
      body: body == null ? null : jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8', ...headers},
    );

Response _error(_HttpError e) => _json(e.status, {'error': e.code, 'message': e.message}, headers: e.headers);

const confirmPhrase = 'DELETE MY DATA';

/// Text that came from outside, made safe to show on a plain page.
String _safe(String s) {
  final clean = s.replaceAll(RegExp(r'[<>&"\x27]'), '');
  return clean.length > 200 ? clean.substring(0, 200) : clean;
}

Handler buildApi(
  Store store, {
  ApiConfig config = const ApiConfig(),
  LogSink? log,
  RateLimiter? limiter,
  FailureLockout? lockout,
  BlobStore? blobs,
  GoogleApi? google,
  GoogleSyncer? googleSync,
  DateTime Function()? clock,
}) {
  final now = clock ?? DateTime.now;
  final limits = limiter ?? RateLimiter(clock: now);
  final locks = lockout ?? FailureLockout(clock: now);
  final router = Router();

  String clientIp(Request r) {
    if (config.trustProxy) {
      final fwd = r.headers['x-forwarded-for'];
      if (fwd != null && fwd.isNotEmpty) return fwd.split(',').first.trim();
    }
    final info = r.context['shelf.io.connection_info'];
    return info is HttpConnectionInfo ? info.remoteAddress.address : 'unknown';
  }

  Future<Object?> readJson(Request r) async {
    final type = r.mimeType;
    if (type != 'application/json') throw _HttpError(415, 'unsupported_media_type', 'Send application/json');
    final declared = r.contentLength;
    if (declared != null && declared > config.maxBodyBytes) throw _HttpError(413, 'too_large', 'The request is too large');
    final chunks = <int>[];
    await for (final part in r.read()) {
      chunks.addAll(part);
      if (chunks.length > config.maxBodyBytes) throw _HttpError(413, 'too_large', 'The request is too large');
    }
    try {
      return jsonDecode(utf8.decode(chunks));
    } on FormatException {
      throw _HttpError(400, 'bad_json', 'The body is not valid JSON');
    }
  }

  DeviceInfo authenticate(Request r) {
    final header = r.headers['authorization'] ?? '';
    final match = RegExp(r'^Bearer ([A-Za-z0-9_-]{20,100})$').firstMatch(header);
    final device = match == null ? null : store.authenticate(match.group(1)!);
    if (device == null) throw _HttpError(401, 'unauthorized', 'This device is not signed in or was removed');
    if (!limits.allow('dev:${device.id}', limit: config.syncPerMinute, window: const Duration(minutes: 1))) {
      throw _HttpError(429, 'slow_down', 'Too many requests', headers: {'retry-after': '30'});
    }
    final who = r.context['who'];
    if (who is Map) who['device'] = device; // for the access log
    return device;
  }

  Handler authed(Future<Response> Function(Request, DeviceInfo) handler) => (Request request) async {
        final device = authenticate(request);
        return handler(request, device);
      };

  router.get('/health', (Request r) => _json(200, {'ok': true}));

  // --- pairing (SEC-2, SEC-8) ---------------------------------------------------

  router.post('/v1/pair', (Request r) async {
    final ip = clientIp(r);
    if (locks.isLocked('pair:$ip') ||
        !limits.allow('pairip:$ip', limit: config.pairPerMinute, window: const Duration(minutes: 1))) {
      throw _HttpError(429, 'locked', 'Too many attempts. Wait 15 minutes and try again.', headers: {'retry-after': '900'});
    }
    final body = await readJson(r);
    if (body is! Map || body['code'] is! String) throw _HttpError(400, 'bad_request', 'Send {"code": "...", "deviceName": "..."}');
    final name = body['deviceName'] is String ? body['deviceName'] as String : 'Device';
    final result = store.redeemInvite(body['code'] as String, name);
    if (result == null) {
      locks.recordFailure('pair:$ip');
      throw _HttpError(401, 'bad_code', 'That code is wrong, already used, or has expired');
    }
    locks.reset('pair:$ip');
    return _json(200, {'token': result.token, 'deviceId': result.deviceId, 'userName': result.userName, 'userId': result.userId});
  });

  // --- the web client (online only): a page, and a sign-in that gives it an API token -----------

  if (config.webClient) {
    router.get('/', (Request r) => Response.found('/app'));
    router.get('/app', (Request r) => webIndexResponse());
    router.get('/app/', (Request r) => webIndexResponse());
    router.get('/app/assets/<file>', (Request r, String file) => webAssetResponse(file));

    router.post('/web/login', (Request r) async {
      final ip = clientIp(r);
      if (locks.isLocked('pair:$ip') ||
          !limits.allow('pairip:$ip', limit: config.pairPerMinute, window: const Duration(minutes: 1))) {
        throw _HttpError(429, 'locked', 'Too many attempts. Wait 15 minutes and try again.', headers: {'retry-after': '900'});
      }
      final body = await readJson(r);
      if (body is! Map || body['code'] is! String) throw _HttpError(400, 'bad_request', 'Send {"code": "..."}');
      final name = body['name'] is String ? body['name'] as String : 'Web browser';
      final result = store.redeemInviteForApiToken(body['code'] as String, name.startsWith('Web browser') ? name : 'Web browser $name');
      if (result == null) {
        locks.recordFailure('pair:$ip');
        throw _HttpError(401, 'bad_code', 'That code is wrong, already used, or has expired');
      }
      locks.reset('pair:$ip');
      return _json(200, {'token': result.token, 'tokenId': result.tokenId, 'userName': result.userName});
    });
  }

  // --- sync ---------------------------------------------------------------------

  router.post('/v1/sync', authed((r, device) async {
    final SyncRequest req;
    try {
      req = SyncRequest.fromJson(await readJson(r));
    } on SyncFormatException catch (e) {
      throw _HttpError(400, 'bad_request', e.message);
    }
    store.applyChangesDetailed(device.userId, device.id, req.changes);
    final page = store.changesSince(device.userId, device.id, req.cursor, limit: req.limit);
    return _json(200, SyncResponse(cursor: page.cursor, changes: page.changes, more: page.more, shares: [for (final s in store.shares.infoFor(device.userId)) s.toJson()]).toJson());
  }));

  // --- the person and their devices ------------------------------------------------

  router.get('/v1/me', authed((r, device) async {
    final user = store.listUsers().firstWhere((u) => u.id == device.userId);
    return _json(200, {
      'user': {'name': user.name, 'id': user.id},
      'device': {'id': device.id, 'name': device.name},
      if (blobs != null) 'storage': {'usedBytes': blobs.usedBytes(device.userId), 'quotaBytes': blobs.quotaBytes, 'maxFileBytes': blobs.maxBytes},
      'devices': [
        for (final d in store.listDevices(device.userId))
          {
            'id': d.id,
            'name': d.name,
            'createdAt': d.createdAt,
            'lastSeen': d.lastSeen,
            'current': d.id == device.id,
            'revoked': d.revoked,
          },
      ],
    });
  }));

  // --- attachment files ---------------------------------------------------------------

  BlobStore needBlobs() => blobs ?? (throw _HttpError(501, 'no_storage', 'This server is not set up to store files'));

  String blobHash(Request r) {
    final hash = r.params['hash'] ?? '';
    if (!isBlobHash(hash)) throw _HttpError(400, 'bad_hash', 'The name of a file is its SHA-256 in lower-case hex');
    return hash;
  }

  router.put('/v1/blobs/<hash>', authed((r, device) async {
    final store = needBlobs();
    final hash = blobHash(r);
    final declared = r.contentLength;
    if (declared != null && declared > store.maxBytes) throw _HttpError(413, 'too_large', 'Files are limited to ${store.maxBytes ~/ (1024 * 1024)} MB');
    if (!limits.allow('blob:${device.id}', limit: config.blobsPerMinute, window: const Duration(minutes: 1))) {
      throw _HttpError(429, 'slow_down', 'Too many requests', headers: {'retry-after': '30'});
    }
    try {
      final size = await store.put(device.userId, hash, r.read());
      return _json(201, {'size': size});
    } on BlobTooLarge catch (e) {
      throw _HttpError(413, 'too_large', 'Files are limited to ${e.limit ~/ (1024 * 1024)} MB');
    } on BlobQuotaExceeded {
      throw _HttpError(507, 'storage_full', 'Your storage on this server is full');
    } on BlobHashMismatch {
      throw _HttpError(422, 'hash_mismatch', 'The file does not match its name');
    }
  }));

  router.get('/v1/blobs/<hash>', authed((r, device) async {
    final file = needBlobs().open(device.userId, blobHash(r));
    if (file == null) throw _HttpError(404, 'not_found', 'No such file');
    return Response.ok(file.openRead(), headers: {'content-type': 'application/octet-stream', 'content-length': '${file.lengthSync()}'});
  }));

  router.add('HEAD', '/v1/blobs/<hash>', authed((r, device) async {
    final size = needBlobs().size(device.userId, blobHash(r));
    if (size == null) return Response(404);
    return Response.ok(null, headers: {'content-length': '$size'});
  }));

  // --- shared projects (family sharing) ---------------------------------------------------------------

  T shareCall<T>(T Function() f) {
    try {
      return f();
    } on ShareError catch (e) {
      throw _HttpError(e.status, e.status == 404 ? 'not_found' : (e.status == 403 ? 'forbidden' : 'bad_request'), e.message);
    }
  }

  router.get('/v1/shares', authed((r, device) async => _json(200, {'shares': [for (final s in store.shares.infoFor(device.userId)) s.toJson()]})));

  router.post('/v1/projects/<id>/invites', authed((r, device) async {
    final body = await readJson(r);
    final role = body is Map ? ShareRole.parse(body['role'] as String?) : null;
    if (role == null || role == ShareRole.owner) throw _HttpError(400, 'bad_request', 'Send {"role": "admin" | "member" | "viewer"}');
    final code = shareCall(() => store.transaction(() => store.shares.createInvite(device.userId, r.params['id'] ?? '', role)));
    return _json(201, {'code': formatPairingCode(code), 'expiresInHours': Shares.inviteTtl.inHours, 'role': role.name});
  }));

  router.post('/v1/invites/redeem', authed((r, device) async {
    final key = 'redeem:${device.userId}';
    if (locks.isLocked(key)) throw _HttpError(429, 'locked', 'Too many wrong codes. Wait 15 minutes and try again.', headers: {'retry-after': '900'});
    final body = await readJson(r);
    if (body is! Map || body['code'] is! String) throw _HttpError(400, 'bad_request', 'Send {"code": "XXXX-XXXX"}');
    final joined = shareCall(() => store.transaction(() => store.shares.redeemInvite(device.userId, body['code'] as String)));
    if (joined == null) {
      locks.recordFailure(key);
      throw _HttpError(401, 'bad_code', 'That code is wrong, already used, or has expired');
    }
    locks.reset(key);
    return _json(200, {'projectId': joined.projectId, 'role': joined.role.name});
  }));

  router.post('/v1/projects/<id>/members/<user>', authed((r, device) async {
    final body = await readJson(r);
    final role = body is Map ? ShareRole.parse(body['role'] as String?) : null;
    if (role == null || role == ShareRole.owner) throw _HttpError(400, 'bad_request', 'Send {"role": "admin" | "member" | "viewer"}');
    shareCall(() => store.transaction(() => store.shares.setRole(device.userId, r.params['id'] ?? '', r.params['user'] == 'me' ? device.userId : (r.params['user'] ?? ''), role)));
    return Response(204);
  }));

  router.delete('/v1/projects/<id>/members/<user>', authed((r, device) async {
    final target = r.params['user'] == 'me' ? device.userId : (r.params['user'] ?? '');
    shareCall(() => store.transaction(() => store.shares.removeMember(device.userId, r.params['id'] ?? '', target)));
    return Response(204);
  }));

  router.delete('/v1/projects/<id>/share', authed((r, device) async {
    shareCall(() => store.transaction(() => store.shares.stopSharing(device.userId, r.params['id'] ?? '')));
    return Response(204);
  }));

  // --- tokens, webhooks and the calendar link, managed from a signed-in device ---------------------

  router.get('/v1/api-tokens', authed((r, device) async => _json(200, {'tokens': store.listApiTokens(device.userId)})));

  router.post('/v1/api-tokens', authed((r, device) async {
    final body = await readJson(r);
    if (body is! Map || body['name'] is! String) throw _HttpError(400, 'bad_request', 'Send {"name": "...", "readOnly": false}');
    try {
      final t = store.createApiToken(device.userId, body['name'] as String, readOnly: body['readOnly'] == true);
      return _json(201, {'id': t.id, 'token': t.token, 'note': 'This is the only time the token is shown.'});
    } on ArgumentError catch (e) {
      throw _HttpError(400, 'bad_request', '${e.message}');
    }
  }));

  router.delete('/v1/api-tokens/<id>', authed((r, device) async {
    if (!store.revokeApiToken(device.userId, r.params['id'] ?? '')) throw _HttpError(404, 'not_found', 'No such token');
    return Response(204);
  }));

  router.get('/v1/webhooks', authed((r, device) async => _json(200, {'webhooks': store.listWebhooks(device.userId)})));

  router.post('/v1/webhooks', authed((r, device) async {
    final body = await readJson(r);
    if (body is! Map || body['url'] is! String) throw _HttpError(400, 'bad_request', 'Send {"url": "https://...", "events": ["task.completed"]}');
    final why = await checkWebhookUrl(body['url'] as String, allowPrivate: config.allowPrivateWebhooks);
    if (why != null) throw _HttpError(400, 'bad_url', why);
    final events = body['events'];
    final list = events is List ? events.whereType<String>().toList() : <String>['*'];
    const known = {'*', 'task.added', 'task.updated', 'task.completed', 'task.uncompleted', 'task.deleted', 'project.added', 'project.updated', 'project.deleted', 'comment.added'};
    if (list.isEmpty || list.any((e) => !known.contains(e))) throw _HttpError(400, 'bad_events', 'Events are: ${known.where((e) => e != '*').join(', ')} (or "*" for all)');
    try {
      final w = store.createWebhook(device.userId, body['url'] as String, events: list.join(','));
      return _json(201, {'id': w.id, 'secret': w.secret, 'note': 'This is the only time the secret is shown. Calls are signed with it (see the docs).'});
    } on ArgumentError catch (e) {
      throw _HttpError(400, 'bad_request', '${e.message}');
    }
  }));

  router.delete('/v1/webhooks/<id>', authed((r, device) async {
    if (!store.deleteWebhook(device.userId, r.params['id'] ?? '')) throw _HttpError(404, 'not_found', 'No such webhook');
    return Response(204);
  }));

  router.post('/v1/webhooks/<id>/reactivate', authed((r, device) async {
    if (!store.reactivateWebhook(device.userId, r.params['id'] ?? '')) throw _HttpError(404, 'not_found', 'No such webhook');
    return Response(204);
  }));

  router.get('/v1/inbound-hooks', authed((r, device) async => _json(200, {'hooks': store.listInboundHooks(device.userId)})));

  router.post('/v1/inbound-hooks', authed((r, device) async {
    final body = await readJson(r);
    if (body is! Map || body['name'] is! String) throw _HttpError(400, 'bad_request', 'Send {"name": "...", "projectId": "inbox"}');
    try {
      final h = store.createInboundHook(device.userId, body['name'] as String, projectId: (body['projectId'] as String?) ?? 'inbox');
      return _json(201, {'id': h.id, 'secret': h.secret, 'path': '/hooks/in/${h.id}', 'note': 'This is the only time the secret is shown.'});
    } on ArgumentError catch (e) {
      throw _HttpError(400, 'bad_request', '${e.message}');
    }
  }));

  router.delete('/v1/inbound-hooks/<id>', authed((r, device) async {
    if (!store.deleteInboundHook(device.userId, r.params['id'] ?? '')) throw _HttpError(404, 'not_found', 'No such hook');
    return Response(204);
  }));

  router.get('/v1/calendar', authed((r, device) async => _json(200, {'enabled': store.hasCalendarFeed(device.userId)})));

  router.post('/v1/calendar', authed((r, device) async {
    // Making a new link replaces the old one, so a link that leaked can be cut off.
    final token = store.createCalendarToken(device.userId);
    return _json(201, {'path': '/ical/$token.ics', 'note': 'Add this address to your calendar app. Anyone who has it can read your dated tasks.'});
  }));

  router.delete('/v1/calendar', authed((r, device) async {
    store.deleteCalendarFeed(device.userId);
    return Response(204);
  }));

  // --- Google Calendar -------------------------------------------------------------------------------

  GoogleApi needGoogle() => google ?? (throw _HttpError(501, 'not_configured', 'Google Calendar is not set up on this server. See the server README.'));

  router.get('/v1/google', authed((r, device) async {
    final a = store.googleAccount(device.userId);
    return _json(200, {
      'configured': google != null,
      'connected': a != null,
      if (a != null) ...{
        'calendarReady': a.calendarId != null,
        'timeZone': a.timeZone,
        'lastSync': a.lastSync,
        'lastError': a.lastError,
        'needsReconnect': a.needsReconnect,
      },
    });
  }));

  router.post('/v1/google/connect', authed((r, device) async {
    final g = needGoogle();
    final body = await readJson(r);
    final tz = body is Map && body['timeZone'] is String ? body['timeZone'] as String : 'UTC';
    if (!RegExp(r'^[A-Za-z0-9_+\-/]{1,64}$').hasMatch(tz)) throw _HttpError(400, 'bad_time_zone', 'Send a time zone name such as Asia/Riyadh');
    final state = store.createGoogleState(device.userId, tz);
    return _json(200, {'url': g.authUrl(state).toString()});
  }));

  // Google sends the person's browser back here. There is no sign-in on this route: the one-time
  // state value made for the signed-in device is what says who this is.
  router.get('/google/callback', (Request r) async {
    Response html(int status, String title, String text) => Response(status,
        body: '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>$title</title><h1>$title</h1><p>$text</p>',
        headers: {'content-type': 'text/html; charset=utf-8'});
    final g = needGoogle();
    final q = r.url.queryParameters;
    if (q['error'] != null) return html(400, 'Not connected', 'Google Calendar was not connected (${_safe(q['error']!)}). Go back to TaskFlow and try again.');
    final state = store.consumeGoogleState(q['state'] ?? '');
    final code = q['code'];
    if (state == null || code == null || code.length > 2000) return html(400, 'This link has expired', 'Go back to TaskFlow and choose Connect Google Calendar again.');
    try {
      final tokens = await g.exchangeCode(code);
      final refresh = tokens.refreshToken;
      if (refresh == null) {
        return html(400, 'Google did not give long-term access', 'Open myaccount.google.com/permissions, remove TaskFlow, then connect again.');
      }
      store.saveGoogleAccount(state.userId, refresh, state.timeZone);
    } on GoogleApiError catch (e) {
      return html(502, 'Could not connect', 'Google refused the request: ${_safe(e.message)}');
    } on GoogleAuthError catch (e) {
      return html(400, 'Could not connect', 'Google refused the request: ${_safe(e.message)}');
    }
    final syncer = googleSync;
    syncer?.syncInBackground(state.userId);
    return html(200, 'Google Calendar is connected', 'Your tasks with dates are being added to a calendar called TaskFlow. You can close this tab and go back to the app.');
  });

  router.post('/v1/google/sync', authed((r, device) async {
    final syncer = googleSync ?? (throw _HttpError(501, 'not_configured', 'Google Calendar is not set up on this server'));
    if (store.googleAccount(device.userId) == null) throw _HttpError(409, 'not_connected', 'Google Calendar is not connected');
    if (!limits.allow('gsync:${device.userId}', limit: 10, window: const Duration(minutes: 1))) {
      throw _HttpError(429, 'slow_down', 'Too many requests', headers: {'retry-after': '30'});
    }
    final report = await syncer.syncUser(device.userId);
    return _json(200, {'created': report.created, 'updated': report.updated, 'deleted': report.deleted, 'moved': report.pulled, 'error': report.error, 'needsReconnect': report.needsReconnect});
  }));

  router.post('/v1/google/time-zone', authed((r, device) async {
    final body = await readJson(r);
    final tz = body is Map ? body['timeZone'] : null;
    if (tz is! String || !RegExp(r'^[A-Za-z0-9_+\-/]{1,64}$').hasMatch(tz)) throw _HttpError(400, 'bad_time_zone', 'Send {"timeZone": "Asia/Riyadh"}');
    if (store.googleAccount(device.userId) == null) throw _HttpError(409, 'not_connected', 'Google Calendar is not connected');
    store.setGoogleTimeZone(device.userId, tz);
    return Response(204);
  }));

  router.post('/v1/google/disconnect', authed((r, device) async {
    final account = store.googleAccount(device.userId);
    if (account == null) return Response(204);
    final body = await readJson(r);
    final removeCalendar = body is Map && body['deleteCalendar'] == true;
    final g = google;
    if (g != null) {
      try {
        if (removeCalendar && account.calendarId != null) {
          await g.deleteCalendar(await g.accessToken(account.refreshToken), account.calendarId!);
        }
      } catch (_) {
        // If Google cannot be reached the calendar stays; the connection is removed all the same.
      }
      await g.revoke(account.refreshToken);
    }
    store.deleteGoogleAccount(device.userId);
    return Response(204);
  }));

  // --- the incoming webhook: another system adds a task (FR-I3) -------------------------------

  final seenSignatures = <String, DateTime>{};

  router.post('/hooks/in/<id>', (Request r) async {
    final ip = clientIp(r);
    if (!limits.allow('hookip:$ip', limit: config.inboundPerMinute, window: const Duration(minutes: 1))) {
      throw _HttpError(429, 'slow_down', 'Too many requests', headers: {'retry-after': '30'});
    }
    final hook = store.inboundHook(r.params['id'] ?? '');
    // The same answer for "no such hook" and "wrong signature", so ids cannot be probed.
    if (hook == null) throw _HttpError(401, 'bad_signature', 'The signature does not match');
    final declared = r.contentLength;
    if (declared != null && declared > 16 * 1024) throw _HttpError(413, 'too_large', 'The request is too large');
    final bytes = <int>[];
    await for (final part in r.read()) {
      bytes.addAll(part);
      if (bytes.length > 16 * 1024) throw _HttpError(413, 'too_large', 'The request is too large');
    }
    final raw = utf8.decode(bytes, allowMalformed: true);
    final why = verifySignedCall(secret: hook.secret, timestamp: r.headers['x-taskflow-timestamp'], signature: r.headers['x-taskflow-signature'], body: raw, now: now());
    if (why != null) throw _HttpError(401, 'bad_signature', why);
    // A signed call can be used once: replaying a captured one adds nothing.
    seenSignatures.removeWhere((_, at) => now().difference(at) > maxTimestampSkew * 2);
    final sig = r.headers['x-taskflow-signature']!.toLowerCase();
    if (seenSignatures.containsKey(sig)) throw _HttpError(409, 'replayed', 'This call was already received');
    seenSignatures[sig] = now();

    var text = raw;
    var offset = int.tryParse(r.headers['x-taskflow-utc-offset-minutes'] ?? '') ?? 0;
    if (r.mimeType == 'application/json') {
      try {
        final j = jsonDecode(raw);
        if (j is! Map || j['text'] is! String) throw const FormatException();
        text = j['text'] as String;
        if (j['utc_offset_minutes'] is int) offset = j['utc_offset_minutes'] as int;
      } on FormatException {
        throw _HttpError(400, 'bad_request', 'Send {"text": "Buy milk tomorrow p1"} or plain text');
      }
    }
    if (offset < -14 * 60 || offset > 14 * 60) offset = 0;
    final local = now().toUtc().add(Duration(minutes: offset));
    try {
      final task = UserModel(store, hook.userId, source: 'hook:${r.params['id']}')
          .taskFromText(text, projectId: hook.projectId, today: DateTime(local.year, local.month, local.day, local.hour, local.minute));
      return _json(201, task);
    } on ModelError catch (e) {
      throw _HttpError(e.status, 'bad_request', e.message);
    }
  });

  // --- the calendar feed: read-only, by secret address ------------------------------------------

  router.get('/ical/<file>', (Request r) {
    final ip = clientIp(r);
    if (!limits.allow('feed:$ip', limit: config.feedPerMinute, window: const Duration(minutes: 1))) {
      throw _HttpError(429, 'slow_down', 'Too many requests', headers: {'retry-after': '60'});
    }
    final file = r.params['file'] ?? '';
    final user = file.endsWith('.ics') ? store.userForCalendarToken(file.substring(0, file.length - 4)) : null;
    if (user == null) throw _HttpError(404, 'not_found', 'No such calendar');
    return Response.ok(buildCalendar(UserModel(store, user)), headers: {'content-type': 'text/calendar; charset=utf-8', 'cache-control': 'private, max-age=300'});
  });

  // --- the REST API for scripts (FR-I4) ----------------------------------------------------------------

  registerRest(
    router,
    RestContext(
      store: store,
      readJson: readJson,
      json: _json,
      error: (status, code, message) => _error(_HttpError(status, code, message)),
      authenticate: (Request r) {
        final header = r.headers['authorization'] ?? '';
        final match = RegExp(r'^Bearer (tf_[A-Za-z0-9_-]{20,100})$').firstMatch(header);
        final t = match == null ? null : store.authenticateApiToken(match.group(1)!);
        if (t == null) throw RestRefusal(401, 'unauthorized', 'Send an API token: Authorization: Bearer tf_...');
        if (!limits.allow('api:${t.tokenId}', limit: config.apiPerMinute, window: const Duration(minutes: 1))) {
          throw RestRefusal(429, 'slow_down', 'Too many requests', headers: {'retry-after': '30'});
        }
        final who = r.context['who'];
        if (who is Map) who['device'] = DeviceInfo(id: t.tokenId.padRight(8, '0'), userId: t.userId, name: 'api', createdAt: 0);
        return RestAuth(t.userId, t.tokenId, t.readOnly);
      },
    ),
  );

  router.delete('/v1/devices/<id>', authed((r, device) async {
    final id = r.params['id'] ?? '';
    // Only the signed-in person's own devices can be revoked (SEC-4, SEC-5).
    if (!store.revokeDevice(device.userId, id)) throw _HttpError(404, 'not_found', 'No such device');
    return Response(204);
  }));

  router.get('/v1/export', authed((r, device) async {
    final all = store.exportAll(device.userId);
    return _json(200, {'fields': [for (final c in all) c.toJson()]});
  }));

  router.post('/v1/me/delete', authed((r, device) async {
    final body = await readJson(r);
    if (body is! Map || body['confirm'] != confirmPhrase) {
      throw _HttpError(400, 'confirm_required', 'Send {"confirm": "$confirmPhrase"}');
    }
    store.deleteUser(device.userId);
    blobs?.deleteUser(device.userId);
    return Response(204);
  }));

  router.all('/<ignored|.*>', (Request r) => _json(404, {'error': 'not_found', 'message': 'No such route'}));

  // --- middleware ---------------------------------------------------------------------

  Middleware errors() => (inner) => (request) async {
        try {
          return await inner(request);
        } on _HttpError catch (e) {
          return _error(e);
        } catch (e, st) {
          // The caller learns nothing; the owner's log gets the reason (no request data).
          final where = st.toString().split('\n').take(6).join(' | ');
          log?.call('${now().toUtc().toIso8601String()} internal error on ${request.method} /${request.url.path}: ${e.runtimeType}: $e [$where]');
          return _json(500, {'error': 'server_error', 'message': 'Something went wrong on the server'});
        }
      };

  Middleware headers() => (inner) => (request) async {
        final response = await inner(request);
        return response.change(headers: {
          'strict-transport-security': 'max-age=31536000',
          'x-content-type-options': 'nosniff',
          // The web page brings its own policy and caching (its files are named by content); everything else gets the strictest.
          if (!response.headers.containsKey('cache-control')) 'cache-control': 'no-store',
          if (!response.headers.containsKey('content-security-policy')) 'content-security-policy': "default-src 'none'",
          'referrer-policy': 'no-referrer',
        });
      };

  // The access log records who, what and when, never bodies, headers or tokens (SEC-12).
  Middleware access() => (inner) => (request) async {
        final started = now();
        final holder = <String, Object?>{};
        final response = await inner(request.change(context: {'who': holder}));
        final ctx = holder['device'];
        final who = ctx is DeviceInfo ? 'user=${ctx.userId.substring(0, 8)} device=${ctx.id.substring(0, 8)}' : 'user=- device=-';
        final ms = now().difference(started).inMilliseconds;
        log?.call('${now().toUtc().toIso8601String()} $who ${request.method} /${request.url.path} ${response.statusCode} ${ms}ms ip=${clientIp(request)}');
        return response;
      };

  return const Pipeline().addMiddleware(access()).addMiddleware(headers()).addMiddleware(errors()).addHandler(router.call);
}
