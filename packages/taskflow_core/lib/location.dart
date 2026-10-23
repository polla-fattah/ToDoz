/// Places and location reminders: "when I get to work, remind me to talk to that guy". Pure Dart (the phone's
/// geofencing is in the app; this decides *what* to watch and describes it).
library;

import 'dart:math';

/// When a location reminder fires.
enum LocationTrigger {
  /// On arriving at the place.
  arrive,

  /// On leaving the place.
  leave;

  String get label => this == arrive ? 'When I arrive' : 'When I leave';

  /// A short phrase for a notification: "You arrived at Work".
  String describe(String placeName) => this == arrive ? 'You arrived at $placeName' : 'You left $placeName';

  static LocationTrigger? decode(String? text) {
    for (final t in values) {
      if (t.name == text) return t;
    }
    return null;
  }
}

/// Android's geofences work reliably from about this radius; a smaller one can miss you.
const minRadiusMeters = 100;
const maxRadiusMeters = 5000;
const defaultRadiusMeters = 150;

/// Android allows 100 geofences per app; leave some room.
const maxWatchedPlaces = 90;

int clampRadius(int meters) => meters.clamp(minRadiusMeters, maxRadiusMeters);

bool validCoordinates(double latitude, double longitude) =>
    latitude.isFinite && longitude.isFinite && latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180;

/// The distance in metres between two points on the Earth (haversine).
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const radius = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = pow(sin(dLat / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLon / 2), 2);
  return 2 * radius * asin(min(1.0, sqrt(a)));
}

/// A point as people read it: `41.0082° N, 28.9784° E`.
String describeCoordinates(double latitude, double longitude) {
  String part(double v, String pos, String neg) => '${v.abs().toStringAsFixed(4)}° ${v >= 0 ? pos : neg}';
  return '${part(latitude, 'N', 'S')}, ${part(longitude, 'E', 'W')}';
}

/// A saved place.
class PlaceRec {
  const PlaceRec({required this.id, required this.name, required this.latitude, required this.longitude, required this.radiusMeters});
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final int radiusMeters;
}

/// A reminder tied to a place: [taskId] is brought up when the [trigger] happens at [placeId].
class LocationReminderRec {
  const LocationReminderRec({required this.id, required this.taskId, required this.placeId, required this.trigger});
  final String id;
  final String taskId;
  final String placeId;
  final LocationTrigger trigger;
}

/// One task to mention at a watched place.
class WatchedTask {
  const WatchedTask({required this.taskId, required this.title, required this.trigger});
  final String taskId;
  final String title;
  final LocationTrigger trigger;

  Map<String, Object?> toJson() => {'taskId': taskId, 'title': title, 'trigger': trigger.name};
}

/// A place the phone should watch, and what to say when something happens there.
class WatchedPlace {
  const WatchedPlace({required this.place, required this.tasks});
  final PlaceRec place;
  final List<WatchedTask> tasks;

  /// Which transitions to ask the phone for: arriving, leaving, or both.
  bool get wantsArrive => tasks.any((t) => t.trigger == LocationTrigger.arrive);
  bool get wantsLeave => tasks.any((t) => t.trigger == LocationTrigger.leave);

  Map<String, Object?> toJson() => {
        'id': place.id,
        'name': place.name,
        'lat': place.latitude,
        'lon': place.longitude,
        'radius': clampRadius(place.radiusMeters),
        'tasks': [for (final t in tasks) t.toJson()],
      };
}

/// What to watch: the places that have at least one location reminder on a task that is still open (titles by
/// task id in [openTasks]). A completed or deleted task, a place that is gone, or a place with bad coordinates is
/// left out. At most [maxWatchedPlaces] places, in the order of [places].
List<WatchedPlace> planWatchedPlaces({
  required List<PlaceRec> places,
  required List<LocationReminderRec> reminders,
  required Map<String, String> openTasks,
  int limit = maxWatchedPlaces,
}) {
  final out = <WatchedPlace>[];
  for (final place in places) {
    if (out.length >= limit) break;
    if (!validCoordinates(place.latitude, place.longitude)) continue;
    final tasks = <WatchedTask>[
      for (final r in reminders)
        if (r.placeId == place.id && openTasks.containsKey(r.taskId)) WatchedTask(taskId: r.taskId, title: openTasks[r.taskId]!, trigger: r.trigger),
    ];
    if (tasks.isNotEmpty) out.add(WatchedPlace(place: place, tasks: tasks));
  }
  return out;
}
