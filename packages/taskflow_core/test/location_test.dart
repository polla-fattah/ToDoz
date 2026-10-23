import 'package:taskflow_core/location.dart';
import 'package:test/test.dart';

void main() {
  group('distance', () {
    test('is zero for the same point and symmetric', () {
      expect(distanceMeters(41.0, 29.0, 41.0, 29.0), 0);
      expect(distanceMeters(41.0, 29.0, 41.01, 29.02), closeTo(distanceMeters(41.01, 29.02, 41.0, 29.0), 0.001));
    });
    test('matches known distances', () {
      // One degree of latitude is about 111.2 km.
      expect(distanceMeters(0, 0, 1, 0), closeTo(111195, 100));
      // London to Paris is about 344 km.
      expect(distanceMeters(51.5074, -0.1278, 48.8566, 2.3522), closeTo(343500, 2000));
      // 0.001 degrees of latitude is about 111 m: a place and a point 100 m away are inside a 150 m radius.
      expect(distanceMeters(36.19, 44.01, 36.191, 44.01), closeTo(111, 1));
    });
  });

  group('coordinates and radius', () {
    test('valid ranges', () {
      expect(validCoordinates(36.19, 44.01), isTrue);
      expect(validCoordinates(90, 180), isTrue);
      expect(validCoordinates(91, 0), isFalse);
      expect(validCoordinates(0, -181), isFalse);
      expect(validCoordinates(double.nan, 0), isFalse);
      expect(validCoordinates(0, double.infinity), isFalse);
    });
    test('the radius stays where geofences work', () {
      expect(clampRadius(10), minRadiusMeters);
      expect(clampRadius(150), 150);
      expect(clampRadius(99999), maxRadiusMeters);
    });
    test('a point reads like a map reference', () {
      expect(describeCoordinates(41.0082, 28.9784), '41.0082° N, 28.9784° E');
      expect(describeCoordinates(-33.8688, -70.5), '33.8688° S, 70.5000° W');
    });
  });

  group('triggers', () {
    test('are stored by name and read back', () {
      expect(LocationTrigger.decode('arrive'), LocationTrigger.arrive);
      expect(LocationTrigger.decode('leave'), LocationTrigger.leave);
      expect(LocationTrigger.decode('enter'), isNull);
      expect(LocationTrigger.decode(null), isNull);
    });
    test('say what happened', () {
      expect(LocationTrigger.arrive.describe('Work'), 'You arrived at Work');
      expect(LocationTrigger.leave.describe('Home'), 'You left Home');
      expect(LocationTrigger.arrive.label, 'When I arrive');
    });
  });

  group('what to watch', () {
    const work = PlaceRec(id: 'p1', name: 'Work', latitude: 36.19, longitude: 44.01, radiusMeters: 150);
    const home = PlaceRec(id: 'p2', name: 'Home', latitude: 36.2, longitude: 44.0, radiusMeters: 5);
    const nowhere = PlaceRec(id: 'p3', name: 'Broken', latitude: 200, longitude: 0, radiusMeters: 150);
    const empty = PlaceRec(id: 'p4', name: 'Gym', latitude: 36.0, longitude: 44.0, radiusMeters: 150);
    const reminders = [
      LocationReminderRec(id: 'r1', taskId: 't1', placeId: 'p1', trigger: LocationTrigger.arrive),
      LocationReminderRec(id: 'r2', taskId: 't2', placeId: 'p1', trigger: LocationTrigger.leave),
      LocationReminderRec(id: 'r3', taskId: 't3', placeId: 'p2', trigger: LocationTrigger.arrive),
      LocationReminderRec(id: 'r4', taskId: 'gone', placeId: 'p2', trigger: LocationTrigger.leave),
      LocationReminderRec(id: 'r5', taskId: 't1', placeId: 'p3', trigger: LocationTrigger.arrive),
    ];
    final open = {'t1': 'Talk to Sam', 't2': 'Take the laptop home', 't3': 'Water the plants'};

    test('lists places with their open tasks only, in the order given', () {
      final plan = planWatchedPlaces(places: [work, home, nowhere, empty], reminders: reminders, openTasks: open);
      expect([for (final w in plan) w.place.id], ['p1', 'p2'], reason: 'no bad coordinates, nothing for a place without reminders');
      expect([for (final t in plan[0].tasks) t.title], ['Talk to Sam', 'Take the laptop home']);
      expect([for (final t in plan[1].tasks) t.taskId], ['t3'], reason: 'a task that is gone or done is not mentioned');
    });

    test('says which transitions each place needs', () {
      final plan = planWatchedPlaces(places: [work, home], reminders: reminders, openTasks: open);
      expect((plan[0].wantsArrive, plan[0].wantsLeave), (true, true));
      expect((plan[1].wantsArrive, plan[1].wantsLeave), (true, false));
    });

    test('a completed task stops being watched, and so does its place', () {
      final plan = planWatchedPlaces(places: [work], reminders: reminders, openTasks: {'t2': 'Take the laptop home'});
      expect(plan.single.tasks.single.trigger, LocationTrigger.leave);
      expect(planWatchedPlaces(places: [work], reminders: reminders, openTasks: const {}), isEmpty);
    });

    test('never asks the phone for more places than it can watch', () {
      final many = [for (var i = 0; i < 120; i++) PlaceRec(id: 'p$i', name: 'P$i', latitude: 36.0 + i / 1000, longitude: 44.0, radiusMeters: 150)];
      final rem = [for (var i = 0; i < 120; i++) LocationReminderRec(id: 'r$i', taskId: 't1', placeId: 'p$i', trigger: LocationTrigger.arrive)];
      expect(planWatchedPlaces(places: many, reminders: rem, openTasks: {'t1': 'x'}), hasLength(maxWatchedPlaces));
    });

    test('is handed to the phone as JSON with a usable radius', () {
      final plan = planWatchedPlaces(places: [home], reminders: reminders, openTasks: open);
      final json = plan.single.toJson();
      expect(json['radius'], minRadiusMeters, reason: 'a 5 m radius is raised to what geofences can do');
      expect(json['name'], 'Home');
      expect((json['tasks']! as List).single, {'taskId': 't3', 'title': 'Water the plants', 'trigger': 'arrive'});
    });
  });
}
