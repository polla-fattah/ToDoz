import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/core/date_parser.dart';
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

  Future<void> start(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900)); // phone layout
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
}
