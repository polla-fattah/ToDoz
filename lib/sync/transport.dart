import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:taskflow_core/sharing.dart';
import 'package:taskflow_core/sync.dart';

import 'sync_engine.dart';

/// Normalises what the owner typed: adds https:// if missing, drops a
/// trailing slash. Plain http is allowed only for local addresses.
Uri? parseServerUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty || (uri.scheme != 'https' && uri.scheme != 'http')) return null;
  if (uri.scheme == 'http' && !_isLocalHost(uri.host)) return null; // SEC-7: no cleartext over the internet
  return uri.replace(path: uri.path.replaceAll(RegExp(r'/+$'), ''));
}

/// Addresses that never cross the open internet: this machine, the emulator's
/// host alias, home/office ranges and Tailscale (whose tunnel is already encrypted).
bool _isLocalHost(String host) {
  if (host == 'localhost' || host == '127.0.0.1' || host == '10.0.2.2' || host.endsWith('.local') || host.endsWith('.ts.net')) return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final n = parts.map(int.tryParse).toList();
  if (n.any((x) => x == null || x < 0 || x > 255)) return false;
  return n[0] == 10 || (n[0] == 192 && n[1] == 168) || (n[0] == 172 && n[1]! >= 16 && n[1]! <= 31) || (n[0] == 100 && n[1]! >= 64 && n[1]! <= 127);
}

class PairingInfo {
  PairingInfo({required this.token, required this.deviceId, required this.userName, this.userId});
  final String? userId;
  final String token;
  final String deviceId;
  final String userName;
}

class DeviceEntry {
  DeviceEntry({required this.id, required this.name, required this.current, required this.revoked, this.lastSeen});
  final String id;
  final String name;
  final bool current;
  final bool revoked;
  final DateTime? lastSeen;
}

class GoogleStatus {
  GoogleStatus({required this.configured, required this.connected, this.calendarReady = false, this.timeZone, this.lastSync, this.lastError, this.needsReconnect = false});
  final bool configured;
  final bool connected;
  final bool calendarReady;
  final String? timeZone;
  final DateTime? lastSync;
  final String? lastError;
  final bool needsReconnect;

  factory GoogleStatus.fromJson(Map<String, Object?> j) => GoogleStatus(
        configured: j['configured'] == true,
        connected: j['connected'] == true,
        calendarReady: j['calendarReady'] == true,
        timeZone: j['timeZone'] as String?,
        lastSync: j['lastSync'] is int ? DateTime.fromMillisecondsSinceEpoch((j['lastSync']! as int) * 1000) : null,
        lastError: j['lastError'] as String?,
        needsReconnect: j['needsReconnect'] == true,
      );
}

class MeInfo {
  MeInfo({required this.userName, required this.devices, this.userId});
  final String? userId;
  final String userName;
  final List<DeviceEntry> devices;
}

/// Everything the app says to the server over HTTPS.
class ServerApi implements SyncTransport {
  ServerApi(this.baseUrl, {this.token, http.Client? client, this.timeout = const Duration(seconds: 30)}) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String? token;
  final http.Client _client;
  final Duration timeout;

