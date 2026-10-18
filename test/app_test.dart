import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/core/date_parser.dart';
import 'package:taskflow/core/view_options.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/ui/catalog.dart';
import 'package:taskflow/app.dart';

/// Lets drift's real async work (it uses isolates-free but timer-driven
/// streams) finish, then renders a frame.
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late Repo repo;
  late Catalog catalog;

  Future<void> start(WidgetTester tester, {Size size = const Size(420, 900)}) async {
    // One logical pixel per physical pixel, so the size below is what the layout sees.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size; // default: a phone
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repo(db);
      await db.ensureInbox();
    });
    catalog = Catalog(repo);
    await tester.pumpWidget(TaskFlowApp(catalog: catalog));
    await settle(tester);
  }

  /// Unmounts the app and stops the catalog's subscriptions.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    catalog.dispose();
    // Let drift's zero-length cleanup timers fire so none is left pending.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    // The in-memory database is not closed: drift's close() waits on stream
    // cleanup that was started inside fake-async time and never completes
    // here. It is released with the test process.
  }

  testWidgets('opens on Today with an empty state and the four destinations', (tester) async {
    await start(tester);
    expect(find.text('A little breathing room'), findsOneWidget);
    for (final label in ['Inbox', 'Today', 'Upcoming', 'Browse']) {
      expect(find.text(label), findsWidgets);
    }
    await finish(tester);
  });

  testWidgets('Quick Add creates a dated, prioritised, labelled task', (tester) async {
    await start(tester);
    await tester.tap(find.byTooltip('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Review paper today p1 %reading');
    await tester.pump();
    // The parsed values are shown as chips before submitting (FR-Q1).
    expect(find.text('Today'), findsWidgets);
    expect(find.text('P1'), findsOneWidget);
    expect(find.textContaining('%reading'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, 'Add task'));
    await tester.pump();
    // %reading is new, so the app asks before creating it (FR-Q5).
    await settle(tester);
    expect(find.text('Create new items?'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await settle(tester);

    expect(find.text('Review paper'), findsOneWidget);
    final tasks = await tester.runAsync(() => repo.watchToday(formatDate(dateOnly(DateTime.now()))).first);
    expect(tasks!.single.title, 'Review paper');
    expect(tasks.single.priority, 1);
    final labels = await tester.runAsync(() => repo.watchLabels().first);
    expect(labels!.single.name, 'reading');
    await finish(tester);
  });

  testWidgets('completing a task shows Undo, and Undo brings it back', (tester) async {
    await start(tester);
    await tester.runAsync(() => repo.addTask(title: 'Buy milk', dueDate: formatDate(dateOnly(DateTime.now()))));
    await settle(tester);
    expect(find.text('Buy milk'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('Complete task')).first);
    await settle(tester);
    expect(find.text('Buy milk'), findsNothing);
    expect(find.text('Task completed'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('Buy milk'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Browse lists projects and lets you create one', (tester) async {
    await start(tester);
    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);
    await tester.tap(find.byTooltip('New project'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Work');
    await tester.tap(find.text('Save'));
    await settle(tester);
    // We land on the new, empty project.
    expect(find.text('No tasks yet'), findsOneWidget);
    final projects = await tester.runAsync(() => repo.watchProjects().first);
    expect(projects!.map((p) => p.name), contains('Work'));
    await finish(tester);
  });

  testWidgets('the task page edits fields and adds a sub-task', (tester) async {
    await start(tester);
    final id = await tester.runAsync(() => repo.addTask(title: 'Write report', dueDate: formatDate(dateOnly(DateTime.now()))));
    await settle(tester);
    await tester.tap(find.text('Write report'));
    await tester.pumpAndSettle();
    expect(find.text('Sub-tasks'), findsOneWidget);

    await tester.tap(find.text('P2'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Add sub-task'), 'Outline');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    final task = await tester.runAsync(() => repo.getTask(id!));
    expect(task!.priority, 2);
    final kids = await tester.runAsync(() => repo.watchChildren(id!).first);
    expect(kids!.single.title, 'Outline');
    expect(find.text('Outline'), findsOneWidget);
    await finish(tester);
  });

  group('R2 screens', () {
    String today() => formatDate(dateOnly(DateTime.now()));

    testWidgets('Quick Add shows the parsed time and saves it', (tester) async {
      await start(tester);
      await tester.tap(find.byTooltip('Add task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Call Sam tomorrow at 4pm');
      await tester.pump();
      expect(find.text('Tomorrow'), findsOneWidget);
      expect(find.text('16:00'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Add task'));
      await settle(tester);
      final tasks = await tester.runAsync(() => repo.watchScheduled().first);
      expect(tasks!.single.title, 'Call Sam');
      expect(tasks.single.dueTime, '16:00');
      await finish(tester);
    });

    testWidgets('the repeat dialog explains a problem, then previews the next dates', (tester) async {
      await start(tester);
      await tester.tap(find.byTooltip('Add task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Water plants');
      await tester.tap(find.text('Repeat'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'every day except fri');
      await tester.pump();
      expect(find.textContaining('except'), findsWidgets);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);

      await tester.enterText(find.byType(TextField).last, 'every other week');
      await tester.pump();
      expect(find.textContaining('Next:'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('every other week'), findsOneWidget); // the chip

      await tester.tap(find.widgetWithText(FilledButton, 'Add task'));
      await settle(tester);
      final tasks = await tester.runAsync(() => repo.watchScheduled().first);
      expect(tasks!.single.recurrence, 'every other week');
      expect(tasks.single.dueDate, today());
      await finish(tester);
    });

    testWidgets('completing a repeating task moves it on and Undo puts it back', (tester) async {
      await start(tester);
      await tester.runAsync(() => repo.addTask(title: 'Water plants', dueDate: today(), recurrence: 'every day'));
      await settle(tester);
      expect(find.text('Water plants'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel(RegExp('Complete task')).first);
      await settle(tester);
      expect(find.textContaining('Next: Tomorrow'), findsOneWidget);
      expect(find.text('Water plants'), findsNothing); // moved to tomorrow, so off Today
      final moved = await tester.runAsync(() => repo.watchScheduled().first);
      expect(moved!.single.completedAt, isNull);

      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(find.text('Water plants'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an Undo bar goes away by itself after a few seconds', (tester) async {
      await start(tester);
      await tester.runAsync(() => repo.addTask(title: 'Buy milk', dueDate: today()));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel(RegExp('Complete task')).first);
      await settle(tester);
      expect(find.text('Undo'), findsOneWidget);
      // Found on a device: a snackbar with an action used to stay on screen for ever.
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Undo'), findsNothing);
      await finish(tester);
    });

    testWidgets('a task whose time has passed today is listed as overdue', (tester) async {
      await start(tester);
      await tester.runAsync(() => repo.addTask(title: 'Early call', dueDate: today(), dueTime: '00:00'));
      await tester.runAsync(() => repo.addTask(title: 'All day', dueDate: today()));
      await settle(tester);
      expect(find.textContaining('Overdue', findRichText: true), findsOneWidget); // the section heading
      expect(find.text('Early call'), findsOneWidget);
      expect(find.text('All day'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the task page edits time, deadline and reminders', (tester) async {
      await start(tester);
      final id = await tester.runAsync(() => repo.addTask(title: 'Dentist', dueDate: today(), dueTime: '15:00'));
      await settle(tester);
      await tester.tap(find.text('Dentist'));
      await tester.pumpAndSettle();
      expect(find.text('Reminders'), findsOneWidget);
      expect(find.textContaining('Automatic'), findsOneWidget); // 30 minutes before, by default

      await tester.tap(find.widgetWithText(ActionChip, 'Reminder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 hour before'));
      await settle(tester);
      final list = await tester.runAsync(() => repo.watchReminders(id!).first);
      expect(list!.single.spec, '60m');
      expect(find.text('1 hour before'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('settings offer the clock, week start and reminder options', (tester) async {
      await start(tester);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('24-hour clock'), findsOneWidget);
      expect(find.text('Week starts on'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Automatic reminder'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Automatic reminder'), findsOneWidget);
      expect(find.text('Daily digest'), findsOneWidget);
      await tester.tap(find.text('24-hour clock'));
      await settle(tester);
      expect(await tester.runAsync(() => repo.getSetting('use24h')), 'false');
      await finish(tester);
    });
  });

  group('R3 screens', () {
    String today() => formatDate(dateOnly(DateTime.now()));

    testWidgets('a wide window shows the permanent sidebar and navigates through it', (tester) async {
      await start(tester, size: const Size(1200, 800));
      await tester.runAsync(() => repo.createProject(name: 'Garden'));
      await settle(tester);
      expect(find.text('PROJECTS'), findsOneWidget);
      expect(find.text('Garden'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.text('Garden'));
      await settle(tester);
      expect(find.text('No tasks yet'), findsOneWidget);
      await tester.tap(find.text('Upcoming'));
      await settle(tester);
      expect(find.text('Nothing scheduled'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('view options switch a project to a board and are saved', (tester) async {
      await start(tester);
      final p = await tester.runAsync(() => repo.createProject(name: 'Work'));
      await tester.runAsync(() => repo.createSection(p!, 'Todo'));
      await tester.runAsync(() => repo.addTask(title: 'Write report', projectId: p!));
      await settle(tester);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work'));
      await settle(tester);
      expect(find.text('Write report'), findsOneWidget);

      await tester.tap(find.byTooltip('View options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Board'));
      await settle(tester);
      final project = await tester.runAsync(() => repo.getProject(p!));
      expect(ViewOptions.decode(project!.viewOptions).layout, ViewLayout.board);
      await finish(tester);
    });

    testWidgets('dragging a card to another board column changes its section', (tester) async {
      await start(tester, size: const Size(1200, 800));
      final p = await tester.runAsync(() => repo.createProject(name: 'Work'));
      final todo = await tester.runAsync(() => repo.createSection(p!, 'Todo'));
      final doing = await tester.runAsync(() => repo.createSection(p!, 'Doing'));
      final t = await tester.runAsync(() => repo.addTask(title: 'Write report', projectId: p!, sectionId: todo));
      await tester.runAsync(() => repo.setProjectViewOptions(p!, const ViewOptions(layout: ViewLayout.board)));
      await settle(tester);
      await tester.tap(find.text('Work'));
      await settle(tester);
      expect(find.text('Doing'), findsOneWidget);

      final card = tester.getCenter(find.text('Write report'));
      final target = tester.getCenter(find.text('Doing')) + const Offset(0, 120);
      final g = await tester.startGesture(card);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await g.moveTo(target);
      await tester.pump();
      await g.up();
      await settle(tester);

      final task = await tester.runAsync(() => repo.getTask(t!));
      expect(task!.sectionId, doing);
      await finish(tester);
    });

    testWidgets('a saved filter lists only matching tasks', (tester) async {
      await start(tester);
      await tester.runAsync(() => repo.addTask(title: 'Urgent thing', priority: 1));
      await tester.runAsync(() => repo.addTask(title: 'Calm thing'));
      await tester.runAsync(() => repo.createFilter(name: 'Urgent', query: 'p1'));
      await settle(tester);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Urgent'));
      await settle(tester);
      expect(find.text('Urgent thing'), findsOneWidget);
      expect(find.text('Calm thing'), findsNothing);
      await finish(tester);
    });

    testWidgets('the filter editor underlines a mistake and only saves a valid query', (tester) async {
      await start(tester);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New filter'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Mine');
      await tester.enterText(find.widgetWithText(TextField, 'Query'), '#NoSuchProject');
      await tester.pump();
      expect(find.textContaining('No project matches'), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Save')).onPressed, isNull);

      await tester.enterText(find.widgetWithText(TextField, 'Query'), 'p1 & overdue');
      await tester.pump();
      expect(find.text('Looks good'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await settle(tester);
      final filters = await tester.runAsync(() => repo.watchFilters().first);
      expect(filters!.single.query, 'p1 & overdue');
      await finish(tester);
    });

    testWidgets('long-press selects tasks and the toolbar completes them', (tester) async {
      await start(tester);
      await tester.runAsync(() => repo.addTask(title: 'One', dueDate: today()));
      await tester.runAsync(() => repo.addTask(title: 'Two', dueDate: today()));
      await settle(tester);
      await tester.longPress(find.text('One'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('Two')); // while selecting, a tap adds to the selection
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Complete'));
      await settle(tester);
      expect(find.text('2 selected'), findsNothing);
      expect(find.textContaining('2 tasks completed'), findsOneWidget);
      final open = await tester.runAsync(() => repo.watchAllOpen().first);
      expect(open, isEmpty);
      await finish(tester);
    });

    testWidgets('search understands filters and finds text in comments', (tester) async {
      await start(tester);
      final a = await tester.runAsync(() => repo.addTask(title: 'Plain task', priority: 1));
      await tester.runAsync(() => repo.addTask(title: 'Other'));
      await tester.runAsync(() => repo.addComment(a!, 'remember the zebra'));
      await settle(tester);
      await tester.tap(find.byTooltip('Search').first);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'p1');
      await settle(tester);
      expect(find.textContaining('Showing a filter'), findsOneWidget);
      expect(find.text('Plain task'), findsOneWidget);
      expect(find.text('Other'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zebra');
      await settle(tester);
      expect(find.text('Plain task'), findsOneWidget); // found through its comment
      expect(find.text('Other'), findsNothing);
      await finish(tester);
    });

    testWidgets('the task page sets a duration', (tester) async {
      await start(tester);
      final id = await tester.runAsync(() => repo.addTask(title: 'Write', dueDate: today()));
      await settle(tester);
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, 'No duration'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, '1h'));
      await settle(tester);
      final t = await tester.runAsync(() => repo.getTask(id!));
      expect(t!.durationMinutes, 60);
      expect(find.text('1h'), findsWidgets);
      await finish(tester);
    });

    testWidgets('Upcoming shows a week strip, and the help page is one tap from Browse', (tester) async {
      await start(tester);
      await tester.tap(find.text('Upcoming'));
      await settle(tester);
      expect(find.byTooltip('Next week'), findsOneWidget);
      expect(find.text('Mon'), findsOneWidget);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Help: Quick Add'));
      await tester.pumpAndSettle();
      expect(find.text('Quick Add'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Filters'), 400, scrollable: find.byType(Scrollable).first);
      expect(find.text('Filters'), findsOneWidget);
      await finish(tester);
    });
  });
}
