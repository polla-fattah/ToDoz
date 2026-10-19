/// Talking to Google: signing the person in (OAuth), and the few Calendar
/// calls the sync needs. Kept thin and separate so tests can point it at a fake Google.
///
/// The app asks for one permission only: `calendar.app.created`, which lets it
/// make its own calendar and manage the events in calendars it made. It cannot
/// see or change the person's other calendars.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const googleScope = 'https://www.googleapis.com/auth/calendar.app.created';

class GoogleConfig {
  const GoogleConfig({required this.clientId, required this.clientSecret, required this.publicUrl});

  final String clientId;
  final String clientSecret;

  /// The server's public address, such as `https://sync.example.com` (no trailing slash).
  final String publicUrl;

  String get redirectUri => '$publicUrl/google/callback';

  /// Reads `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `TASKFLOW_PUBLIC_URL`, or null if any is missing.
  static GoogleConfig? fromEnvironment(Map<String, String> env, {String? clientId, String? clientSecret, String? publicUrl}) {
    final id = clientId ?? env['GOOGLE_CLIENT_ID'];
    final secret = clientSecret ?? env['GOOGLE_CLIENT_SECRET'];
    final url = publicUrl ?? env['TASKFLOW_PUBLIC_URL'];
    if (id == null || id.isEmpty || secret == null || secret.isEmpty || url == null || url.isEmpty) return null;
    return GoogleConfig(clientId: id, clientSecret: secret, publicUrl: url.replaceAll(RegExp(r'/+$'), ''));
  }
}

/// Google no longer accepts the saved sign-in (the person removed access, or it expired).
class GoogleAuthError implements Exception {
  GoogleAuthError(this.message);
  final String message;
  @override
  String toString() => message;
}

class GoogleApiError implements Exception {
  GoogleApiError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'Google answered $status: $message';
}

class GoogleTokens {
  GoogleTokens({required this.accessToken, this.refreshToken, required this.expiresIn});
  final String accessToken;
  final String? refreshToken;
  final int expiresIn;
}

