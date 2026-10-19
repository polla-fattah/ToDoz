/// Family sharing rules (SRS 4.14), used by the app and the server so both
/// agree on who may do what and which fields are shared.
///
/// A shared project is copied between people. Each person keeps their own
/// full copy of its projects, sections, tasks and comments, and the server
/// passes every accepted change on to the other members. Everything that is
/// a person's own business (labels, reminders, completions, the activity
/// log, and personal view settings) is never passed on.
library;

/// What a person may do in a shared project.
enum ShareRole {
  /// Made the project. Can do everything, and cannot be removed.
  owner,

  /// Can change the project's name and sections, invite and remove people, and do what a member does.
  admin,

  /// Can add, change, complete and delete tasks, and write comments.
  member,

  /// Can only look.
  viewer;

  static ShareRole? parse(String? s) {
    for (final r in values) {
      if (r.name == s) return r;
    }
    return null;
  }

  /// May add and change tasks, comments, attachments and reactions.
  bool get canEditTasks => this != viewer;

  /// May change the project itself (its name, colour) and its sections.
  bool get canEditProject => this == owner || this == admin;

  /// May invite people, change roles and remove others.
  bool get canManageMembers => this == owner || this == admin;

  String get label => switch (this) {
        owner => 'Owner',
        admin => 'Admin',
        member => 'Member',
        viewer => 'Read only',
      };
}

/// Tables whose rows belong to a project and are copied between its members.
const sharedTables = {'projects', 'sections', 'tasks', 'comments', 'attachments', 'reactions', 'project_comments'};

/// Columns each person keeps for themselves even on a shared row: where the
/// project sits in their own tree, their own favourites and view layout,
/// and what they have collapsed.
const personalColumns = <String, Set<String>>{
  'projects': {'parent_id', 'sort_order', 'is_favorite', 'is_archived', 'view_options'},
  'sections': {'is_collapsed'},
  'tasks': {'is_collapsed'},
};

bool isPersonalColumn(String table, String column) => personalColumns[table]?.contains(column) ?? false;

/// The least role that may write [column] of [table] in a shared project.
/// Personal columns are anyone's to change (they are not copied anywhere).
ShareRole? roleNeededToWrite(String table, String column) {
  if (isPersonalColumn(table, column)) return null; // no restriction
  return switch (table) {
    'projects' || 'sections' => ShareRole.admin,
    _ => ShareRole.member,
  };
}

/// Whether [role] may write [column] of [table].
bool mayWrite(ShareRole role, String table, String column) {
  final needed = roleNeededToWrite(table, column);
  if (needed == null) return true;
  return switch (needed) {
    ShareRole.admin => role.canEditProject,
    _ => role.canEditTasks,
  };
}

class ShareMember {
  const ShareMember({required this.userId, required this.name, required this.role});
  final String userId;
  final String name;
  final ShareRole role;

  Map<String, Object?> toJson() => {'id': userId, 'name': name, 'role': role.name};

  static ShareMember? fromJson(Object? j) {
    if (j is! Map) return null;
    final role = ShareRole.parse(j['role'] as String?);
    if (j['id'] is! String || j['name'] is! String || role == null) return null;
    return ShareMember(userId: j['id'] as String, name: j['name'] as String, role: role);
  }
}

/// A shared project as one person sees it.
class ShareInfo {
  const ShareInfo({required this.projectId, required this.ownerId, required this.myRole, required this.members});
  final String projectId;
  final String ownerId;
  final ShareRole myRole;
  final List<ShareMember> members;

  ShareMember? member(String userId) {
    for (final m in members) {
      if (m.userId == userId) return m;
    }
    return null;
  }

  String? nameOf(String userId) => member(userId)?.name;

  Map<String, Object?> toJson() => {
        'projectId': projectId,
        'ownerId': ownerId,
        'myRole': myRole.name,
        'members': [for (final m in members) m.toJson()],
      };

  static ShareInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final role = ShareRole.parse(j['myRole'] as String?);
    final members = [for (final m in (j['members'] as List? ?? const [])) ?ShareMember.fromJson(m)];
    if (j['projectId'] is! String || j['ownerId'] is! String || role == null) return null;
    return ShareInfo(projectId: j['projectId'] as String, ownerId: j['ownerId'] as String, myRole: role, members: members);
  }
}

/// The emoji people may react with (FR-W3).
const reactionEmoji = ['👍', '❤️', '😂', '🎉', '🙏', '👀'];
