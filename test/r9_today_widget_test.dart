import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/platform/today_widget.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late Repo repo;
  final now = DateTime(2026, 10, 19, 9, 30); // a Monday

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.ensureInbox();
    repo = Repo(db, clock: () => now);
  });
  tearDown(() => db.close());

  Future<List<Task>> today() => repo.watchToday('2026-10-19').first;

  test('lists what is due today and overdue, in the order the Today screen uses, with the date and a count', () async {
    await repo.addTask(title: 'Later today', dueDate: '2026-10-19', dueTime: '17:00');
    await repo.addTask(title: 'Late one', dueDate: '2026-10-17');
    await repo.addTask(title: 'No time', dueDate: '2026-10-19', priority: 1);
    await repo.addTask(title: 'Tomorrow', dueDate: '2026-10-20');
    await repo.addTask(title: 'Undated');

    final p = buildWidgetPayload(await today(), now: now, use24h: true);
    expect(p['date'], 'Mon 19 Oct');
    expect(p['total'], 3);
    final items = (p['items'] as List).cast<Map<String, Object?>>();
    expect(items.map((i) => i['title']), ['Late one', 'Later today', 'No time']);
    expect(items[0]['time'], 'Overdue');
    expect(items[0]['late'], isTrue);
    expect(items[1]['time'], '17:00');
    expect(items[1]['late'], isFalse);
    expect(items[2]['time'], isNull);
    expect(items[2]['p'], 1);
    expect(p['more'], 0);
    expect(items.every((i) => (i['id'] as String).isNotEmpty), isTrue, reason: 'the id is what a tap on the widget acts on');
  });

  test('shows the time the way the app is set to (12 or 24 hour)', () async {
    await repo.addTask(title: 'Call', dueDate: '2026-10-19', dueTime: '17:05');
    final tasks = await today();
    String time(bool h24) => ((buildWidgetPayload(tasks, now: now, use24h: h24)['items'] as List).single as Map)['time'] as String;
    expect(time(true), '17:05');
    expect(time(false), '5:05 PM');
  });

  test('shows at most six tasks and says how many more there are', () async {
    for (var i = 0; i < 9; i++) {
      await repo.addTask(title: 'Task $i', dueDate: '2026-10-19');
    }
    final p = buildWidgetPayload(await today(), now: now, use24h: true);
    expect(p['total'], 9);
    expect((p['items'] as List), hasLength(widgetRows));
    expect(p['more'], 3);
  });

  test('is empty on a day with nothing due, and survives being written as JSON', () async {
    final p = buildWidgetPayload(await today(), now: now, use24h: true);
    expect(p['total'], 0);
    expect(p['items'], isEmpty);
    expect(jsonDecode(jsonEncode(p)), p);
  });

  test('a task completed from the widget is gone from the next payload; a repeating one moves on', () async {
    final once = await repo.addTask(title: 'Once', dueDate: '2026-10-19');
    final weekly = await repo.addTask(title: 'Weekly', dueDate: '2026-10-19', recurrence: 'every week');
    await repo.completeTask(once);
    await repo.completeTask(weekly);
    final p = buildWidgetPayload(await today(), now: now, use24h: true);
    expect(p['total'], 0, reason: 'a repeating task goes to its next date, as in the app');
  });
}
