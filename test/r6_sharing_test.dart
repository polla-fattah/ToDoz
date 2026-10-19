import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/sync/share_notifier.dart';
import 'package:taskflow/sync/sync_engine.dart' show SyncTransportException;
import 'package:taskflow/sync/sync_service.dart';
import 'package:taskflow/sync/transport.dart';
import 'package:taskflow/ui/catalog.dart';
import 'package:taskflow_core/backup.dart' show inboxId;
import 'package:taskflow_core/filter.dart';
import 'package:taskflow_core/sharing.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/store.dart';

/// Two people, each with a phone (and Bob with a second), against the real server code over HTTP.
class Person {
  Person(this.name, this.account, this.db, this.repo, this.svc);
  final String name;
  final Account account;
  final AppDatabase db;
  final Repo repo;
  final SyncService svc;

  ServerApi get api => svc.api!;

  Future<void> sync() => svc.syncNow();
  Future<List<String>> titles() async => (await repo.watchAllOpen().first).map((t) => t.title).toList()..sort();
}

class RecordingAlerts implements ShareAlerts {
  final shown = <({int id, String title, String body, String? taskId})>[];
  @override
  Future<void> show({required int id, required String title, required String body, String? taskId}) async => shown.add((id: id, title: title, body: body, taskId: taskId));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Store server;
  late HttpServer httpServer;
  late String url;
  late Account aliceAccount;
  late Account bobAccount;
  late Person alice;
  late Person bob;
  var clock = DateTime(2026, 10, 19, 9);

