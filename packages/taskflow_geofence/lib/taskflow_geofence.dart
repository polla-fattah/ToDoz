import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// What the phone can do about location reminders right now.
class GeofenceStatus {
  const GeofenceStatus({required this.playServices, required this.fineLocation, required this.backgroundLocation, required this.watching, this.result = ''});

  /// Google Play Services is there (Android's geofencing is part of it).
  final bool playServices;

  /// Location access while the app is in use.
  final bool fineLocation;

  /// Location access "all the time", which is what lets the phone tell the app while it is closed.
  final bool backgroundLocation;

  /// How many places are being watched.
  final int watching;

  /// How the last attempt to hand the places to Android ended: `ok:3` or a sentence about what went wrong.
  final String result;

  /// Why Android is not watching the places, when it tried and failed (null when all is well or nothing was tried).
  String? get error => result.isEmpty || result.startsWith('ok') ? null : result;

  /// Everything needed for a reminder to fire while the app is closed.
  bool get ready => playServices && fineLocation && backgroundLocation;

  static const unsupported = GeofenceStatus(playServices: false, fineLocation: false, backgroundLocation: false, watching: 0);
}

/// Android geofencing. [set] hands the places to watch to the operating system, which watches them even while the
/// app is closed and shows a notification when you arrive at or leave one. Does nothing on other platforms.
///
/// This is a plugin (not code in the app's MainActivity) so that it also works in the background job that runs
/// while the app is closed.
class TaskflowGeofence {
  static const _channel = MethodChannel('taskflow/geofence');

  static bool get supported => Platform.isAndroid;

  /// Watches exactly [placesJson] (see WatchedPlace.toJson in taskflow_core) and forgets the rest. Returns null on
  /// success, or why it could not (no permission, no Play Services).
  static Future<String?> set(List<Map<String, Object?>> places) async {
    if (!supported) return null;
    try {
      final error = await _channel.invokeMethod<String>('set', jsonEncode(places));
      return error;
    } on MissingPluginException {
      return null; // running without the Android host (tests)
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }

  static Future<void> clear() => set(const []);

  /// Shows the notification you would get on [kind] (`arrive` or `leave`) at the place [placeId], for the tasks
  /// that have such a reminder there, as a test. Returns how many were shown.
  static Future<int> simulate(String placeId, String kind) async {
    if (!supported) return 0;
    try {
      return (await _channel.invokeMethod<int>('simulate', {'placeId': placeId, 'kind': kind})) ?? 0;
    } on MissingPluginException {
      return 0;
    }
  }

  static Future<GeofenceStatus> status() async {
    if (!supported) return GeofenceStatus.unsupported;
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('status');
      if (m == null) return GeofenceStatus.unsupported;
      return GeofenceStatus(
        playServices: m['playServices'] == true,
        fineLocation: m['fine'] == true,
        backgroundLocation: m['background'] == true,
        watching: (m['watching'] as int?) ?? 0,
        result: (m['result'] as String?) ?? '',
      );
    } on MissingPluginException {
      return GeofenceStatus.unsupported;
    }
  }
}