class GoogleApi {
  GoogleApi(
    this.config, {
    http.Client? client,
    this.authBase = 'https://accounts.google.com/o/oauth2/v2/auth',
    this.tokenUrl = 'https://oauth2.googleapis.com/token',
    this.revokeUrl = 'https://oauth2.googleapis.com/revoke',
    this.apiBase = 'https://www.googleapis.com/calendar/v3',
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final GoogleConfig config;
  final http.Client _client;
  final String authBase, tokenUrl, revokeUrl, apiBase;
  final Duration timeout;

  /// The Google page the person is sent to. [state] comes back to us unchanged.
  Uri authUrl(String state) => Uri.parse(authBase).replace(queryParameters: {
        'client_id': config.clientId,
        'redirect_uri': config.redirectUri,
        'response_type': 'code',
        'scope': googleScope,
        'access_type': 'offline', // so we get a refresh token
        'prompt': 'consent', // and get it again if the person reconnects
        'include_granted_scopes': 'false',
        'state': state,
      });

  Future<Map<String, Object?>> _json(http.Response r) async {
    Object? body;
    try {
      body = r.body.isEmpty ? <String, Object?>{} : jsonDecode(r.body);
    } on FormatException {
      body = null;
    }
    if (r.statusCode >= 200 && r.statusCode < 300) return body is Map ? body.cast<String, Object?>() : <String, Object?>{};
    var message = r.reasonPhrase ?? 'error';
    if (body is Map) {
      final err = body['error'];
      if (err is Map && err['message'] is String) {
        message = err['message'] as String;
      } else if (err is String) {
        message = '$err${body['error_description'] is String ? ': ${body['error_description']}' : ''}';
      }
    }
    if (r.statusCode == 401 || (body is Map && body['error'] == 'invalid_grant')) throw GoogleAuthError(message);
    throw GoogleApiError(r.statusCode, message);
  }

  Future<http.Response> _send(String method, String url, {String? token, Object? body, Map<String, String>? form}) async {
    final req = http.Request(method, Uri.parse(url));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (form != null) {
      req.bodyFields = form;
    } else if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    try {
      return await http.Response.fromStream(await _client.send(req).timeout(timeout));
    } on TimeoutException {
      throw GoogleApiError(504, 'Google did not answer in time');
    }
  }

  Future<GoogleTokens> exchangeCode(String code) async {
    final j = await _json(await _send('POST', tokenUrl, form: {
      'code': code,
      'client_id': config.clientId,
      'client_secret': config.clientSecret,
      'redirect_uri': config.redirectUri,
      'grant_type': 'authorization_code',
    }));
    return GoogleTokens(accessToken: j['access_token'] as String, refreshToken: j['refresh_token'] as String?, expiresIn: (j['expires_in'] as num?)?.toInt() ?? 3600);
  }

  Future<String> accessToken(String refreshToken) async {
    final j = await _json(await _send('POST', tokenUrl, form: {
      'refresh_token': refreshToken,
      'client_id': config.clientId,
      'client_secret': config.clientSecret,
      'grant_type': 'refresh_token',
    }));
    return j['access_token'] as String;
  }

  Future<void> revoke(String token) async {
    try {
      await _send('POST', revokeUrl, form: {'token': token});
    } catch (_) {
      // Revoking is a courtesy; the connection is removed here either way.
    }
  }

  // --- calendar ------------------------------------------------------------------

  Future<String> createCalendar(String access, String summary, String timeZone) async {
    final j = await _json(await _send('POST', '$apiBase/calendars', token: access, body: {
      'summary': summary,
      'description': 'Tasks from TaskFlow. Edit the time of an event to reschedule its task.',
      'timeZone': timeZone,
    }));
    return j['id'] as String;
  }

  Future<void> deleteCalendar(String access, String calendarId) async {
    final r = await _send('DELETE', '$apiBase/calendars/${Uri.encodeComponent(calendarId)}', token: access);
    if (r.statusCode != 404 && r.statusCode != 410) await _json(r);
  }

  Future<bool> calendarExists(String access, String calendarId) async {
    final r = await _send('GET', '$apiBase/calendars/${Uri.encodeComponent(calendarId)}', token: access);
    if (r.statusCode == 404 || r.statusCode == 410) return false;
    await _json(r);
    return true;
  }

  String _events(String calendarId) => '$apiBase/calendars/${Uri.encodeComponent(calendarId)}/events';

  Future<Map<String, Object?>> insertEvent(String access, String calendarId, Map<String, Object?> event) async =>
      _json(await _send('POST', _events(calendarId), token: access, body: event));

  Future<Map<String, Object?>> patchEvent(String access, String calendarId, String eventId, Map<String, Object?> event) async =>
      _json(await _send('PATCH', '${_events(calendarId)}/${Uri.encodeComponent(eventId)}', token: access, body: event));

  /// Deletes an event; one that is already gone is not an error.
  Future<void> deleteEvent(String access, String calendarId, String eventId) async {
    final r = await _send('DELETE', '${_events(calendarId)}/${Uri.encodeComponent(eventId)}', token: access);
    if (r.statusCode != 404 && r.statusCode != 410) await _json(r);
  }

  /// Events changed since [updatedMin], including deleted ones.
  Future<List<Map<String, Object?>>> listChanged(String access, String calendarId, {DateTime? updatedMin}) async {
    final out = <Map<String, Object?>>[];
    String? page;
    do {
      final uri = Uri.parse(_events(calendarId)).replace(queryParameters: {
        'showDeleted': 'true',
        'singleEvents': 'true',
        'maxResults': '250',
        'updatedMin': ?updatedMin?.toUtc().toIso8601String(),
        'pageToken': ?page,
      });
      final j = await _json(await _send('GET', uri.toString(), token: access));
      for (final e in (j['items'] as List? ?? const [])) {
        if (e is Map) out.add(e.cast<String, Object?>());
      }
      page = j['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }
}