  Future<Person> person(String name, Account account, {ShareAlerts? alerts}) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.ensureSyncMeta();
    await db.ensureInbox();
    final repo = Repo(db, clock: () => clock);
    final svc = SyncService(repo, MemoryTokenStore(), notifier: alerts == null ? null : ShareNotifier(repo, alerts), interval: const Duration(hours: 1), debounce: const Duration(hours: 1));
    addTearDown(svc.dispose);
    await svc.pair(url, server.createInvite(account.id), '$name phone');
    return Person(name, account, db, repo, svc);
  }

  setUp(() async {
    clock = DateTime(2026, 10, 19, 9);
    server = Store.open(':memory:');
    aliceAccount = server.createUser('Alice');
    bobAccount = server.createUser('Bob');
    httpServer = await io.serve(buildApi(server, config: const ApiConfig(syncPerMinute: 100000)), InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${httpServer.port}';
    alice = await person('Alice', aliceAccount);
    bob = await person('Bob', bobAccount);
  });
  tearDown(() async {
    await httpServer.close(force: true);
    server.close();
  });

  /// Alice makes "Home" with a task, invites Bob in [role], Bob joins, both sync.
  Future<String> shareHome({ShareRole role = ShareRole.member}) async {
    final p = await alice.repo.createProject(name: 'Home');
    await alice.repo.addTask(title: 'Buy bread', projectId: p, dueDate: '2026-10-19');
    await alice.sync();
    final code = await alice.api.createInvite(p, role);
    final joined = await bob.api.redeemInvite(code);
    expect(joined, p);
    await bob.sync();
    await alice.sync();
    return p;
  }

  group('joining', () {
    test('Bob gets the project and its tasks, knows his role, and sees who else is in it; Alice\'s private things stay private', () async {
      final secret = await alice.repo.createProject(name: 'Surprise party');
      await alice.repo.addTask(title: 'Book the cake', projectId: secret);
      await alice.repo.addTask(title: 'My inbox task');
      final p = await shareHome();

      expect((await bob.repo.getProject(p))!.name, 'Home');
      expect(await bob.titles(), ['Buy bread'], reason: 'only the shared project came over');
      expect(await bob.repo.getProject(secret), isNull);
      final shared = (await bob.repo.sharedProject(p))!;
      expect(shared.role, ShareRole.member);
      expect(shared.members.map((m) => m.name), unorderedEquals(['Alice', 'Bob']));
      expect(shared.nameOf(alice.repo.me!), 'Alice');
      expect((await alice.repo.sharedProject(p))!.role, ShareRole.owner);
      expect(alice.repo.me, aliceAccount.id);
      expect(bob.repo.me, bobAccount.id);
    });

    test('Bob\'s second phone gets the project too', () async {
      final p = await shareHome();
      final tablet = await person('Bob', bobAccount);
      await tablet.sync();
      expect(await tablet.titles(), ['Buy bread']);
      expect((await tablet.repo.sharedProject(p))!.role, ShareRole.member);
    });

    test('a wrong code is refused with a clear message', () async {
      await expectLater(bob.api.redeemInvite('AAAA-2222'), throwsA(isA<SyncTransportException>().having((e) => e.message, 'message', contains('wrong'))));
    });
  });

  group('working together', () {
    late String p;
    setUp(() async => p = await shareHome());

    test('tasks, edits and completions go both ways', () async {
      await bob.repo.addTask(title: 'Buy milk', projectId: p);
      await bob.sync();
      await alice.sync();
      expect(await alice.titles(), ['Buy bread', 'Buy milk']);

      final bread = (await alice.repo.watchProjectTasks(p).first).firstWhere((t) => t.title == 'Buy bread');
      await alice.repo.updateTask(bread.id, title: 'Buy sourdough bread');
      await alice.sync();
      await bob.sync();
      expect(await bob.titles(), ['Buy milk', 'Buy sourdough bread']);

      await bob.repo.completeTask(bread.id);
      await bob.sync();
      await alice.sync();
      expect((await alice.repo.getTask(bread.id))!.completedAt, isNotNull);
    });

    test('each person keeps their own favourites and layout for the project', () async {
      await bob.repo.updateProject(p, isFavorite: true);
      await bob.sync();
      await alice.sync();
      expect((await alice.repo.getProject(p))!.isFavorite, isFalse);
      expect((await bob.repo.getProject(p))!.isFavorite, isTrue);
    });

    test('my labels and reminders on a shared task stay mine', () async {
      final bread = (await bob.repo.watchProjectTasks(p).first).single;
      final label = await bob.repo.createLabel('mine');
      await bob.repo.updateTask(bread.id, labelIds: [label]);
      await bob.sync();
      await alice.sync();
      expect(await alice.repo.watchLabels().first, isEmpty);
      expect(await alice.repo.watchLabelLinks().first, isEmpty);
    });

    test('comments show who wrote them', () async {
      final bread = (await bob.repo.watchProjectTasks(p).first).single;
      await bob.repo.addComment(bread.id, 'Wholemeal, please');
      await bob.sync();
      await alice.sync();
      final c = (await alice.repo.watchComments(bread.id).first).single;
      expect((c.body, c.authorId), ('Wholemeal, please', bobAccount.id));
    });

    test('reactions: add, count, take back, and everyone sees them', () async {
      final bread = (await bob.repo.watchProjectTasks(p).first).single;
      await bob.repo.addComment(bread.id, 'Got it');
      await bob.sync();
      await alice.sync();
      final comment = (await alice.repo.watchComments(bread.id).first).single;
      await alice.repo.toggleReaction(comment.id, '👍');
      await bob.repo.toggleReaction(comment.id, '👍');
      await bob.repo.toggleReaction(comment.id, '🎉');
      await alice.sync();
      await bob.sync();
      await alice.sync();
      for (final who in [alice, bob]) {
        final r = await who.repo.watchTaskReactions(bread.id).first;
        expect(r.map((x) => '${x.emoji}:${x.userId == aliceAccount.id ? 'A' : 'B'}'), unorderedEquals(['👍:A', '👍:B', '🎉:B']));
      }
      await bob.repo.toggleReaction(comment.id, '👍'); // take it back
      await bob.sync();
      await alice.sync();
      expect((await alice.repo.watchTaskReactions(bread.id).first).map((x) => x.emoji), unorderedEquals(['👍', '🎉']));
      await expectLater(alice.repo.toggleReaction(comment.id, '💩'), throwsA(isA<RuleException>()));
    });
  });

  group('assignment', () {
    late String p;
    late String bread;
    setUp(() async {
      p = await shareHome();
      bread = (await alice.repo.watchProjectTasks(p).first).single.id;
    });

    test('Alice gives Bob a task: he sees who gave it, and it is in his Today but not hers', () async {
      await alice.repo.assignTask(bread, bobAccount.id);
      await alice.sync();
      await bob.sync();
      final t = (await bob.repo.getTask(bread))!;
      expect((t.assigneeId, t.assignedBy), (bobAccount.id, aliceAccount.id));
      expect((await bob.repo.watchToday('2026-10-19').first).map((x) => x.title), ['Buy bread']);
      expect(await alice.repo.watchToday('2026-10-19').first, isEmpty, reason: 'it is Bob\'s now, not hers');
      // Unassigned tasks and my own tasks show for everyone concerned.
      await alice.repo.assignTask(bread, null);
      await alice.sync();
      await bob.sync();
      expect((await alice.repo.watchToday('2026-10-19').first).length, 1);
      expect((await bob.repo.watchToday('2026-10-19').first).length, 1);
    });

    test('only a member of the project can be assigned', () async {
      await expectLater(alice.repo.assignTask(bread, 'someone-else'), throwsA(isA<RuleException>()));
      final private = await alice.repo.addTask(title: 'Private');
      await expectLater(alice.repo.assignTask(private, bobAccount.id), throwsA(isA<RuleException>()));
    });

    test('Quick Add understands +name in a shared project, and leaves it alone elsewhere', () async {
      final plan = await alice.repo.planQuickAdd('Call the plumber +bob tomorrow', defaultProjectId: p);
      expect(plan.parsed.title, 'Call the plumber');
      expect(plan.assigneeId, bobAccount.id);
      final id = await alice.repo.addFromPlan(plan);
      expect((await alice.repo.getTask(id))!.assigneeId, bobAccount.id);
      final plain = await alice.repo.planQuickAdd('Call +bob', defaultProjectId: inboxId);
      expect(plain.assigneeId, isNull);
      expect(plain.parsed.title, 'Call +bob');
    });

    test('the filters work on real shared data', () async {
      await alice.repo.assignTask(bread, bobAccount.id);
      await alice.repo.addTask(title: 'Mine', projectId: p);
      await alice.repo.addTask(title: 'Private', projectId: inboxId);
      final mine = (await alice.repo.watchProjectTasks(p).first).firstWhere((t) => t.title == 'Mine');
      await alice.repo.assignTask(mine.id, aliceAccount.id);
      final catalog = Catalog(alice.repo);
      addTearDown(catalog.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final tasks = await alice.repo.watchAllOpen().first;
      List<String> run(String q) {
        final f = parseFilter(q, catalog.filterEnv);
        return [for (final t in tasks) if (f.matches(catalog.filterTask(t))) t.title]..sort();
      }

      expect(run('assigned to: me'), ['Mine']);
      expect(run('assigned to: others'), ['Buy bread']);
      expect(run('assigned to: bob'), ['Buy bread']);
      expect(run('!assigned & shared'), isEmpty);
      expect(run('shared'), ['Buy bread', 'Mine']);
      expect(run('assigned by: me'), ['Buy bread', 'Mine'], reason: 'Alice assigned both');
    });
  });

  group('roles on the phone', () {
    test('a read-only person can look but not add, change, complete, delete, comment, assign or react', () async {
      final p = await shareHome(role: ShareRole.viewer);
      final bread = (await bob.repo.watchProjectTasks(p).first).single;
      expect((await bob.repo.sharedProject(p))!.role, ShareRole.viewer);
      Matcher blocked() => throwsA(isA<RuleException>().having((e) => e.message, 'message', contains('only look')));
      await expectLater(bob.repo.addTask(title: 'x', projectId: p), blocked());
      await expectLater(bob.repo.updateTask(bread.id, title: 'x'), blocked());
      await expectLater(bob.repo.completeTask(bread.id), blocked());
      await expectLater(bob.repo.deleteTask(bread.id), blocked());
      await expectLater(bob.repo.addComment(bread.id, 'hello'), blocked());
      await expectLater(bob.repo.assignTask(bread.id, bobAccount.id), blocked());
      await expectLater(bob.repo.moveTask(bread.id, projectId: inboxId), blocked());
      // Their own private projects are not affected.
      await bob.repo.addTask(title: 'my own thing');
    });

    test('a member can do tasks but not rename the project or add sections; an admin can', () async {
      final p = await shareHome(role: ShareRole.member);
      await expectLater(bob.repo.updateProject(p, name: 'Mine now'), throwsA(isA<RuleException>()));
      await expectLater(bob.repo.createSection(p, 'Garden'), throwsA(isA<RuleException>()));
      await bob.repo.updateProject(p, isFavorite: true); // personal: allowed
      await bob.repo.addTask(title: 'fine', projectId: p);
      await alice.api.setMemberRole(p, bobAccount.id, ShareRole.admin);
      await bob.sync();
      await bob.repo.updateProject(p, name: 'Family home');
      await bob.repo.createSection(p, 'Garden');
      await bob.sync();
      await alice.sync();
      expect((await alice.repo.getProject(p))!.name, 'Family home');
      expect((await alice.repo.watchSections(p).first).single.name, 'Garden');
    });

    test('a role change reaches the phone at the next sync', () async {
      final p = await shareHome(role: ShareRole.member);
      await alice.api.setMemberRole(p, bobAccount.id, ShareRole.viewer);
      await bob.sync();
      expect((await bob.repo.sharedProject(p))!.role, ShareRole.viewer);
      await expectLater(bob.repo.addTask(title: 'x', projectId: p), throwsA(isA<RuleException>()));
    });
  });

  group('leaving and removal', () {
    test('Bob leaves: the project goes from his phone, his tasks stay for Alice and are unassigned', () async {
      final p = await shareHome();
      final bread = (await alice.repo.watchProjectTasks(p).first).single.id;
      await bob.repo.addTask(title: 'Bob\'s task', projectId: p);
      final bobsTask = (await bob.repo.watchProjectTasks(p).first).firstWhere((t) => t.title == 'Bob\'s task').id;
      await bob.repo.assignTask(bobsTask, bobAccount.id);
      await alice.repo.assignTask(bread, bobAccount.id);
      await bob.sync();
      await alice.sync();

      await bob.api.removeMember(p, 'me');
      await bob.sync();
      await alice.sync();

      expect(await bob.repo.getProject(p), isNull, reason: 'gone from his phone');
      expect(await bob.titles(), isEmpty);
      expect(await bob.repo.sharedProject(p), isNull);
      expect(await bob.db.select(bob.db.taskLabels).get(), isEmpty);
      expect(await alice.titles(), ['Bob\'s task', 'Buy bread'], reason: 'the project\'s data stays');
      expect((await alice.repo.getTask(bobsTask))!.assigneeId, isNull);
      expect((await alice.repo.getTask(bread))!.assigneeId, isNull);
      expect((await alice.repo.sharedProject(p)), isNull, reason: 'nobody left to share with, so it is private again');
    });

    test('Alice removes Bob, then invites him again with a new code', () async {
      final p = await shareHome();
      await alice.api.removeMember(p, bobAccount.id);
      await bob.sync();
      expect(await bob.repo.getProject(p), isNull);
      final code = await alice.api.createInvite(p, ShareRole.viewer);
      await bob.api.redeemInvite(code);
      await bob.sync();
      expect((await bob.repo.getProject(p))!.name, 'Home');
      expect((await bob.repo.sharedProject(p))!.role, ShareRole.viewer);
    });

    test('Alice stops sharing: Bob loses the project and Alice keeps it', () async {
      final p = await shareHome();
      await alice.api.stopSharing(p);
      await bob.sync();
      await alice.sync();
      expect(await bob.repo.getProject(p), isNull);
      expect((await alice.repo.getProject(p))!.name, 'Home');
      expect(await alice.titles(), ['Buy bread']);
    });

    test('unpairing makes shared projects ordinary local ones, editable again', () async {
      final p = await shareHome(role: ShareRole.viewer);
      await bob.svc.unpair();
      expect(await bob.repo.sharedProject(p), isNull);
      expect(bob.repo.me, isNull);
      await bob.repo.addTask(title: 'now allowed', projectId: p);
    });
  });

  group('notifications', () {
    test('a new comment and a new assignment from someone else are announced once; the first look is silent', () async {
      final alerts = RecordingAlerts();
      final carol = server.createUser('Carol');
      final watcher = await person('Carol', carol, alerts: alerts);
      final p = await alice.repo.createProject(name: 'Home');
      final t = await alice.repo.addTask(title: 'Buy bread', projectId: p);
      await alice.sync();
      await alice.repo.addComment(t, 'An old comment before Carol joined');
      await alice.sync();
      await watcher.api.redeemInvite(await alice.api.createInvite(p, ShareRole.member));
      await watcher.sync();
      await alice.sync(); // Alice learns Carol is a member
      expect(alerts.shown, isEmpty, reason: 'history is not announced');

      await alice.repo.addComment(t, 'Please get rye');
      await alice.repo.assignTask(t, carol.id);
      await alice.sync();
      await watcher.sync();
      expect(alerts.shown.map((a) => a.title), unorderedEquals(['Alice commented on "Buy bread"', 'Alice assigned you a task']));
      expect(alerts.shown.firstWhere((a) => a.title.contains('commented')).body, 'Please get rye');
      expect(alerts.shown.every((a) => a.taskId == t), isTrue);

      alerts.shown.clear();
      await watcher.sync();
      expect(alerts.shown, isEmpty, reason: 'announced once');
      // My own comments and my own assignments are not news.
      await watcher.repo.addComment(t, 'On it');
      await watcher.repo.assignTask(t, carol.id);
      await watcher.sync();
      expect(alerts.shown, isEmpty);
    });

    test('a burst is summarised after a few', () async {
      final alerts = RecordingAlerts();
      final carol = server.createUser('Carol');
      final watcher = await person('Carol', carol, alerts: alerts);
      final p = await alice.repo.createProject(name: 'Home');
      final t = await alice.repo.addTask(title: 'T', projectId: p);
      await alice.sync();
      await watcher.api.redeemInvite(await alice.api.createInvite(p, ShareRole.member));
      await watcher.sync();
      await alice.sync();
      for (var i = 0; i < 8; i++) {
        await alice.repo.addComment(t, 'comment $i');
      }
      await alice.sync();
      await watcher.sync();
      expect(alerts.shown.length, 6, reason: 'five alerts and one summary');
      expect(alerts.shown.last.title, '3 more updates in shared projects');
    });
  });
}
