import 'package:taskflow_core/filter.dart';
import 'package:taskflow_core/quick_add.dart';
import 'package:taskflow_core/sharing.dart';
import 'package:taskflow_core/sync.dart';
import 'package:test/test.dart';

final now = DateTime(2026, 10, 19, 9);

FilterTask task(String id, {String project = 'p', String? assignee, String? by}) => FilterTask(
      id: id,
      title: id,
      projectId: project,
      createdAt: now,
      assigneeId: assignee,
      assignedById: by,
    );

void main() {
  group('roles', () {
    test('what each role may do', () {
      expect(ShareRole.viewer.canEditTasks, isFalse);
      expect(ShareRole.member.canEditTasks, isTrue);
      expect(ShareRole.member.canEditProject, isFalse);
      expect(ShareRole.admin.canEditProject, isTrue);
      expect(ShareRole.owner.canManageMembers, isTrue);
      expect(ShareRole.member.canManageMembers, isFalse);
    });

    test('writing rules by table and column', () {
      expect(mayWrite(ShareRole.viewer, 'tasks', 'title'), isFalse);
      expect(mayWrite(ShareRole.viewer, 'tasks', 'is_collapsed'), isTrue, reason: 'personal');
      expect(mayWrite(ShareRole.viewer, 'projects', 'view_options'), isTrue, reason: 'personal');
      expect(mayWrite(ShareRole.member, 'projects', 'name'), isFalse);
      expect(mayWrite(ShareRole.member, 'projects', 'is_favorite'), isTrue);
      expect(mayWrite(ShareRole.member, 'sections', 'name'), isFalse);
      expect(mayWrite(ShareRole.member, 'comments', 'body'), isTrue);
      expect(mayWrite(ShareRole.member, 'reactions', 'emoji'), isTrue);
      expect(mayWrite(ShareRole.admin, 'sections', 'name'), isTrue);
      expect(mayWrite(ShareRole.admin, 'projects', 'name'), isTrue);
    });

    test('every column that is not personal and not listed in the sync schema cannot be sent', () {
      for (final e in personalColumns.entries) {
        expect(syncSchema.containsKey(e.key), isTrue, reason: e.key);
        for (final c in e.value) {
          expect(syncSchema[e.key]!.contains(c), isTrue, reason: '${e.key}.$c');
        }
      }
      for (final t in sharedTables) {
        expect(syncSchema.containsKey(t), isTrue, reason: t);
      }
    });

    test('share info survives a round trip through JSON, and bad data is ignored', () {
      const info = ShareInfo(
        projectId: 'P',
        ownerId: 'u1',
        myRole: ShareRole.member,
        members: [ShareMember(userId: 'u1', name: 'Alice', role: ShareRole.owner), ShareMember(userId: 'u2', name: 'Bob', role: ShareRole.member)],
      );
      final back = ShareInfo.fromJson(info.toJson())!;
      expect((back.projectId, back.myRole, back.nameOf('u2')), ('P', ShareRole.member, 'Bob'));
      expect(ShareInfo.fromJson({'projectId': 'P'}), isNull);
      expect(ShareInfo.fromJson({'projectId': 'P', 'ownerId': 'u', 'myRole': 'king', 'members': []}), isNull);
      expect(ShareInfo.fromJson('nope'), isNull);
    });

    test('a sync response carries the share list or not', () {
      final with_ = SyncResponse.fromJson({'cursor': 1, 'more': false, 'changes': [], 'shares': [{'projectId': 'P'}]});
      expect(with_.shares, hasLength(1));
      expect(SyncResponse.fromJson({'cursor': 1, 'more': false, 'changes': []}).shares, isNull);
      expect(const SyncResponse(cursor: 1, changes: [], more: false).toJson().containsKey('shares'), isFalse);
    });
  });

  group('filters for shared projects', () {
    final env = FilterEnv(
      now: now,
      currentUserId: 'me',
      memberNames: const {'me': 'Polla', 'u2': 'Sam', 'u3': 'Sarah'},
      sharedProjectIds: const {'family'},
    );
    final mine = task('mine', project: 'family', assignee: 'me', by: 'u2');
    final sams = task('sams', project: 'family', assignee: 'u2', by: 'me');
    final sarahs = task('sarahs', project: 'family', assignee: 'u3', by: 'u3');
    final nobody = task('nobody', project: 'family');
    final privateTask = task('private');

    List<String> run(String q) {
      final f = parseFilter(q, env);
      return [for (final t in [mine, sams, sarahs, nobody, privateTask]) if (f.matches(t)) t.id];
    }

    test('assigned to me, to others, to a name', () {
      expect(run('assigned to: me'), ['mine']);
      expect(run('assigned to: others'), ['sams', 'sarahs']);
      expect(run('assigned to: sam'), ['sams']);
      expect(run('assigned to: sa*'), ['sams', 'sarahs']);
    });

    test('assigned by', () {
      expect(run('assigned by: me'), ['sams']);
      expect(run('assigned by: sam'), ['mine']);
      expect(run('assigned by: sarah'), ['sarahs']);
    });

    test('assigned, not assigned, and shared', () {
      expect(run('assigned'), ['mine', 'sams', 'sarahs']);
      expect(run('!assigned'), ['nobody', 'private']);
      expect(run('shared'), ['mine', 'sams', 'sarahs', 'nobody']);
      expect(run('shared & !assigned'), ['nobody']);
      expect(run('assigned to: me | assigned to: sam'), ['mine', 'sams']);
    });

    test('a name nobody has is explained instead of matching nothing', () {
      expect(() => parseFilter('assigned to: zebra', env), throwsA(isA<FilterException>().having((e) => e.message, 'message', contains('zebra'))));
      expect(() => parseFilter('assigned sideways', env), throwsA(isA<FilterException>()));
    });

    test('without sharing these filters match nothing assigned', () {
      final plain = FilterEnv(now: now);
      expect(parseFilter('assigned', plain).matches(mine), isTrue);
      expect(parseFilter('shared', plain).matches(mine), isFalse);
      expect(() => parseFilter('assigned to: sam', plain), throwsA(isA<FilterException>()));
    });
  });

  group('Quick Add +name', () {
    const members = ['Sam', 'Sarah', 'Polla'];

    test('a member\'s name after + becomes the assignee and leaves the title', () {
      final r = parseQuickAdd('Buy milk +sam tomorrow p2', now, memberNames: members);
      expect(r.assigneeName, 'Sam');
      expect(r.title, 'Buy milk');
      expect(r.priority, 2);
      expect(r.tokens.where((t) => t.kind == QuickAddKind.assignee), hasLength(1));
    });

    test('a short unique beginning is enough; an ambiguous one is left in the title', () {
      expect(parseQuickAdd('Call +pol', now, memberNames: members).assigneeName, 'Polla');
      final ambiguous = parseQuickAdd('Call +sa', now, memberNames: members);
      expect(ambiguous.assigneeName, isNull);
      expect(ambiguous.title, 'Call +sa');
    });

    test('with no members known, "+" text is just text (a phone number, "+2 items")', () {
      final r = parseQuickAdd('Call +966501234567 and buy +2 items', now);
      expect(r.assigneeName, isNull);
      expect(r.title, 'Call +966501234567 and buy +2 items');
      final withMembers = parseQuickAdd('Buy +2 items', now, memberNames: members);
      expect(withMembers.assigneeName, isNull);
      expect(withMembers.title, 'Buy +2 items');
    });
  });
}
