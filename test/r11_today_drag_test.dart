import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/app.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/ui/catalog.dart';
import 'package:taskflow/ui/sidebar.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Moving tasks around from the Today list on a computer-sized window: carry one to a project or to Today in the sidebar.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late Repo repo;
  late Catalog catalog;
  late String work;
  late String late_;
  late String now_;
  final clock = DateTime(2026, 10, 19, 9, 0); // a Monday morning
  const today = '2026-10-19';

  Future<void> start(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repo(db, clock: () => clock);
      await db.ensureInbox();
      work = await repo.createProject(name: 'Work');
      late_ = await repo.addTask(title: 'Pay the invoice', dueDate: '2026-10-17');
      now_ = await repo.addTask(title: 'Call the bank', dueDate: today, dueTime: '17:00');
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

  Offset handleOf(WidgetTester tester, String title) {
    final handle = find.descendant(of: find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first, matching: find.byIcon(Icons.drag_indicator));
    expect(handle, findsOneWidget, reason: 'a drag handle on "$title"');
    return tester.getCenter(handle);
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 12; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 50));
    await g.up();
    await settle(tester);
  }

  Finder inSidebar(String text) => find.descendant(of: find.byType(Sidebar), matching: find.text(text));

  testWidgets('on a wide window the Today and Overdue tasks have a drag handle', (tester) async {
    await start(tester);
    expect(find.text('Pay the invoice'), findsOneWidget);
    expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
    await finish(tester);
  });

  testWidgets('on a phone there is no sidebar to carry a task to, so no handle', (tester) async {
    await start(tester, size: const Size(420, 900));
    expect(find.text('Call the bank'), findsOneWidget);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    await finish(tester);
  });

  testWidgets('dragging a task from Today onto a project in the sidebar moves it there, with Undo', (tester) async {
    await start(tester);
    await drag(tester, handleOf(tester, 'Call the bank'), tester.getCenter(inSidebar('Work')));
    final moved = await tester.runAsync(() => repo.getTask(now_));
    expect(moved!.projectId, work);
    expect(moved.dueDate, today, reason: 'only the project changes');
    expect(find.text('Moved to Work'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('dragging an overdue task onto Today in the sidebar plans it for today, with Undo', (tester) async {
    await start(tester);
    await drag(tester, handleOf(tester, 'Pay the invoice'), tester.getCenter(inSidebar('Today')));
    final planned = await tester.runAsync(() => repo.getTask(late_));
    expect(planned!.dueDate, today);
    expect(find.text('Planned for today'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    final back = await tester.runAsync(() => repo.getTask(late_));
    expect(back!.dueDate, '2026-10-17');
    await finish(tester);
  });
}
