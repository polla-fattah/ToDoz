import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:taskflow_geofence/taskflow_geofence.dart';

import '../data/repository.dart';

/// Location reminders on Android: hands the places that have an open task to the phone's geofencing, which watches
/// them while the app is closed and shows the notification itself (see packages/taskflow_geofence).
///
/// What to watch comes from the database ([Repo.watchedPlaces], decided by the shared Dart code), so the same call
/// is made by the app, by the background sync and by the buttons on a notification.
class GeofenceService {
  GeofenceService(this.repo);

  final Repo repo;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Makes the phone watch exactly the places that have a location reminder on an open task. Returns null on
  /// success or why not (no location access, no Google Play Services).
  Future<String?> sync() async {
    if (!supported) return null;
    final plan = await repo.watchedPlaces();
    return TaskflowGeofence.set([for (final w in plan) w.toJson()]);
  }

  Future<GeofenceStatus> status() => TaskflowGeofence.status();

  /// Shows the notification for the tasks with a reminder at [placeId], as if you had just arrived (or left). Makes
  /// sure the phone has the latest places first. Returns how many were shown.
  Future<int> testReminder(String placeId, String kind) async {
    await sync();
    return TaskflowGeofence.simulate(placeId, kind);
  }

  /// Asks for what a reminder needs to fire with the app closed. Android wants it in two steps: location while the
  /// app is in use first, then "all the time" (which opens the phone's settings page on Android 11 and newer).
  /// Notifications are asked for too. Returns the status afterwards.
  Future<GeofenceStatus> requestPermissions() async {
    if (!supported) return GeofenceStatus.unsupported;
    await Permission.notification.request();
    final inUse = await Permission.locationWhenInUse.request();
    if (inUse.isGranted) await Permission.locationAlways.request();
    final after = await status();
    if (after.ready) await sync();
    return after;
  }
}

/// Keeps the watched places in step with the data: hands them over a moment after any change to a task, a place or
/// a location reminder, and when the app comes back to the foreground (a background job may have changed things).
class GeofenceSync with WidgetsBindingObserver {
  GeofenceSync(this.service) {
    _sub = service.repo.watchLocationChanges().listen((_) => _later());
    WidgetsBinding.instance.addObserver(this);
    _later();
  }

  final GeofenceService service;
  late final StreamSubscription<int> _sub;
  Timer? _timer;

  void _later() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () async {
      try {
        await service.sync();
      } catch (e) {
        debugPrint('Could not hand the places to the phone: $e');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _later(); // also after the person granted location in Settings
  }

  void dispose() {
    _timer?.cancel();
    _sub.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

/// A short sentence about what stands in the way of location reminders, or null when all is ready.
String? geofenceProblem(GeofenceStatus s) {
  if (!s.playServices) return 'This phone has no Google Play Services, which Android needs for location reminders.';
  if (!s.fineLocation) return 'Allow location access so ToDoz can tell when you arrive somewhere.';
  if (!s.backgroundLocation) return 'Set location access to "Allow all the time", so reminders work while ToDoz is closed.';
  return null;
}

/// Used where the geofencing call must not fail the caller (a background job).
Future<void> syncGeofencesQuietly(Repo repo) async {
  try {
    await GeofenceService(repo).sync();
  } catch (_) {}
}
