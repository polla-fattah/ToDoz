import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/ui/task_tree.dart';

void main() {
  late AppDatabase db;
  late Repo repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repo(db);
  });
  tearDown(() => db.close());

  Future<List<Task>> open() => repo.watchProjectTasks('inbox').first;

  test('sub-tasks follow their parent, indented by depth', () async {
    final a = await repo.addTask(title: 'a');
    final a1 = await repo.addTask(title: 'a1', parentId: a);
    await repo.addTask(title: 'a1x', parentId: a1);
    await repo.addTask(title: 'a2', parentId: a);
    await repo.addTask(title: 'b');
    final rows = flattenTasks(await open());
    expect(rows.map((r) => '${'-' * r.depth}${r.task.title}'), ['a', '-a1', '--a1x', '-a2', 'b']);
    expect(rows.first.hasChildren, isTrue);
    expect(rows.last.hasChildren, isFalse);
  });

  test('a collapsed task hides everything below it', () async {
    final a = await repo.addTask(title: 'a');
    await repo.addTask(title: 'a1', parentId: a);
    await repo.setTaskCollapsed(a, true);
    final rows = flattenTasks(await open());
    expect(rows.map((r) => r.task.title), ['a']);
    expect(rows.single.collapsed, isTrue);
    expect(rows.single.hasChildren, isTrue);
  });

  test('a task whose parent is not listed is shown at the top level', () async {
    final a = await repo.addTask(title: 'a');
    await repo.addTask(title: 'child', parentId: a);
    await repo.setCompleted(a, true); // parent completed, child still open
    final rows = flattenTasks(await open());
    expect(rows.map((r) => (r.task.title, r.depth)), [('child', 0)]);
  });

  test('keeps the incoming order among siblings', () async {
    final x = await repo.addTask(title: 'x');
    final y = await repo.addTask(title: 'y');
    final z = await repo.addTask(title: 'z');
    await repo.reorderTasks([z, x, y]);
    expect(flattenTasks(await open()).map((r) => r.task.title), ['z', 'x', 'y']);
  });
}
