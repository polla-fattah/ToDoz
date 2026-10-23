import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/sync_engine.dart';
import 'package:taskflow_core/backup.dart';
import 'package:taskflow_core/location.dart';
import 'package:taskflow_core/sync.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';

/// Calls the real server code in the same process, as if over HTTP.
class _Transport implements SyncTransport {
  _Transport(this.handler, this.token);
  final Handler handler;
  final String token;

  @override
  Future<SyncResponse> sync(SyncRequest request) async {
    final response = await handler(Request('POST', Uri.parse('http://localhost/v1/sync'),
        headers: {'authorization': 'Bearer $token', 'content-type': 'application/json'}, body: jsonEncode(request.toJson())));
    if (response.statusCode != 200) throw SyncTransportException('status ${response.statusCode}');
    return SyncResponse.fromJson(jsonDecode(await response.readAsString()));
  }
}

class _Device {
  _Device(this.db, this.repo, this.engine);
  final AppDatabase db;
  final Repo repo;
  final SyncEngine engine;
}

/// Places, and reminders that fire at a place ("when I get to work, talk to that guy").
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late Repo repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repo(db, clock: () => DateTime(2026, 10, 19, 9));
    await db.ensureInbox();
  });
  tearDown(() => db.close());

  group('places', () {
    test('are saved with a trimmed name and a radius a geofence can use', () async {
      final id = await repo.createPlace(name: '  Work  ', latitude: 36.19, longitude: 44.01, radiusMeters: 20);
      final p = (await repo.getPlace(id))!;
      expect((p.name, p.latitude, p.longitude, p.radiusMeters), ('Work', 36.19, 44.01, minRadiusMeters));
      final big = await repo.createPlace(name: 'Farm', latitude: 1, longitude: 1, radiusMeters: 90000);
      expect((await repo.getPlace(big))!.radiusMeters, maxRadiusMeters);
      final plain = await repo.createPlace(name: 'Home', latitude: 2, longitude: 2);
      expect((await repo.getPlace(plain))!.radiusMeters, defaultRadiusMeters);
    });

    test('need a name and a real point on the map', () async {
      expect(() => repo.createPlace(name: '  ', latitude: 1, longitude: 1), throwsA(isA<RuleException>()));
      expect(() => repo.createPlace(name: 'Mars', latitude: 120, longitude: 1), throwsA(isA<RuleException>()));
      expect(() => repo.createPlace(name: 'Void', latitude: double.nan, longitude: 1), throwsA(isA<RuleException>()));
    });

    test('can be changed, and are listed by name', () async {
      final b = await repo.createPlace(name: 'bakery', latitude: 1, longitude: 1);
      await repo.createPlace(name: 'Airport', latitude: 2, longitude: 2);
      await repo.updatePlace(b, name: 'Bakery', radiusMeters: 300, latitude: 1.5);
      final list = await repo.watchPlaces().first;
      expect(list.map((p) => p.name), ['Airport', 'Bakery']);
      final p = (await repo.getPlace(b))!;
      expect((p.radiusMeters, p.latitude, p.longitude), (300, 1.5, 1.0));
      expect(() => repo.updatePlace(b, name: ''), throwsA(isA<RuleException>()));
      expect(() => repo.updatePlace('nope', name: 'x'), throwsA(isA<RuleException>()));
    });
  });

  group('location reminders', () {
    late String work;
    late String home;
    late String task;

    setUp(() async {
      work = await repo.createPlace(name: 'Work', latitude: 36.19, longitude: 44.01);
      home = await repo.createPlace(name: 'Home', latitude: 36.2, longitude: 44.0);
      task = await repo.addTask(title: 'Talk to Sam');
    });

    test('a task can have several, and the same one twice is one', () async {
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
      await repo.addLocationReminder(task, work, LocationTrigger.leave);
      await repo.addLocationReminder(task, home, LocationTrigger.arrive);
      final list = await repo.watchLocationReminders(task).first;
      expect(list.map((r) => (r.placeId, r.kind)), [(work, 'arrive'), (work, 'leave'), (home, 'arrive')]);
    });

    test('need a place that exists', () async {
      expect(() => repo.addLocationReminder(task, 'nowhere', LocationTrigger.arrive), throwsA(isA<RuleException>()));
    });

    test('one can be taken off', () async {
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
      final r = (await repo.watchLocationReminders(task).first).single;
      await repo.removeLocationReminder(r.id);
      expect(await repo.watchLocationReminders(task).first, isEmpty);
    });

    test('deleting a place removes its reminders and leaves the task', () async {
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
      await repo.addLocationReminder(task, home, LocationTrigger.leave);
      await repo.deletePlace(work);
      expect((await repo.watchLocationReminders(task).first).map((r) => r.placeId), [home]);
      expect(await repo.getPlace(work), isNull);
      expect((await repo.getTask(task))!.title, 'Talk to Sam');
    });

    test('deleting the task for good removes its location reminders', () async {
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
      await repo.deleteTask(task);
      await repo.deleteTaskForever(task);
      expect(await db.select(db.locationReminders).get(), isEmpty);
    });

    test('a duplicate of the task is watched at the same places', () async {
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
      final copy = await repo.duplicateTask(task);
      expect((await repo.watchLocationReminders(copy).first).map((r) => (r.placeId, r.kind)), [(work, 'arrive')]);
    });

    test('the phone watches only places with an open task, and says what to mention', () async {
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
      final second = await repo.addTask(title: 'Take the laptop home');
      await repo.addLocationReminder(second, work, LocationTrigger.leave);
      final other = await repo.addTask(title: 'Water the plants');
      await repo.addLocationReminder(other, home, LocationTrigger.arrive);

      var plan = await repo.watchedPlaces();
      expect(plan.map((w) => w.place.name), unorderedEquals(['Work', 'Home']));
      final w = plan.firstWhere((w) => w.place.name == 'Work');
      expect(w.tasks.map((t) => (t.title, t.trigger)), [('Talk to Sam', LocationTrigger.arrive), ('Take the laptop home', LocationTrigger.leave)]);

      await repo.completeTask(other); // Home has nothing left to do
      plan = await repo.watchedPlaces();
      expect(plan.map((w) => w.place.name), ['Work']);

      await repo.deleteTask(task);
      await repo.deleteTask(second);
      expect(await repo.watchedPlaces(), isEmpty);
    });

    test('a place with no reminders is not watched', () async {
      expect(await repo.watchedPlaces(), isEmpty);
    });

    test('counts how many open tasks use each place', () async {
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
      final second = await repo.addTask(title: 'b');
      await repo.addLocationReminder(second, work, LocationTrigger.leave);
      expect(await repo.watchPlaceUsage().first, {work: 2});
      await repo.completeTask(second);
      expect(await repo.watchPlaceUsage().first, {work: 1});
    });

    test('the watch signal changes when a place or a reminder changes', () async {
      final first = await repo.watchLocationChanges().first;
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
      final second = await repo.watchLocationChanges().first;
      expect(second, isNot(first));
      await repo.updatePlace(work, radiusMeters: 500);
      expect(await repo.watchLocationChanges().first, isNotNull);
    });
  });

  group('backup', () {
    test('keeps places and location reminders through export and restore', () async {
      final work = await repo.createPlace(name: 'Work', latitude: 36.19, longitude: 44.01, radiusMeters: 250);
      final t = await repo.addTask(title: 'Talk to Sam');
      await repo.addLocationReminder(t, work, LocationTrigger.leave);
      final json = (await repo.exportBundle()).toJsonString();

      final other = AppDatabase(NativeDatabase.memory());
      addTearDown(other.close);
      final repo2 = Repo(other);
      await other.ensureInbox();
      await repo2.replaceAll(Bundle.parse(json));
      final p = (await repo2.getPlace(work))!;
      expect((p.name, p.latitude, p.longitude, p.radiusMeters), ('Work', 36.19, 44.01, 250));
      expect((await repo2.watchLocationReminders(t).first).single.kind, 'leave');
    });

    test('an older backup without places still restores', () async {
      final json = jsonDecode((await repo.exportBundle()).toJsonString()) as Map<String, Object?>;
      json
        ..remove('places')
        ..remove('locationReminders');
      final b = Bundle.parse(jsonEncode(json));
      expect(b.places, isEmpty);
      expect(b.locationReminders, isEmpty);
    });

    test('a bad place, or a reminder for something missing, is refused', () async {
      final work = await repo.createPlace(name: 'Work', latitude: 36.19, longitude: 44.01);
      final t = await repo.addTask(title: 'x');
      await repo.addLocationReminder(t, work, LocationTrigger.arrive);
      final base = jsonDecode((await repo.exportBundle()).toJsonString()) as Map<String, Object?>;
      String with_(void Function(Map<String, Object?>) change) {
        final copy = jsonDecode(jsonEncode(base)) as Map<String, Object?>;
        change(copy);
        return jsonEncode(copy);
      }

      expect(() => Bundle.parse(with_((j) => ((j['places']! as List).first as Map)['latitude'] = 123)), throwsFormatException);
      expect(() => Bundle.parse(with_((j) => ((j['locationReminders']! as List).first as Map)['placeId'] = 'nope')), throwsFormatException);
      expect(() => Bundle.parse(with_((j) => ((j['locationReminders']! as List).first as Map)['taskId'] = 'nope')), throwsFormatException);
      expect(() => Bundle.parse(with_((j) => ((j['locationReminders']! as List).first as Map)['kind'] = 'teleport')), throwsFormatException);
    });
  });

  group('sync', () {
    late Store server;
    late Handler api;
    var counter = 0;

    setUp(() {
      server = Store.open(':memory:');
      api = buildApi(server, config: const ApiConfig(trustProxy: true, syncPerMinute: 100000));
    });
    tearDown(() => server.close());

    Future<_Device> device(Account who) async {
      final paired = server.redeemInvite(server.createInvite(who.id), 'dev${++counter}')!;
      final d = AppDatabase(NativeDatabase.memory());
      addTearDown(d.close);
      await d.ensureSyncMeta();
      await d.ensureInbox();
      final engine = SyncEngine(d, _Transport(api, paired.token));
      await engine.enable();
      return _Device(d, Repo(d, clock: () => DateTime(2026, 10, 19, 9)), engine);
    }

    test('places and location reminders made on the phone arrive on the computer, and a deletion follows', () async {
      final alice = server.createUser('Alice');
      final phone = await device(alice);
      final pc = await device(alice);
      final place = await phone.repo.createPlace(name: 'Work', latitude: 36.19, longitude: 44.01, radiusMeters: 200);
      final task = await phone.repo.addTask(title: 'Talk to Sam');
      await phone.repo.addLocationReminder(task, place, LocationTrigger.arrive);
      await phone.engine.run();
      await pc.engine.run();

      final p = (await pc.repo.getPlace(place))!;
      expect((p.name, p.latitude, p.longitude, p.radiusMeters), ('Work', 36.19, 44.01, 200));
      expect((await pc.repo.watchLocationReminders(task).first).single.kind, 'arrive');
      expect((await pc.repo.watchedPlaces()).single.tasks.single.title, 'Talk to Sam');

      await phone.repo.deletePlace(place);
      await phone.engine.run();
      await pc.engine.run();
      expect(await pc.repo.getPlace(place), isNull);
      expect(await pc.repo.watchLocationReminders(task).first, isEmpty);
    });

    test('another person never sees a place or a location reminder', () async {
      final alice = server.createUser('Alice');
      final bob = server.createUser('Bob');
      final a = await device(alice);
      final b = await device(bob);
      final place = await a.repo.createPlace(name: 'Secret hideout', latitude: 1, longitude: 1);
      final t = await a.repo.addTask(title: 'x');
      await a.repo.addLocationReminder(t, place, LocationTrigger.arrive);
      await a.engine.run();
      await b.engine.run();
      expect(await b.repo.watchPlaces().first, isEmpty);
      expect(await b.db.select(b.db.locationReminders).get(), isEmpty);
    });
  });
}