  Uri _uri(String path) => baseUrl.replace(path: '${baseUrl.path}$path');

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<Map<String, Object?>> _send(String method, String path, {Object? body, Set<int> ok = const {200}}) async {
    final http.Response r;
    try {
      final request = http.Request(method, _uri(path))
        ..headers.addAll(_headers)
        ..body = body == null ? '' : jsonEncode(body);
      r = await http.Response.fromStream(await _client.send(request).timeout(timeout));
    } on TimeoutException {
      throw SyncTransportException('The server did not answer in time');
    } on Exception catch (e) {
      throw SyncTransportException('Could not reach the server: ${_short(e)}');
    }
    if (r.statusCode == 401 && token != null) {
      // "Signed out" only when the server says the token is bad. A wrong invitation code is also a 401.
      var code = '';
      try {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['error'] is String) code = j['error'] as String;
      } catch (_) {}
      if (code == '' || code == 'unauthorized') {
        throw SyncTransportException('This device was signed out by the server', unauthorized: true);
      }
    }
    if (!ok.contains(r.statusCode)) {
      var message = 'The server answered ${r.statusCode}';
      try {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['message'] is String) message = j['message'] as String;
      } catch (_) {}
      throw SyncTransportException(message);
    }
    if (r.bodyBytes.isEmpty) return {};
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    return j is Map<String, Object?> ? j : {};
  }

  String _short(Object e) => e.toString().replaceAll(RegExp(r'\s+'), ' ').split(',').first;

  /// Swaps a pairing code for a device token.
  Future<PairingInfo> pair(String code, String deviceName) async {
    final j = await _send('POST', '/v1/pair', body: {'code': code, 'deviceName': deviceName});
    return PairingInfo(token: j['token']! as String, deviceId: j['deviceId']! as String, userName: j['userName']! as String, userId: j['userId'] as String?);
  }

  @override
  Future<SyncResponse> sync(SyncRequest request) async {
    final j = await _send('POST', '/v1/sync', body: request.toJson());
    try {
      return SyncResponse.fromJson(j);
    } on SyncFormatException catch (e) {
      throw SyncTransportException('The server sent something unexpected: ${e.message}');
    }
  }

  Future<MeInfo> me() async {
    final j = await _send('GET', '/v1/me');
    return MeInfo(
      userName: (j['user']! as Map)['name']! as String,
      userId: (j['user']! as Map)['id'] as String?,
      devices: [
        for (final d in j['devices']! as List)
          DeviceEntry(
            id: d['id'] as String,
            name: d['name'] as String,
            current: d['current'] == true,
            revoked: d['revoked'] == true,
            lastSeen: d['lastSeen'] == null ? null : DateTime.fromMillisecondsSinceEpoch((d['lastSeen'] as int) * 1000),
          ),
      ],
    );
  }

  Future<void> revokeDevice(String id) => _send('DELETE', '/v1/devices/$id', ok: {204});

  /// Deletes the person and all their data on the server (SEC-17).
  Future<void> deleteAccount() => _send('POST', '/v1/me/delete', body: {'confirm': 'DELETE MY DATA'}, ok: {204});

  // --- shared projects ----------------------------------------------------------------------

  Future<List<ShareInfo>> listShares() async => [for (final s in (await _get('/v1/shares'))['shares']! as List) ?ShareInfo.fromJson(s)];

  /// An invitation code (XXXX-XXXX) for a project, valid for a day.
  Future<String> createInvite(String projectId, ShareRole role) async =>
      (await _send('POST', '/v1/projects/$projectId/invites', body: {'role': role.name}, ok: {201}))['code']! as String;

  /// Joins a shared project with a code; returns the project id.
  Future<String> redeemInvite(String code) async => (await _send('POST', '/v1/invites/redeem', body: {'code': code}))['projectId']! as String;

  Future<void> setMemberRole(String projectId, String userId, ShareRole role) =>
      _send('POST', '/v1/projects/$projectId/members/$userId', body: {'role': role.name}, ok: {204});

  /// Removes a member, or (with `me`) leaves the project.
  Future<void> removeMember(String projectId, String userId) => _send('DELETE', '/v1/projects/$projectId/members/$userId', ok: {204});

  Future<void> stopSharing(String projectId) => _send('DELETE', '/v1/projects/$projectId/share', ok: {204});

  // --- integrations: calendar, API tokens, webhooks ---------------------------------------

  Future<Map<String, Object?>> _get(String path) => _send('GET', path);

  /// The full address for a path the server returned (`/ical/...`).
  Uri addressOf(String path) => baseUrl.replace(path: '${baseUrl.path}$path');

  Future<bool> calendarFeedEnabled() async => (await _get('/v1/calendar'))['enabled'] == true;

  /// Makes (or replaces) the secret calendar feed address and returns it.
  Future<Uri> createCalendarFeed() async => addressOf((await _send('POST', '/v1/calendar', ok: {201}))['path']! as String);

  Future<void> deleteCalendarFeed() => _send('DELETE', '/v1/calendar', ok: {204});

  Future<GoogleStatus> googleStatus() async => GoogleStatus.fromJson(await _get('/v1/google'));

  /// The Google page the person must open to allow access.
  Future<Uri> googleConnectUrl(String timeZone) async =>
      Uri.parse((await _send('POST', '/v1/google/connect', body: {'timeZone': timeZone}))['url']! as String);

  Future<String> googleSyncNow() async {
    final j = await _send('POST', '/v1/google/sync');
    final err = j['error'];
    if (err is String) return err;
    return 'Added ${j['created']}, updated ${j['updated']}, removed ${j['deleted']}, moved ${j['moved']} task${j['moved'] == 1 ? '' : 's'} from Google';
  }

  Future<void> googleDisconnect({required bool deleteCalendar}) =>
      _send('POST', '/v1/google/disconnect', body: {'deleteCalendar': deleteCalendar}, ok: {204});

  Future<void> googleTimeZone(String timeZone) => _send('POST', '/v1/google/time-zone', body: {'timeZone': timeZone}, ok: {204});

  Future<List<Map<String, Object?>>> listApiTokens() async => [for (final t in (await _get('/v1/api-tokens'))['tokens']! as List) (t as Map).cast<String, Object?>()];

  /// Makes an API token; the returned string is shown once and never again.
  Future<String> createApiToken(String name, {required bool readOnly}) async =>
      (await _send('POST', '/v1/api-tokens', body: {'name': name, 'readOnly': readOnly}, ok: {201}))['token']! as String;

  Future<void> revokeApiToken(String id) => _send('DELETE', '/v1/api-tokens/$id', ok: {204});

  Future<List<Map<String, Object?>>> listWebhooks() async => [for (final t in (await _get('/v1/webhooks'))['webhooks']! as List) (t as Map).cast<String, Object?>()];

  /// Adds a webhook and returns its secret, shown once.
  Future<String> createWebhook(String url, List<String> events) async =>
      (await _send('POST', '/v1/webhooks', body: {'url': url, 'events': events}, ok: {201}))['secret']! as String;

  Future<void> deleteWebhook(String id) => _send('DELETE', '/v1/webhooks/$id', ok: {204});

  Future<void> reactivateWebhook(String id) => _send('POST', '/v1/webhooks/$id/reactivate', ok: {204});

  Future<List<Map<String, Object?>>> listInboundHooks() async => [for (final t in (await _get('/v1/inbound-hooks'))['hooks']! as List) (t as Map).cast<String, Object?>()];

  /// Makes an incoming webhook; returns its address and secret (shown once).
  Future<({Uri url, String secret})> createInboundHook(String name) async {
    final j = await _send('POST', '/v1/inbound-hooks', body: {'name': name}, ok: {201});
    return (url: addressOf(j['path']! as String), secret: j['secret']! as String);
  }

  Future<void> deleteInboundHook(String id) => _send('DELETE', '/v1/inbound-hooks/$id', ok: {204});

  // --- attachment files ------------------------------------------------------------

  Map<String, String> get _authOnly => {if (token != null) 'authorization': 'Bearer $token'};

  /// Whether the server already holds the file whose SHA-256 is [hash].
  Future<bool> hasBlob(String hash) async {
    try {
      final r = await _client.head(_uri('/v1/blobs/$hash'), headers: _authOnly).timeout(timeout);
      if (r.statusCode == 401) throw SyncTransportException('This device was signed out by the server', unauthorized: true);
      return r.statusCode == 200;
    } on TimeoutException {
      throw SyncTransportException('The server did not answer in time');
    } on SyncTransportException {
      rethrow;
    } on Exception catch (e) {
      throw SyncTransportException('Could not reach the server: ${_short(e)}');
    }
  }

  /// Uploads a file's bytes. The server checks they match [hash].
  Future<void> putBlob(String hash, Stream<List<int>> bytes, int length) async {
    final request = http.StreamedRequest('PUT', _uri('/v1/blobs/$hash'))
      ..headers.addAll({'content-type': 'application/octet-stream', ..._authOnly})
      ..contentLength = length;
    unawaited(request.sink.addStream(bytes).then((_) => request.sink.close(), onError: (Object e) {
      request.sink.addError(e);
      request.sink.close();
    }));
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(request).timeout(const Duration(minutes: 30)));
    } on TimeoutException {
      throw SyncTransportException('The server did not answer in time');
    } on Exception catch (e) {
      throw SyncTransportException('Could not reach the server: ${_short(e)}');
    }
    if (r.statusCode == 401) throw SyncTransportException('This device was signed out by the server', unauthorized: true);
    if (r.statusCode != 201) {
      var message = 'The server answered ${r.statusCode}';
      try {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['message'] is String) message = j['message'] as String;
      } catch (_) {}
      throw SyncTransportException(message);
    }
  }

  /// The bytes of a file, or null if the server does not have it.
  Future<Stream<List<int>>?> getBlob(String hash) async {
    try {
      final r = await _client.send(http.Request('GET', _uri('/v1/blobs/$hash'))..headers.addAll(_authOnly)).timeout(timeout);
      if (r.statusCode == 404) {
        await r.stream.drain<void>();
        return null;
      }
      if (r.statusCode == 401) throw SyncTransportException('This device was signed out by the server', unauthorized: true);
      if (r.statusCode != 200) {
        await r.stream.drain<void>();
        throw SyncTransportException('The server answered ${r.statusCode}');
      }
      return r.stream;
    } on TimeoutException {
      throw SyncTransportException('The server did not answer in time');
    } on SyncTransportException {
      rethrow;
    } on Exception catch (e) {
      throw SyncTransportException('Could not reach the server: ${_short(e)}');
    }
  }

  void close() => _client.close();
}
