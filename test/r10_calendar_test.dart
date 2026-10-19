import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/app.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/ui/catalog.dart';
import 'package:taskflow_core/time_grid.dart' show CalendarMode;
import 'package:taskflow_core/view_options.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// The Calendar views (Day, 3 days, Week, Month) as a person uses them: on a phone and on a wide window.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late Repo repo;
  late Catalog catalog;
  final clock = DateTime(2026, 10, 19, 9, 0); // a Monday morning
  const monday = '2026-10-19';
  const tuesday = '2026-10-20';

  Future<void> start(WidgetTester tester, {Size size = const Size(420, 900), CalendarMode? mode, Future<void> Function()? seed}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repo(db, clock: () => clock);
      await db.ensureInbox();
      if (mode != null) await repo.setSetting('calendarMode', mode.name);
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

  final viewMenu = find.byKey(const Key('calendar-view-menu'));

  /// Opens the view picker and chooses [label] (it is a different one from the view being shown).
  Future<void> pickView(WidgetTester tester, String label) async {
    await tester.tap(viewMenu);
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(PopupMenuItem<CalendarMode>), matching: find.text(label)));
    await settle(tester);
  }

  Future<void> openCalendar(WidgetTester tester) async {
    final wide = tester.view.physicalSize.width >= 840;
    await tester.tap(find.text('Calendar').last);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 600)); // the page we left finishes sliding away
    expect(viewMenu, findsOneWidget, reason: wide ? 'on the sidebar layout' : 'on the phone layout');
  }

  Future<Task> task(WidgetTester tester, String id) async => (await tester.runAsync(() => repo.getTask(id)))!;

  testWidgets('on a phone the Calendar is a tab; it opens on three days with today first, and Week is not offered', (tester) async {
    await start(tester, seed: () async {
      await repo.addTask(title: 'Standup', dueDate: monday, dueTime: '09:30');
    });
    await openCalendar(tester);
    expect(find.text('October'), findsOneWidget, reason: 'the month, without the year when it is this year (on a phone)');
    expect(find.textContaining('Standup'), findsOneWidget);
    expect(find.text('3 days'), findsOneWidget);
    await tester.tap(viewMenu);
    await settle(tester);
    expect(find.descendant(of: find.byType(PopupMenuItem<CalendarMode>), matching: find.text('Day')), findsOneWidget);
    expect(find.descendant(of: find.byType(PopupMenuItem<CalendarMode>), matching: find.text('Month')), findsOneWidget);
    expect(find.text('Week'), findsNothing);
    await finish(tester);
  });

  testWidgets('tasks with a date but no time sit in the all-day row, apart from the hours', (tester) async {
    await start(tester, seed: () async {
      await repo.addTask(title: 'Pay rent', dueDate: tuesday);
      await repo.addTask(title: 'Call mum', dueDate: tuesday, dueTime: '18:00');
    });
    await openCalendar(tester);
    final rent = tester.getTopLeft(find.textContaining('Pay rent')).dy;
    final call = tester.getTopLeft(find.textContaining('Call mum')).dy;
    expect(rent, lessThan(call), reason: 'the all-day row is above the hours');
    await finish(tester);
  });

  testWidgets('tasks that overlap in time share the width of the day, side by side', (tester) async {
    late String a, b, c;
    await start(tester, mode: CalendarMode.day, seed: () async {
      a = await repo.addTask(title: 'Alpha', dueDate: monday, dueTime: '09:30', durationMinutes: 60);
      b = await repo.addTask(title: 'Bravo', dueDate: monday, dueTime: '09:45', durationMinutes: 60);
      c = await repo.addTask(title: 'Charlie', dueDate: monday, dueTime: '14:00');
    });
    await openCalendar(tester);
    final ra = tester.getRect(find.byKey(ValueKey('block-$a')));
    final rb = tester.getRect(find.byKey(ValueKey('block-$b')));
    final rc = tester.getRect(find.byKey(ValueKey('block-$c')));
    expect(ra.right, lessThanOrEqualTo(rb.left + 1), reason: 'side by side');
    expect((ra.width - rb.width).abs(), lessThan(1));
    expect(rc.width, greaterThan(ra.width * 1.8), reason: 'a task alone has the whole day');
    expect(rb.top - ra.top, closeTo(15 * 56 / 60, 1), reason: 'a quarter of an hour later');
    expect(ra.height, closeTo(56 - 2, 1), reason: 'an hour long');
    expect(rc.height, closeTo(28 - 2, 1), reason: 'half an hour when no duration is set');
    await finish(tester);
  });

  testWidgets('the view you pick is remembered, and a day heading opens that day', (tester) async {
    await start(tester, seed: () async => repo.addTask(title: 'Standup', dueDate: tuesday, dueTime: '10:00'));
    await openCalendar(tester);
    await pickView(tester, 'Month');
    expect(find.descendant(of: viewMenu, matching: find.text('Month')), findsOneWidget, reason: 'the picker shows the view in use');
    expect(await tester.runAsync(() => repo.getSetting('calendarMode')), 'month');
    await pickView(tester, '3 days');
    expect(find.descendant(of: viewMenu, matching: find.text('3 days')), findsOneWidget);
    await tester.tap(find.text('20').first); // the heading of Tuesday
    await settle(tester);
    expect(find.text('20 October'), findsOneWidget);
    await tester.tap(find.byTooltip('Next'));
    await settle(tester);
    expect(find.text('21 October'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('dragging a block with a mouse moves the task to the new time, keeping its length', (tester) async {
    late String id;
    await start(tester, mode: CalendarMode.day, seed: () async {
      id = await repo.addTask(title: 'Design review', dueDate: monday, dueTime: '10:00', durationMinutes: 90);
    });
    await openCalendar(tester);
    final block = tester.getRect(find.byKey(ValueKey('block-$id')));
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.down(block.center - const Offset(0, 6));
    await tester.pump();
    await g.moveBy(const Offset(0, 30));
    await tester.pump();
    await g.moveBy(Offset(0, 2 * 56.0 - 30)); // two hours down
    await tester.pump();
    await g.up();
    await settle(tester);
    final t = await task(tester, id);
    expect(t.dueTime, '12:00');
    expect(t.dueDate, monday);
    expect(t.durationMinutes, 90);
    await finish(tester);
  });

  testWidgets('dragging the bottom edge of a block changes how long it lasts, in quarter hours', (tester) async {
    late String id;
    await start(tester, mode: CalendarMode.day, seed: () async {
      id = await repo.addTask(title: 'Write notes', dueDate: monday, dueTime: '11:00', durationMinutes: 60);
    });
    await openCalendar(tester);
    final block = tester.getRect(find.byKey(ValueKey('block-$id')));
    await tester.dragFrom(Offset(block.center.dx, block.bottom - 4), const Offset(0, 28 + 6)); // half an hour and a bit
    await settle(tester);
    final t = await task(tester, id);
    expect(t.dueTime, '11:00', reason: 'the start does not move');
    expect(t.durationMinutes, 90);
    await finish(tester);
  });

  testWidgets('tapping an empty spot adds a task at that time, on that day', (tester) async {
    await start(tester, mode: CalendarMode.day);
    await openCalendar(tester);
    // The grid starts about 90 minutes before now (09:00), so 07:30 is at the top; find the 10:00 line.
    final hour10 = tester.getTopLeft(find.text('10:00')).dy + 7;
    await tester.tapAt(Offset(300, hour10 + 3));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'Call the bank');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add task'));
    await settle(tester);
    final all = await tester.runAsync(() => repo.watchAllOpen().first);
    final made = all!.singleWhere((t) => t.title == 'Call the bank');
    expect(made.dueDate, monday);
    expect(made.dueTime, '10:00');
    await finish(tester);
  });

  testWidgets('a date typed in the text wins over the spot that was tapped', (tester) async {
    await start(tester, mode: CalendarMode.day);
    await openCalendar(tester);
    final hour10 = tester.getTopLeft(find.text('10:00')).dy + 7;
    await tester.tapAt(Offset(300, hour10 + 3));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'Pay rent tomorrow');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add task'));
    await settle(tester);
    final all = await tester.runAsync(() => repo.watchAllOpen().first);
    final made = all!.singleWhere((t) => t.title == 'Pay rent');
    expect(made.dueDate, tuesday);
    expect(made.dueTime, isNull, reason: 'the time of the tapped spot goes with the tapped day only');
    await finish(tester);
  });

  testWidgets('on a wide window there is a Week view with seven days, and it is where a computer starts', (tester) async {
    await start(tester, size: const Size(1280, 800), mode: CalendarMode.week, seed: () async {
      await repo.addTask(title: 'Standup', dueDate: monday, dueTime: '09:30');
      await repo.addTask(title: 'Dentist', dueDate: '2026-10-23', dueTime: '15:00');
    });
    await openCalendar(tester);
    expect(find.text('Week'), findsOneWidget);
    expect(find.text('October 2026'), findsOneWidget);
    for (final d in ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN']) {
      expect(find.text(d), findsOneWidget);
    }
    expect(find.textContaining('Standup'), findsOneWidget);
    await tester.tap(find.byTooltip('Next'));
    await settle(tester);
    expect(find.text('Oct – Nov 2026'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a saved Week view shrinks to three days when the window is narrow', (tester) async {
    await start(tester, mode: CalendarMode.week);
    await openCalendar(tester);
    expect(find.text('3 days'), findsOneWidget);
    expect(find.text('Week'), findsNothing);
    await finish(tester);
  });

  testWidgets('the month shows tasks as chips on a wide window; dragging one to another day moves it', (tester) async {
    late String id;
    await start(tester, size: const Size(1280, 800), mode: CalendarMode.month, seed: () async {
      id = await repo.addTask(title: 'Dentist', dueDate: '2026-10-21', dueTime: '15:00');
    });
    await openCalendar(tester);
    expect(find.text('October 2026'), findsOneWidget);
    final chip = find.text('Dentist');
    expect(chip, findsOneWidget);
    final target = tester.getCenter(find.text('27')); // the cell number of Tuesday the 27th
    final g = await tester.startGesture(tester.getCenter(chip));
    await tester.pump(const Duration(milliseconds: 400));
    await g.moveTo(target + const Offset(0, 40));
    await tester.pump();
    await g.up();
    await settle(tester);
    final t = await task(tester, id);
    expect(t.dueDate, '2026-10-27');
    expect(t.dueTime, '15:00', reason: 'the time stays when only the day changes');
    await finish(tester);
  });

  testWidgets('a project can be shown as a calendar too, with the same views', (tester) async {
    late String project;
    await start(tester, seed: () async {
      project = await repo.createProject(name: 'Work');
      await repo.setProjectViewOptions(project, const ViewOptions(layout: ViewLayout.calendar));
      await repo.addTask(title: 'Write report', projectId: project, dueDate: monday, dueTime: '13:00');
      await repo.addTask(title: 'Elsewhere', dueDate: monday, dueTime: '13:00');
    });
    await tester.tap(find.text('Browse'));
    await settle(tester);
    await tester.tap(find.text('Work'));
    await settle(tester);
    expect(viewMenu, findsOneWidget);
    expect(find.textContaining('Write report'), findsOneWidget);
    expect(find.text('Elsewhere'), findsNothing);
    await finish(tester);
  });
}
