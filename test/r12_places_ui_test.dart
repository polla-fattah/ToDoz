import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/app.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/ui/catalog.dart';
import 'package:taskflow/ui/place_editor.dart';
import 'package:taskflow_core/location.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Places and the location reminder on a task page, as a person uses them (on a computer-sized window).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late Repo repo;
  late Catalog catalog;
  late String task;

  setUp(() => PlaceEditorPage.showMap = false); // the map needs the internet; the coordinate fields still work
  tearDown(() => PlaceEditorPage.showMap = true);

  Future<void> start(WidgetTester tester, {Future<void> Function()? seed}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repo(db, clock: () => DateTime(2026, 10, 19, 9));
      await db.ensureInbox();
      task = await repo.addTask(title: 'Talk to Sam', dueDate: '2026-10-19');
      await seed?.call();
    });
    catalog = Catalog(repo);
    await tester.pumpWidget(TaskFlowApp(catalog: catalog));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    catalog.dispose();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> openPlaces(WidgetTester tester) async {
    await tester.tap(find.text('Settings'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Places'), 300, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Places'));
    await settle(tester);
  }

  Future<void> fillPlace(WidgetTester tester, {required String name, String lat = '36.19', String lon = '44.01'}) async {
    await tester.enterText(find.widgetWithText(TextField, 'Name'), name);
    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), lat);
    await tester.enterText(find.widgetWithText(TextField, 'Longitude'), lon);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await settle(tester);
  }

  Future<void> openTask(WidgetTester tester) async {
    await tester.tap(find.text('Talk to Sam'));
    await settle(tester);
    await tester.scrollUntilVisible(find.widgetWithText(ActionChip, 'Location'), 300, scrollable: find.byType(Scrollable).last);
  }

  testWidgets('the Places screen starts empty, and a place made there is listed', (tester) async {
    await start(tester);
    await openPlaces(tester);
    expect(find.textContaining('No places yet'), findsOneWidget);
    await tester.tap(find.text('Add place'));
    await settle(tester);
    await fillPlace(tester, name: '  Work ');
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('150 m · no open tasks'), findsOneWidget);
    final saved = await tester.runAsync(() => repo.watchPlaces().first);
    expect((saved!.single.name, saved.single.latitude, saved.single.longitude), ('Work', 36.19, 44.01));
    await finish(tester);
  });

  testWidgets('a place with no name or no point is not saved, and says why', (tester) async {
    await start(tester);
    await openPlaces(tester);
    await tester.tap(find.text('Add place'));
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.textContaining('Choose where the place is'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '36.19');
    await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '44.01');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.textContaining('Give the place a name'), findsOneWidget);
    expect(await tester.runAsync(() => repo.watchPlaces().first), isEmpty);
    await finish(tester);
  });

  testWidgets('typing a point that is not on the Earth does not move the pin', (tester) async {
    await start(tester);
    await openPlaces(tester);
    await tester.tap(find.text('Add place'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Mars');
    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '123');
    await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '44');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.textContaining('Choose where the place is'), findsOneWidget, reason: 'the bad point was ignored');
    expect(await tester.runAsync(() => repo.watchPlaces().first), isEmpty);
    await finish(tester);
  });

  testWidgets('a place can be edited and deleted (a place in use asks first)', (tester) async {
    late String work;
    await start(tester, seed: () async {
      work = await repo.createPlace(name: 'Work', latitude: 36.19, longitude: 44.01);
      await repo.addLocationReminder(task, work, LocationTrigger.arrive);
    });
    await openPlaces(tester);
    expect(find.text('150 m · 1 open task'), findsOneWidget);
    await tester.tap(find.text('Work'));
    await settle(tester);
    expect(find.text('Edit place'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Office');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Office'), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(find.textContaining('1 open task will keep its other details'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    expect(await tester.runAsync(() => repo.watchPlaces().first), isEmpty);
    expect(await tester.runAsync(() => repo.watchLocationReminders(task).first), isEmpty);
    expect((await tester.runAsync(() => repo.getTask(task)))!.title, 'Talk to Sam');
    await finish(tester);
  });

  testWidgets('on a task: choose "when I arrive", make a new place on the spot, and the reminder is there', (tester) async {
    await start(tester);
    await openTask(tester);
    await tester.tap(find.widgetWithText(ActionChip, 'Location'));
    await settle(tester);
    expect(find.text('When I arrive'), findsOneWidget);
    expect(find.text('When I leave'), findsOneWidget);
    await tester.tap(find.text('New place…'));
    await settle(tester);
    await fillPlace(tester, name: 'Work');
    expect(find.widgetWithText(InputChip, 'Work · When I arrive'), findsOneWidget);
    final list = await tester.runAsync(() => repo.watchLocationReminders(task).first);
    expect(list!.single.kind, 'arrive');
    await finish(tester);
  });

  testWidgets('on a task: an existing place and "when I leave", and a reminder can be taken off', (tester) async {
    await start(tester, seed: () async {
      await repo.createPlace(name: 'Home', latitude: 36.2, longitude: 44.0);
    });
    await openTask(tester);
    await tester.tap(find.widgetWithText(ActionChip, 'Location'));
    await settle(tester);
    await tester.tap(find.text('When I leave'));
    await tester.pump();
    await tester.tap(find.text('Home'));
    await settle(tester);
    expect(find.widgetWithText(InputChip, 'Home · When I leave'), findsOneWidget);

    await tester.tap(find.descendant(of: find.widgetWithText(InputChip, 'Home · When I leave'), matching: find.byType(Icon)).last);
    await settle(tester);
    expect(find.widgetWithText(InputChip, 'Home · When I leave'), findsNothing);
    expect(await tester.runAsync(() => repo.watchLocationReminders(task).first), isEmpty);
    await finish(tester);
  });
}
