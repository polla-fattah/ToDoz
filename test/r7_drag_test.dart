import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow_core/view_options.dart';
import 'package:taskflow/app.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/ui/catalog.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Moving tasks between sections and putting them in a manual order, on a phone-sized screen.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late Repo repo;
  late Catalog catalog;
  late String project;
  late String todo;
  late String doing;
  late String done;
  final ids = <String, String>{};

  Future<void> start(WidgetTester tester, {ViewOptions? options, Size size = const Size(420, 900), int filler = 0}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repo(db);
      await db.ensureInbox();
      project = await repo.createProject(name: 'Work');
      todo = await repo.createSection(project, 'Todo');
      doing = await repo.createSection(project, 'Doing');
      done = await repo.createSection(project, 'Finished');
      ids['a'] = await repo.addTask(title: 'Alpha', projectId: project, sectionId: todo);
      ids['b'] = await repo.addTask(title: 'Bravo', projectId: project, sectionId: todo);
      ids['c'] = await repo.addTask(title: 'Charlie', projectId: project, sectionId: doing);
      for (var i = 0; i < filler; i++) {
        await repo.addTask(title: 'Filler $i', projectId: project, sectionId: doing);
      }
      if (options != null) await repo.setProjectViewOptions(project, options);
    });
    catalog = Catalog(repo);
    await tester.pumpWidget(TaskFlowApp(catalog: catalog));
    await settle(tester);
    if (size.width > 900) {
      await tester.tap(find.text('Work').first); // a wide window has the project list in a sidebar
    } else {
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work'));
    }
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    catalog.dispose();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  /// Titles in [section], in the order the tasks are stored.
  Future<List<String>> titles(WidgetTester tester, String? section) async {
    final rows = await tester.runAsync(() => repo.watchProjectTasks(project).first);
    return [
      for (final t in (rows!.where((t) => t.sectionId == section).toList()..sort((x, y) => x.sortOrder.compareTo(y.sortOrder)))) t.title,
    ];
  }

  /// Presses [from], drags to [to] in small steps and lets go.
  Future<void> drag(WidgetTester tester, Offset from, Offset to, {int steps = 12}) async {
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= steps; i++) {
      await g.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 50));
    await g.up();
    await settle(tester);
  }

  Offset handleOf(WidgetTester tester, String title) {
    final tile = find.ancestor(of: find.text(title), matching: find.byType(Row)).first;
    final handle = find.descendant(of: find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first, matching: find.byIcon(Icons.drag_indicator));
    expect(handle, findsOneWidget, reason: 'a drag handle on "$title" ($tile)');
    return tester.getCenter(handle);
  }

  group('list view', () {
    testWidgets('every top-level task has a drag handle', (tester) async {
      await start(tester);
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(3));
      await finish(tester);
    });

    testWidgets('dragging a task onto a task in another section moves it there, ahead of that task', (tester) async {
      await start(tester);
      await drag(tester, handleOf(tester, 'Alpha'), tester.getCenter(find.text('Charlie')));
      expect(await titles(tester, doing), ['Alpha', 'Charlie']);
      expect(await titles(tester, todo), ['Bravo']);
      await finish(tester);
    });

    testWidgets('dropping on a section heading puts the task at the top of that section, even an empty one', (tester) async {
      await start(tester);
      await drag(tester, handleOf(tester, 'Bravo'), tester.getCenter(find.textContaining('Finished')));
      expect(await titles(tester, done), ['Bravo']);
      expect(await titles(tester, todo), ['Alpha']);
      await drag(tester, handleOf(tester, 'Charlie'), tester.getCenter(find.textContaining('Todo')));
      expect(await titles(tester, todo), ['Charlie', 'Alpha']);
      await finish(tester);
    });

    testWidgets('dragging within a section changes the manual order, and it survives a rebuild', (tester) async {
      await start(tester);
      await drag(tester, handleOf(tester, 'Bravo'), tester.getCenter(find.text('Alpha')));
      expect(await titles(tester, todo), ['Bravo', 'Alpha']);
      // The list on screen follows.
      expect(tester.getCenter(find.text('Bravo')).dy, lessThan(tester.getCenter(find.text('Alpha')).dy));
      await finish(tester);
    });

    testWidgets('a task can be dropped at the end of a section (after the last task)', (tester) async {
      await start(tester);
      // The space under Bravo (the last task of Todo) is the end of Todo.
      final below = tester.getCenter(find.text('Bravo')) + const Offset(0, 40);
      await drag(tester, handleOf(tester, 'Alpha'), below);
      expect(await titles(tester, todo), ['Bravo', 'Alpha']);
      await finish(tester);
    });

    testWidgets('in an automatically sorted list a move between sections works but reordering is explained', (tester) async {
      await start(tester, options: const ViewOptions(sort: SortBy.name));
      await drag(tester, handleOf(tester, 'Bravo'), tester.getCenter(find.text('Alpha')));
      expect(find.textContaining('Choose Manual'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await drag(tester, handleOf(tester, 'Alpha'), tester.getCenter(find.text('Charlie')));
      expect(await titles(tester, doing), contains('Alpha'));
      await finish(tester);
    });

    testWidgets('a task with sub-tasks moves together with them', (tester) async {
      await start(tester);
      await tester.runAsync(() => repo.addTask(title: 'Sub of Alpha', projectId: project, parentId: ids['a']));
      await settle(tester);
      await drag(tester, handleOf(tester, 'Alpha'), tester.getCenter(find.text('Charlie')));
      final sub = await tester.runAsync(() => repo.watchProjectTasks(project).first);
      expect(sub!.firstWhere((t) => t.title == 'Sub of Alpha').sectionId, doing);
      expect(await titles(tester, doing), contains('Alpha'));
      await finish(tester);
    });

    testWidgets('a task dragged near the bottom edge scrolls the list so a far section can be reached', (tester) async {
      await start(tester, filler: 12);
      tester.view.physicalSize = const Size(420, 520); // short enough that the last section is off screen
      await settle(tester);
      expect(find.textContaining('Finished'), findsNothing, reason: 'the last section starts off screen');
      final g = await tester.startGesture(handleOf(tester, 'Alpha'));
      await tester.pump(const Duration(milliseconds: 50));
      await g.moveTo(const Offset(200, 480));
      double headingY() => find.textContaining('Finished').evaluate().isEmpty ? 9999 : tester.getCenter(find.textContaining('Finished')).dy;
      for (var i = 0; i < 200 && headingY() > 330; i++) {
        await g.moveBy(const Offset(0, 0.1));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(headingY(), lessThan(340), reason: 'the list scrolled by itself');
      await g.moveTo(Offset(200, headingY()));
      await tester.pump(const Duration(milliseconds: 20));
      await g.up();
      await settle(tester);
      expect(await titles(tester, done), ['Alpha']);
      await finish(tester);
    });
  });

  group('board view on a phone', () {
    testWidgets('a card can be carried to a column that starts off screen', (tester) async {
      await start(tester, options: const ViewOptions(layout: ViewLayout.board));
      // Columns are 290 wide and the phone 420: "Finished" (the fourth) is not even on screen.
      expect(find.textContaining('Finished'), findsNothing);
      final g = await tester.startGesture(tester.getCenter(find.text('Alpha')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await g.moveTo(const Offset(400, 300));
      double leftOfFinished() => find.textContaining('Finished').evaluate().isEmpty ? 9999 : tester.getTopLeft(find.textContaining('Finished')).dx;
      for (var i = 0; i < 300 && leftOfFinished() > 250; i++) {
        await g.moveBy(const Offset(0.2, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(leftOfFinished(), lessThan(300), reason: 'the board scrolled by itself');
      await g.moveTo(tester.getCenter(find.textContaining('Finished')) + const Offset(0, 120));
      await tester.pump();
      await g.up();
      await settle(tester);
      expect(await titles(tester, done), ['Alpha']);
      await finish(tester);
    });
  });

  group('wide screens', () {
    testWidgets('dragging a task onto a project in the sidebar moves it there, and Undo brings it back', (tester) async {
      await start(tester, size: const Size(1200, 800));
      // The project list is permanent on a wide window. Add another project to drop on.
      final other = await tester.runAsync(() => repo.createProject(name: 'Garden'));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Garden'), findsOneWidget, reason: 'the sidebar lists the other project');

      await drag(tester, handleOf(tester, 'Alpha'), tester.getCenter(find.text('Garden')));
      var t = await tester.runAsync(() => repo.getTask(ids['a']!));
      expect(t!.projectId, other);
      expect(t.sectionId, isNull);
      expect(find.text('Moved to Garden'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await settle(tester);
      t = await tester.runAsync(() => repo.getTask(ids['a']!));
      expect(t!.projectId, project);
      expect(t.sectionId, todo);
      await finish(tester);
    });
  });
}
