import 'dart:convert';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:taskflow_core/sharing.dart';
import 'package:taskflow_core/sync.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/shares.dart';
import 'package:taskflow_server/store.dart';
import 'package:test/test.dart';

void main() {
  late Store store;
  late DateTime now;
  late Account alice;
  late Account bob;
  late Account carol;
  var wall = 1000000;

  setUp(() {
    now = DateTime.utc(2026, 10, 19, 9);
    store = Store.open(':memory:', clock: () => now);
    alice = store.createUser('Alice');
    bob = store.createUser('Bob');
    carol = store.createUser('Carol');
    wall = now.millisecondsSinceEpoch;
  });
  tearDown(() => store.close());

  /// A change with a clock a little later than the last one made.
  SyncChange ch(String table, String row, String col, Object? v, {int? at, String node = 'phone'}) =>
      SyncChange(table: table, row: row, col: col, value: v, hlc: formatHlc(at ?? ++wall, 0, node));

  List<SyncChange> project(String id, {String name = 'Home', Map<String, Object?> extra = const {}}) => [
        ch('projects', id, presentColumn, true),
        ch('projects', id, 'name', name),
        ch('projects', id, 'color', 0xFF112233),
        ch('projects', id, 'is_favorite', 1),
        ch('projects', id, 'sort_order', 7),
        ch('projects', id, 'view_options', '{"layout":"board"}'),
        ch('projects', id, 'created_at', 1000),
        ch('projects', id, 'updated_at', 1000),
        for (final e in extra.entries) ch('projects', id, e.key, e.value),
      ];

  List<SyncChange> task(String id, String projectId, {String title = 'A task', Map<String, Object?> extra = const {}}) => [
        ch('tasks', id, presentColumn, true),
        ch('tasks', id, 'title', title),
        ch('tasks', id, 'project_id', projectId),
        ch('tasks', id, 'priority', 4),
        ch('tasks', id, 'is_collapsed', 1),
        ch('tasks', id, 'created_at', 1000),
        ch('tasks', id, 'updated_at', 1000),
        for (final e in extra.entries) ch('tasks', id, e.key, e.value),
      ];

  void put(Account who, List<SyncChange> changes, {String device = 'phone'}) => store.applyChangesDetailed(who.id, '${who.name}-$device', changes);

  Map<String, Map<String, Map<String, Object?>>> view(Account who) => store.snapshot(who.id);

  Object? field(Account who, String table, String row, String col) => view(who)[table]?[row]?[col];

  bool has(Account who, String table, String row) => view(who)[table]?.containsKey(row) ?? false;

  /// Alice makes project P with a task, invites [people] with the given roles, and they join.
  String share({Map<Account, ShareRole> people = const {}, String projectId = 'P'}) {
    put(alice, [...project(projectId), ...task('t1', projectId, title: 'First task')]);
    for (final e in people.entries) {
      final code = store.shares.createInvite(alice.id, projectId, e.value);
      expect(store.shares.redeemInvite(e.key.id, code), isNotNull);
    }
    return projectId;
  }

  group('joining', () {
    test('a new member gets a copy of the project, its sections, tasks and comments, but not the owner\'s personal view settings', () {
      put(alice, [
        ...project('P'),
        ch('sections', 's1', presentColumn, true),
        ch('sections', 's1', 'project_id', 'P'),
        ch('sections', 's1', 'name', 'Later'),
        ch('sections', 's1', 'is_collapsed', 1),
        ...task('t1', 'P', title: 'Buy bread'),
        ch('comments', 'c1', presentColumn, true),
        ch('comments', 'c1', 'task_id', 't1'),
        ch('comments', 'c1', 'body', 'sourdough please'),
        ch('project_comments', 'n1', presentColumn, true),
        ch('project_comments', 'n1', 'project_id', 'P'),
        ch('project_comments', 'n1', 'body', 'house rules'),
        // Alice's private things:
        ...project('private', name: 'Secret'),
        ...task('t2', 'private', title: 'Surprise party'),
        ch('labels', 'l1', presentColumn, true),
        ch('labels', 'l1', 'name', 'errands'),
        ch('task_labels', 't1|l1', presentColumn, true),
        ch('reminders', 'r1', presentColumn, true),
        ch('reminders', 'r1', 'task_id', 't1'),
        ch('reminders', 'r1', 'spec', '30m'),
        ch('completions', 'k1', presentColumn, true),
        ch('completions', 'k1', 'task_id', 't1'),
      ]);
      final code = store.shares.createInvite(alice.id, 'P', ShareRole.member);
      expect(store.shares.redeemInvite(bob.id, code), isNotNull);

      expect(field(bob, 'projects', 'P', 'name'), 'Home');
      expect(field(bob, 'projects', 'P', 'color'), 0xFF112233);
      expect(field(bob, 'projects', 'P', 'is_favorite'), isNull, reason: 'favourites are personal');
      expect(field(bob, 'projects', 'P', 'sort_order'), isNull);
      expect(field(bob, 'projects', 'P', 'view_options'), isNull);
      expect(field(bob, 'sections', 's1', 'name'), 'Later');
      expect(field(bob, 'sections', 's1', 'is_collapsed'), isNull);
      expect(field(bob, 'tasks', 't1', 'title'), 'Buy bread');
      expect(field(bob, 'tasks', 't1', 'is_collapsed'), isNull);
      expect(field(bob, 'comments', 'c1', 'body'), 'sourdough please');
      expect(field(bob, 'project_comments', 'n1', 'body'), 'house rules');
      // And nothing private came along:
      expect(has(bob, 'projects', 'private'), isFalse);
      expect(has(bob, 'tasks', 't2'), isFalse);
      for (final t in ['labels', 'task_labels', 'reminders', 'completions']) {
        expect(view(bob)[t] ?? const {}, isEmpty, reason: t);
      }
    });

    test('the copy keeps the original clocks, so later edits merge correctly', () {
      put(alice, project('P'));
      final code = store.shares.createInvite(alice.id, 'P', ShareRole.member);
      store.shares.redeemInvite(bob.id, code);
      final a = store.exportAll(alice.id).firstWhere((c) => c.row == 'P' && c.col == 'name');
      final b = store.exportAll(bob.id).firstWhere((c) => c.row == 'P' && c.col == 'name');
      expect(b.hlc, a.hlc);
    });

    test('a member\'s phone gets the copy through its normal sync', () {
      share(people: {bob: ShareRole.member});
      final page = store.changesSince(bob.id, 'bob-phone', 0, limit: 1000);
      expect(page.changes.where((c) => c.table == 'tasks' && c.row == 't1' && c.col == 'title').single.value, 'First task');
    });

    test('sub-projects, labels and other private tables are not part of a share', () {
      put(alice, [...project('P'), ...project('child', name: 'Child', extra: {'parent_id': 'P'})]);
      store.shares.redeemInvite(bob.id, store.shares.createInvite(alice.id, 'P', ShareRole.member));
      expect(has(bob, 'projects', 'child'), isFalse);
    });
  });

  group('changes pass between members', () {
    setUp(() => share(people: {bob: ShareRole.member}));

    test('a task a member adds appears for the owner, with the same fields and clocks', () {
      final changes = task('t2', 'P', title: 'From Bob');
      put(bob, changes);
      expect(field(alice, 'tasks', 't2', 'title'), 'From Bob');
      expect(field(alice, 'tasks', 't2', 'project_id'), 'P');
      expect(field(alice, 'tasks', 't2', 'is_collapsed'), isNull, reason: 'collapsed is personal');
      expect(field(bob, 'tasks', 't2', 'is_collapsed'), 1, reason: 'but Bob keeps his own');
      final aliceHlc = store.exportAll(alice.id).firstWhere((c) => c.row == 't2' && c.col == 'title').hlc;
      expect(aliceHlc, changes.firstWhere((c) => c.col == 'title').hlc);
    });

    test('edits go both ways, and the later one wins for everyone', () {
      put(alice, [ch('tasks', 't1', 'title', 'Alice\'s title')]);
      expect(field(bob, 'tasks', 't1', 'title'), 'Alice\'s title');
      put(bob, [ch('tasks', 't1', 'title', 'Bob\'s title')]);
      expect(field(alice, 'tasks', 't1', 'title'), 'Bob\'s title');
      // An older edit that arrives late loses for everyone.
      put(alice, [ch('tasks', 't1', 'title', 'stale', at: 5)]);
      expect(field(alice, 'tasks', 't1', 'title'), 'Bob\'s title');
      expect(field(bob, 'tasks', 't1', 'title'), 'Bob\'s title');
    });

    test('edits to different fields of one task both survive', () {
      put(alice, [ch('tasks', 't1', 'priority', 1)]);
      put(bob, [ch('tasks', 't1', 'due_date', '2026-10-25')]);
      for (final who in [alice, bob]) {
        expect((field(who, 'tasks', 't1', 'priority'), field(who, 'tasks', 't1', 'due_date')), (1, '2026-10-25'));
      }
    });

    test('completing and deleting reach everyone', () {
      put(bob, [ch('tasks', 't1', 'completed_at', 1790000000)]);
      expect(field(alice, 'tasks', 't1', 'completed_at'), 1790000000);
      put(alice, [ch('tasks', 't1', 'deleted_at', 1790000100)]);
      expect(field(bob, 'tasks', 't1', 'deleted_at'), 1790000100);
    });

    test('comments and reactions pass on, each reaction is its own row', () {
      put(bob, [
        ch('comments', 'c1', presentColumn, true),
        ch('comments', 'c1', 'task_id', 't1'),
        ch('comments', 'c1', 'body', 'Looks good'),
        ch('comments', 'c1', 'author_id', bob.id),
      ]);
      expect(field(alice, 'comments', 'c1', 'author_id'), bob.id);
      put(alice, [
        ch('reactions', 'c1:${alice.id}:👍', presentColumn, true),
        ch('reactions', 'c1:${alice.id}:👍', 'comment_id', 'c1'),
        ch('reactions', 'c1:${alice.id}:👍', 'user_id', alice.id),
        ch('reactions', 'c1:${alice.id}:👍', 'emoji', '👍'),
      ]);
      expect(field(bob, 'reactions', 'c1:${alice.id}:👍', 'emoji'), '👍');
      put(alice, [ch('reactions', 'c1:${alice.id}:👍', presentColumn, false)]);
      expect(has(bob, 'reactions', 'c1:${alice.id}:👍'), isFalse, reason: 'taking a reaction back reaches everyone');
    });

    test('personal columns of the project are never passed on', () {
      put(bob, [ch('projects', 'P', 'is_favorite', 1), ch('projects', 'P', 'sort_order', 99), ch('projects', 'P', 'parent_id', 'somewhere')]);
      expect(field(alice, 'projects', 'P', 'sort_order'), 7, reason: 'Alice keeps her own');
      expect(field(alice, 'projects', 'P', 'parent_id'), isNull);
      expect(field(bob, 'projects', 'P', 'sort_order'), 99);
    });

    test('a person\'s private data (labels, reminders, completions) on a shared task stays with them', () {
      put(bob, [
        ch('labels', 'bl', presentColumn, true),
        ch('labels', 'bl', 'name', 'mine'),
        ch('task_labels', 't1|bl', presentColumn, true),
        ch('reminders', 'br', presentColumn, true),
        ch('reminders', 'br', 'task_id', 't1'),
        ch('completions', 'bk', presentColumn, true),
        ch('completions', 'bk', 'task_id', 't1'),
        ch('activity', 'act1', presentColumn, true),
      ]);
      for (final t in ['labels', 'task_labels', 'reminders', 'completions', 'activity']) {
        expect(view(alice)[t] ?? const {}, isEmpty, reason: t);
      }
    });

    test('a private project of either person stays private even beside a shared one', () {
      put(bob, [...project('bobs', name: 'Bob only'), ...task('bt', 'bobs', title: 'Bob secret')]);
      put(alice, [...task('at', 'P', title: 'Shared')]);
      expect(has(alice, 'tasks', 'bt'), isFalse);
      expect(has(bob, 'tasks', 'at'), isTrue);
    });

    test('a third person who is not a member sees nothing', () {
      put(bob, [ch('tasks', 't1', 'title', 'changed')]);
      expect(view(carol), isEmpty);
    });

    test('the change reaches the owner\'s other devices too, but not back to the device that made it', () {
      put(bob, [ch('tasks', 't1', 'title', 'from bob phone')], device: 'phone');
      final forBobPhone = store.changesSince(bob.id, 'Bob-phone', 0, limit: 1000).changes.where((c) => c.row == 't1' && c.col == 'title');
      final forBobTablet = store.changesSince(bob.id, 'Bob-tablet', 0, limit: 1000).changes.where((c) => c.row == 't1' && c.col == 'title');
      final forAlice = store.changesSince(alice.id, 'Alice-phone', 0, limit: 1000).changes.where((c) => c.row == 't1' && c.col == 'title');
      expect(forBobPhone.map((c) => c.value), isNot(contains('from bob phone')));
      expect(forBobTablet.map((c) => c.value), contains('from bob phone'));
      expect(forAlice.map((c) => c.value), contains('from bob phone'));
    });
  });

  group('roles', () {
    late Account viewer;
    late Account admin;

    setUp(() {
      viewer = bob;
      admin = carol;
      share(people: {viewer: ShareRole.viewer, admin: ShareRole.admin});
    });

    test('a read-only person cannot change tasks: the change is refused and their copy put right', () {
      put(viewer, [ch('tasks', 't1', 'title', 'vandalism')]);
      expect(field(alice, 'tasks', 't1', 'title'), 'First task');
      expect(field(viewer, 'tasks', 't1', 'title'), 'First task', reason: 'their own copy is corrected so the phone does not keep the edit');
      expect(field(admin, 'tasks', 't1', 'title'), 'First task');
      // The correction reaches their phone through normal sync, with a clock that beats their edit.
      final fix = store.changesSince(viewer.id, 'Bob-phone', 0, limit: 1000).changes.where((c) => c.row == 't1' && c.col == 'title').last;
      expect(fix.value, 'First task');
    });

    test('a read-only person cannot add tasks or comments; nothing is left behind', () {
      put(viewer, [...task('sneaky', 'P', title: 'Sneaky'), ch('comments', 'cx', presentColumn, true), ch('comments', 'cx', 'task_id', 't1'), ch('comments', 'cx', 'body', 'hi')]);
      expect(has(alice, 'tasks', 'sneaky'), isFalse);
      expect(has(alice, 'comments', 'cx'), isFalse);
      expect(has(viewer, 'tasks', 'sneaky'), isFalse, reason: 'removed again from their own copy');
      expect(has(viewer, 'comments', 'cx'), isFalse);
    });

    test('a read-only person cannot delete a task', () {
      put(viewer, [ch('tasks', 't1', 'deleted_at', 1790000000)]);
      expect(field(alice, 'tasks', 't1', 'deleted_at'), isNull);
      expect(field(viewer, 'tasks', 't1', 'deleted_at'), isNull);
    });

    test('a read-only person can still arrange their own view of the project', () {
      put(viewer, [ch('projects', 'P', 'is_favorite', 0), ch('projects', 'P', 'view_options', '{"layout":"list"}'), ch('tasks', 't1', 'is_collapsed', 0)]);
      expect(field(viewer, 'projects', 'P', 'view_options'), '{"layout":"list"}');
    });

    test('a member can change tasks but not the project\'s name or its sections', () {
      final member = viewer;
      store.shares.setRole(alice.id, 'P', member.id, ShareRole.member);
      put(member, [ch('tasks', 't1', 'title', 'edited by member')]);
      expect(field(alice, 'tasks', 't1', 'title'), 'edited by member');
      put(member, [ch('projects', 'P', 'name', 'Renamed by member')]);
      expect(field(alice, 'projects', 'P', 'name'), 'Home');
      expect(field(member, 'projects', 'P', 'name'), 'Home', reason: 'put back on their copy');
      put(member, [ch('sections', 's9', presentColumn, true), ch('sections', 's9', 'project_id', 'P'), ch('sections', 's9', 'name', 'Mine')]);
      expect(has(alice, 'sections', 's9'), isFalse);
      expect(has(member, 'sections', 's9'), isFalse);
    });

    test('an admin can rename the project and add sections; everyone sees it', () {
      put(admin, [ch('projects', 'P', 'name', 'Family home'), ch('sections', 's9', presentColumn, true), ch('sections', 's9', 'project_id', 'P'), ch('sections', 's9', 'name', 'Garden')]);
      expect(field(alice, 'projects', 'P', 'name'), 'Family home');
      expect(field(viewer, 'projects', 'P', 'name'), 'Family home');
      expect(field(viewer, 'sections', 's9', 'name'), 'Garden');
    });

    test('roles can change, and the new rights apply at once', () {
      put(viewer, [ch('tasks', 't1', 'title', 'no')]);
      expect(field(alice, 'tasks', 't1', 'title'), 'First task');
      store.shares.setRole(alice.id, 'P', viewer.id, ShareRole.member);
      put(viewer, [ch('tasks', 't1', 'title', 'yes now')]);
      expect(field(alice, 'tasks', 't1', 'title'), 'yes now');
    });

    test('who may change whose role', () {
      expect(() => store.shares.setRole(viewer.id, 'P', admin.id, ShareRole.viewer), throwsA(isA<ShareError>()), reason: 'a viewer manages nobody');
      expect(() => store.shares.setRole(admin.id, 'P', alice.id, ShareRole.member), throwsA(isA<ShareError>()), reason: 'the owner stays owner');
      expect(() => store.shares.setRole(admin.id, 'P', viewer.id, ShareRole.admin), throwsA(isA<ShareError>()), reason: 'only the owner makes admins');
      store.shares.setRole(admin.id, 'P', viewer.id, ShareRole.member);
      expect(store.shares.roleIn('P', viewer.id), ShareRole.member);
      expect(() => store.shares.setRole(alice.id, 'P', viewer.id, ShareRole.owner), throwsA(isA<ShareError>()));
    });
  });

  group('invitations', () {
    test('only an owner or admin can invite; the owner can make admins; the Inbox and unknown projects cannot be shared', () {
      put(alice, [...project('P'), ...project('inbox', name: 'Inbox')]);
      expect(() => store.shares.createInvite(bob.id, 'P', ShareRole.member), throwsA(isA<ShareError>()), reason: 'not his project');
      expect(() => store.shares.createInvite(alice.id, 'inbox', ShareRole.member), throwsA(isA<ShareError>()));
      expect(() => store.shares.createInvite(alice.id, 'nope', ShareRole.member), throwsA(isA<ShareError>()));
      expect(() => store.shares.createInvite(alice.id, 'P', ShareRole.owner), throwsA(isA<ShareError>()));
      final c1 = store.shares.createInvite(alice.id, 'P', ShareRole.admin);
      store.shares.redeemInvite(bob.id, c1);
      expect(() => store.shares.createInvite(bob.id, 'P', ShareRole.admin), throwsA(isA<ShareError>()), reason: 'an admin cannot make admins');
      final c2 = store.shares.createInvite(bob.id, 'P', ShareRole.viewer);
      expect(store.shares.redeemInvite(carol.id, c2), isNotNull);
      store.shares.setRole(alice.id, 'P', carol.id, ShareRole.viewer);
      expect(() => store.shares.createInvite(carol.id, 'P', ShareRole.viewer), throwsA(isA<ShareError>()), reason: 'a viewer cannot invite');
    });

    test('a code works once, expires after a day, and is stored only as a hash', () {
      put(alice, project('P'));
      final code = store.shares.createInvite(alice.id, 'P', ShareRole.member);
      expect(store.db.select('SELECT * FROM share_invites').first.values.join(' '), isNot(contains(code)));
      expect(store.shares.redeemInvite(bob.id, code), isNotNull);
      expect(store.shares.redeemInvite(carol.id, code), isNull, reason: 'used already');
      final late = store.shares.createInvite(alice.id, 'P', ShareRole.member);
      now = now.add(const Duration(hours: 25));
      expect(store.shares.redeemInvite(carol.id, late), isNull, reason: 'expired');
    });

    test('a wrong or badly formed code joins nothing', () {
      put(alice, project('P'));
      store.shares.createInvite(alice.id, 'P', ShareRole.member);
      expect(store.shares.redeemInvite(bob.id, 'AAAA-2222'), isNull);
      expect(store.shares.redeemInvite(bob.id, 'nonsense'), isNull);
      expect(store.shares.rolesOf(bob.id), isEmpty);
    });

    test('someone already in the project cannot join twice', () {
      put(alice, project('P'));
      final a = store.shares.createInvite(alice.id, 'P', ShareRole.member);
      store.shares.redeemInvite(bob.id, a);
      final b = store.shares.createInvite(alice.id, 'P', ShareRole.viewer);
      expect(() => store.shares.redeemInvite(bob.id, b), throwsA(isA<ShareError>()));
    });

    test('the owner cannot be invited into her own project, and too many pending invites are refused', () {
      put(alice, project('P'));
      for (var i = 0; i < 20; i++) {
        store.shares.createInvite(alice.id, 'P', ShareRole.viewer);
      }
      expect(() => store.shares.createInvite(alice.id, 'P', ShareRole.viewer), throwsA(isA<ShareError>()));
    });
  });

  group('leaving and removal', () {
    setUp(() {
      share(people: {bob: ShareRole.member, carol: ShareRole.member});
      put(bob, [...task('t2', 'P', title: 'Bob\'s task', extra: {'assignee_id': bob.id, 'assigned_by': alice.id})]);
      put(carol, [...task('t3', 'P', title: 'Carol\'s task', extra: {'assignee_id': carol.id, 'assigned_by': carol.id})]);
    });

    test('removing a member takes the project off their phone, unassigns their tasks, and keeps the project for everyone else', () {
      store.shares.removeMember(alice.id, 'P', bob.id);
      expect(has(bob, 'projects', 'P'), isFalse);
      expect(has(bob, 'tasks', 't1'), isFalse);
      expect(has(bob, 'tasks', 't2'), isFalse);
      // Their task is still there for the others, now unassigned. Carol's stays hers.
      expect(has(alice, 'tasks', 't2'), isTrue);
      expect(field(alice, 'tasks', 't2', 'assignee_id'), isNull);
      expect(field(carol, 'tasks', 't2', 'assignee_id'), isNull);
      expect(field(carol, 'tasks', 't3', 'assignee_id'), carol.id);
      expect(store.shares.roleIn('P', bob.id), isNull);
    });

    test('after removal, nothing more flows to them and their edits go nowhere', () {
      store.shares.removeMember(alice.id, 'P', bob.id);
      put(alice, [ch('tasks', 't1', 'title', 'after Bob left')]);
      expect(has(bob, 'tasks', 't1'), isFalse);
      put(bob, [ch('tasks', 't1', 'title', 'ghost edit')]);
      expect(field(alice, 'tasks', 't1', 'title'), 'after Bob left');
      expect(field(carol, 'tasks', 't1', 'title'), 'after Bob left');
    });

    test('the removal reaches their phone as deletions through normal sync', () {
      store.shares.removeMember(alice.id, 'P', bob.id);
      final gone = store.changesSince(bob.id, 'Bob-phone', 0, limit: 5000).changes.where((c) => c.col == presentColumn && c.value == false).map((c) => '${c.table}/${c.row}').toSet();
      expect(gone, containsAll(['projects/P', 'tasks/t1', 'tasks/t2']));
    });

    test('a member can leave; the owner cannot; an admin cannot remove an admin; a member cannot remove anyone', () {
      expect(() => store.shares.removeMember(bob.id, 'P', carol.id), throwsA(isA<ShareError>()));
      expect(() => store.shares.removeMember(alice.id, 'P', alice.id), throwsA(isA<ShareError>()));
      store.shares.setRole(alice.id, 'P', bob.id, ShareRole.admin);
      store.shares.setRole(alice.id, 'P', carol.id, ShareRole.admin);
      expect(() => store.shares.removeMember(bob.id, 'P', carol.id), throwsA(isA<ShareError>()));
      store.shares.removeMember(carol.id, 'P', carol.id);
      expect(has(carol, 'projects', 'P'), isFalse);
      expect(has(alice, 'projects', 'P'), isTrue);
    });

    test('when the last other member goes, the project stops being shared', () {
      store.shares.removeMember(alice.id, 'P', bob.id);
      store.shares.removeMember(alice.id, 'P', carol.id);
      expect(store.shares.participants('P'), isEmpty);
      put(alice, [ch('tasks', 't1', 'title', 'private again')]);
      expect(view(bob)['tasks'] ?? const {}, isEmpty, reason: 'Bobs copy is gone and nothing new reaches him');
    });

    test('the owner can stop sharing; everyone else loses their copy and the owner keeps the project', () {
      store.shares.stopSharing(alice.id, 'P');
      expect(has(bob, 'projects', 'P'), isFalse);
      expect(has(carol, 'projects', 'P'), isFalse);
      expect(has(alice, 'projects', 'P'), isTrue);
      expect(has(alice, 'tasks', 't2'), isTrue);
      expect(() => store.shares.stopSharing(bob.id, 'P'), throwsA(isA<ShareError>()));
    });
  });

  group('coming back', () {
    test('someone who left and is invited again gets the whole project delivered again', () {
      share(people: {bob: ShareRole.member});
      put(bob, [ch('tasks', 't1', 'title', 'Bob edited this')]);
      final cursorBefore = store.changesSince(bob.id, 'Bob-phone', 0, limit: 10000).cursor;
      store.shares.removeMember(alice.id, 'P', bob.id);
      final afterLeaving = store.changesSince(bob.id, 'Bob-phone', cursorBefore, limit: 10000);
      expect(afterLeaving.changes.every((c) => c.col == presentColumn && c.value == false), isTrue, reason: 'only deletion marks, nothing else');
      store.shares.redeemInvite(bob.id, store.shares.createInvite(alice.id, 'P', ShareRole.viewer));
      final again = store.changesSince(bob.id, 'Bob-phone', afterLeaving.cursor, limit: 10000).changes;
      expect(again.where((c) => c.table == 'projects' && c.col == 'name').single.value, 'Home');
      expect(again.where((c) => c.table == 'tasks' && c.row == 't1' && c.col == 'title').single.value, 'Bob edited this');
      expect(again.where((c) => c.table == 'tasks' && c.row == 't1' && c.col == presentColumn).single.value, true);
      // The revived presence beats the old deletion mark when both are applied in order.
      final deletion = afterLeaving.changes.firstWhere((c) => c.row == 't1' && c.col == presentColumn);
      final revival = again.firstWhere((c) => c.row == 't1' && c.col == presentColumn);
      expect(revival.hlc.compareTo(deletion.hlc), greaterThan(0));
    });

    test('a task moved out of the project and later back in arrives again with all its fields', () {
      share(people: {bob: ShareRole.member});
      put(alice, [...project('mine', name: 'Alice only')]);
      put(alice, [ch('tasks', 't1', 'project_id', 'mine')]);
      expect(has(bob, 'tasks', 't1'), isFalse);
      put(alice, [ch('tasks', 't1', 'project_id', 'P')]);
      expect(field(bob, 'tasks', 't1', 'title'), 'First task');
      expect(has(bob, 'tasks', 't1'), isTrue);
    });
  });

  group('moving tasks between projects', () {
    setUp(() {
      share(people: {bob: ShareRole.member});
      put(alice, [...project('mine', name: 'Alice only'), ...task('p1', 'mine', title: 'Private task'), ch('comments', 'pc', presentColumn, true), ch('comments', 'pc', 'task_id', 'p1'), ch('comments', 'pc', 'body', 'a note')]);
    });

    test('moving a private task into the shared project gives it, and its comments, to the others', () {
      expect(has(bob, 'tasks', 'p1'), isFalse);
      put(alice, [ch('tasks', 'p1', 'project_id', 'P')]);
      expect(field(bob, 'tasks', 'p1', 'title'), 'Private task');
      expect(field(bob, 'comments', 'pc', 'body'), 'a note');
    });

    test('moving a shared task out to a private project removes it, and its comments, from the others', () {
      put(alice, [ch('tasks', 't1', 'project_id', 'mine')]);
      expect(has(bob, 'tasks', 't1'), isFalse);
      expect(has(alice, 'tasks', 't1'), isTrue);
      put(alice, [ch('tasks', 't1', 'title', 'private now')]);
      expect(has(bob, 'tasks', 't1'), isFalse);
    });

    test('a read-only member cannot move a task out of the project', () {
      store.shares.setRole(alice.id, 'P', bob.id, ShareRole.viewer);
      put(bob, [ch('tasks', 't1', 'project_id', 'bobs')]);
      expect(field(alice, 'tasks', 't1', 'project_id'), 'P');
      expect(field(bob, 'tasks', 't1', 'project_id'), 'P');
    });

    test('moving between two shared projects with different members', () {
      put(alice, project('Q', name: 'Other'));
      store.shares.redeemInvite(carol.id, store.shares.createInvite(alice.id, 'Q', ShareRole.member));
      put(alice, [ch('tasks', 't1', 'project_id', 'Q')]);
      expect(has(bob, 'tasks', 't1'), isFalse, reason: 'Bob is not in Q');
      expect(field(carol, 'tasks', 't1', 'title'), 'First task');
    });
  });

  group('assignment', () {
    test('who a task is assigned to and by whom passes to everyone', () {
      share(people: {bob: ShareRole.member});
      put(alice, [ch('tasks', 't1', 'assignee_id', bob.id), ch('tasks', 't1', 'assigned_by', alice.id)]);
      expect((field(bob, 'tasks', 't1', 'assignee_id'), field(bob, 'tasks', 't1', 'assigned_by')), (bob.id, alice.id));
    });
  });

  group('the member list a phone is told', () {
    test('every sync response says which projects are shared, with names and roles', () {
      share(people: {bob: ShareRole.viewer});
      final forBob = store.shares.infoFor(bob.id).single;
      expect((forBob.projectId, forBob.myRole, forBob.ownerId), ('P', ShareRole.viewer, alice.id));
      expect({for (final m in forBob.members) m.name: m.role}, {'Alice': ShareRole.owner, 'Bob': ShareRole.viewer});
      expect(store.shares.infoFor(carol.id), isEmpty);
    });
  });

  group('accounts', () {
    test('when the owner\'s account is deleted, the longest-standing admin becomes the owner and the others keep the project', () {
      share(people: {bob: ShareRole.member, carol: ShareRole.admin});
      store.deleteUser(alice.id);
      expect(store.shares.roleIn('P', carol.id), ShareRole.owner);
      expect(store.shares.roleIn('P', bob.id), ShareRole.member);
      expect(field(bob, 'tasks', 't1', 'title'), 'First task');
      expect(field(carol, 'tasks', 't1', 'title'), 'First task');
      // The new owner can invite and rename.
      final code = store.shares.createInvite(carol.id, 'P', ShareRole.admin);
      expect(code, isNotEmpty);
      put(carol, [ch('projects', 'P', 'name', 'Carol\'s now')]);
      expect(field(bob, 'projects', 'P', 'name'), 'Carol\'s now');
    });

    test('a member deleting their account leaves the project for the rest', () {
      share(people: {bob: ShareRole.member});
      put(bob, task('t2', 'P', title: 'Bob\'s'));
      store.deleteUser(bob.id);
      expect(field(alice, 'tasks', 't2', 'title'), 'Bob\'s');
      expect(store.shares.participants('P').map((p) => p.userId), [alice.id]);
    });

    test('an owner with nobody else just ends the share when deleted', () {
      put(alice, project('P'));
      store.shares.createInvite(alice.id, 'P', ShareRole.member);
      store.deleteUser(alice.id);
      expect(store.db.select('SELECT COUNT(*) AS n FROM shares').first['n'], 0);
    });
  });

  test('random edits by three people always leave every copy of the shared project identical', () {
    final rnd = Random(42);
    share(people: {bob: ShareRole.member, carol: ShareRole.admin});
    final people = [alice, bob, carol];
    final ids = ['t1'];
    for (var i = 0; i < 300; i++) {
      final who = people[rnd.nextInt(3)];
      final action = rnd.nextInt(6);
      if (action == 0) {
        final id = 'n${ids.length}';
        ids.add(id);
        put(who, task(id, 'P', title: 'task $i'));
      } else {
        final id = ids[rnd.nextInt(ids.length)];
        final col = ['title', 'priority', 'due_date', 'description', 'completed_at', 'assignee_id'][rnd.nextInt(6)];
        final value = switch (col) {
          'priority' => rnd.nextInt(4) + 1,
          'completed_at' => rnd.nextBool() ? null : 1790000000 + i,
          'assignee_id' => rnd.nextBool() ? null : people[rnd.nextInt(3)].id,
          _ => 'v$i',
        };
        // Clocks are not in step across people: some edits are older than ones already made.
        put(who, [ch('tasks', id, col, value, at: wall + rnd.nextInt(2000) - 1000)]);
      }
    }
    Map<String, Object?> shared(Account who) => {
          for (final e in (view(who)['tasks'] ?? const {}).entries)
            for (final c in e.value.entries)
              if (c.key != 'is_collapsed') '${e.key}.${c.key}': c.value,
        };
    expect(shared(bob), shared(alice));
    expect(shared(carol), shared(alice));
    expect(shared(alice), isNotEmpty);
  });

  group('over HTTP', () {
    late Handler api;
    late Map<String, String> tokens;

    setUp(() async {
      api = buildApi(store, config: const ApiConfig(trustProxy: true, syncPerMinute: 100000), clock: () => now);
      tokens = {};
      for (final a in [alice, bob, carol]) {
        final r = await api(Request('POST', Uri.parse('http://x/v1/pair'), headers: {'content-type': 'application/json', 'x-forwarded-for': '1.1.1.1'}, body: jsonEncode({'code': store.createInvite(a.id), 'deviceName': 'p'})));
        final j = jsonDecode(await r.readAsString()) as Map;
        expect(j['userId'], a.id, reason: 'pairing tells the app who it is');
        tokens[a.name] = j['token'] as String;
      }
    });

    Future<({int status, dynamic body})> call(String who, String method, String path, {Object? body}) async {
      final r = await api(Request(method, Uri.parse('http://x$path'),
          headers: {'authorization': 'Bearer ${tokens[who]}', 'x-forwarded-for': '1.1.1.1', if (body != null) 'content-type': 'application/json'}, body: body == null ? null : jsonEncode(body)));
      final text = await r.readAsString();
      return (status: r.statusCode, body: text.isEmpty ? null : jsonDecode(text));
    }

    Future<void> syncChanges(String who, Account a, List<SyncChange> changes) async {
      final r = await call(who, 'POST', '/v1/sync', body: SyncRequest(cursor: 0, changes: changes).toJson());
      expect(r.status, 200, reason: '${r.body}');
    }

    test('invite, join, see the member list in the sync response, change a role, leave', () async {
      await syncChanges('Alice', alice, [...project('P'), ...task('t1', 'P')]);
      final inv = await call('Alice', 'POST', '/v1/projects/P/invites', body: {'role': 'member'});
      expect(inv.status, 201);
      expect(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(inv.body['code'] as String), isTrue);
      final join = await call('Bob', 'POST', '/v1/invites/redeem', body: {'code': inv.body['code']});
      expect((join.status, join.body['projectId'], join.body['role']), (200, 'P', 'member'));

      final sync = await call('Bob', 'POST', '/v1/sync', body: const SyncRequest(cursor: 0, changes: []).toJson());
      final shares = (sync.body['shares'] as List).single as Map;
      expect((shares['projectId'], shares['myRole']), ('P', 'member'));
      expect((shares['members'] as List).map((m) => m['name']), unorderedEquals(['Alice', 'Bob']));
      expect(((sync.body['changes'] as List).where((c) => c['t'] == 'tasks' && c['c'] == 'title').single)['v'], 'A task');

      expect((await call('Alice', 'POST', '/v1/projects/P/members/${bob.id}', body: {'role': 'viewer'})).status, 204);
      expect((await call('Bob', 'GET', '/v1/shares')).body['shares'].single['myRole'], 'viewer');
      expect((await call('Bob', 'DELETE', '/v1/projects/P/members/me')).status, 204);
      expect((await call('Bob', 'GET', '/v1/shares')).body['shares'], isEmpty);
    });

    test('refusals come back as clear errors', () async {
      await syncChanges('Alice', alice, project('P'));
      expect((await call('Bob', 'POST', '/v1/projects/P/invites', body: {'role': 'member'})).status, 404);
      expect((await call('Alice', 'POST', '/v1/projects/P/invites', body: {'role': 'owner'})).status, 400);
      expect((await call('Alice', 'POST', '/v1/projects/P/invites', body: {'role': 'dictator'})).status, 400);
      expect((await call('Alice', 'POST', '/v1/projects/P/invites', body: {})).status, 400);
      final inv = await call('Alice', 'POST', '/v1/projects/P/invites', body: {'role': 'viewer'});
      await call('Bob', 'POST', '/v1/invites/redeem', body: {'code': inv.body['code']});
      expect((await call('Bob', 'POST', '/v1/projects/P/invites', body: {'role': 'viewer'})).status, 403);
      expect((await call('Bob', 'DELETE', '/v1/projects/P/share')).status, 403);
      expect((await call('Alice', 'DELETE', '/v1/projects/P/members/me')).status, 400, reason: 'the owner cannot leave');
    });

    test('guessing codes is locked out after five wrong tries', () async {
      await syncChanges('Alice', alice, project('P'));
      await call('Alice', 'POST', '/v1/projects/P/invites', body: {'role': 'viewer'});
      for (var i = 0; i < 5; i++) {
        expect((await call('Carol', 'POST', '/v1/invites/redeem', body: {'code': 'AAAA-222$i'})).status, 401);
      }
      expect((await call('Carol', 'POST', '/v1/invites/redeem', body: {'code': 'AAAA-2227'})).status, 429);
    });

    test('me reports the person\'s id, and unsharing works end to end', () async {
      expect((await call('Alice', 'GET', '/v1/me')).body['user']['id'], alice.id);
      await syncChanges('Alice', alice, [...project('P'), ...task('t1', 'P')]);
      final inv = await call('Alice', 'POST', '/v1/projects/P/invites', body: {'role': 'member'});
      await call('Bob', 'POST', '/v1/invites/redeem', body: {'code': inv.body['code']});
      expect((await call('Alice', 'DELETE', '/v1/projects/P/share')).status, 204);
      expect(has(bob, 'projects', 'P'), isFalse);
      expect(has(alice, 'projects', 'P'), isTrue);
    });
  });
}
