import 'package:flutter/material.dart';
import 'package:taskflow_core/sharing.dart';

import '../sync/sync_engine.dart';
import '../sync/transport.dart';
import 'catalog.dart';
import 'common.dart';
import 'integrations_screen.dart' show showSecret;

String _problem(Object e) => e is SyncTransportException ? e.message : 'Something went wrong: ${e.toString().split('\n').first}';

/// Who is in a shared project, what each may do, and how to invite or remove people (FR-W1, W4, W6).
class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key, required this.projectId});
  final String projectId;

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  bool _busy = false;

  ServerApi? get _api => AppScope.of(context).sync?.api;

  Future<void> _run(Future<void> Function(ServerApi api) action, {String? done}) async {
    final api = _api;
    if (api == null) {
      showMessage(context, 'Set up sync first (Settings, Sync). Sharing goes through your sync server.');
      return;
    }
    final sync = AppScope.of(context).sync;
    setState(() => _busy = true);
    try {
      await action(api);
      await sync?.syncNow();
      if (mounted && done != null) showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, _problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _invite(ShareRole mine) async {
    final role = await showDialog<ShareRole>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('What may they do?'),
        children: [
          for (final r in [if (mine == ShareRole.owner) ShareRole.admin, ShareRole.member, ShareRole.viewer])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, r),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r.label),
                subtitle: Text(switch (r) {
                  ShareRole.admin => 'Everything a member can do, and change the project, its sections and its people.',
                  ShareRole.member => 'Add, change, complete and delete tasks, and comment.',
                  _ => 'Look only.',
                }),
              ),
            ),
        ],
      ),
    );
    if (role == null || !mounted) return;
    await _run((api) async {
      final code = await api.createInvite(widget.projectId, role);
      if (!mounted) return;
      await showSecret(
        context,
        title: 'Invitation code',
        body: 'Give this code to the person. In ToDoz they open Browse, choose "Join a shared project" and type it. It works once and expires in 24 hours. They need an account on the same server.',
        secret: code,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Share ${catalog.project(widget.projectId)?.name ?? 'project'}')),
      body: ListenableBuilder(
        listenable: catalog,
        builder: (context, _) {
          final shared = catalog.sharedOf(widget.projectId);
          final cs = Theme.of(context).colorScheme;
          final mine = shared?.role ?? ShareRole.owner;
          final paired = catalog.sync?.paired ?? false;
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (!paired)
              const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Sharing goes through your sync server. Set up sync first (Settings, Sync), then come back.')))
            else ...[
              Text(
                shared == null
                    ? 'This project is private. Invite someone to share it: they will see its tasks, sections and comments, and everything else of yours stays private (your Inbox, Today and your other projects).'
                    : 'Everyone below sees this project\'s tasks, sections and comments. Your Inbox, Today and other projects stay private.',
              ),
              const SizedBox(height: 16),
              if (shared != null)
                for (final m in shared.members)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(child: Text(m.name.isEmpty ? '?' : m.name[0].toUpperCase())),
                    title: Text(m.userId == catalog.me ? '${m.name} (you)' : m.name),
                    subtitle: Text(m.role.label),
                    trailing: (m.userId != catalog.me && m.role != ShareRole.owner && mine.canManageMembers && (m.role != ShareRole.admin || mine == ShareRole.owner))
                        ? PopupMenuButton<String>(
                            enabled: !_busy,
                            onSelected: (v) async {
                              if (v == 'remove') {
                                if (!await confirm(context, 'Remove ${m.name}?', 'They lose this project on their phone. The tasks stay for everyone else, and tasks assigned to them become unassigned.', action: 'Remove')) return;
                                await _run((api) => api.removeMember(widget.projectId, m.userId), done: '${m.name} was removed');
                              } else {
                                await _run((api) => api.setMemberRole(widget.projectId, m.userId, ShareRole.parse(v)!), done: '${m.name} is now ${ShareRole.parse(v)!.label.toLowerCase()}');
                              }
                            },
                            itemBuilder: (_) => [
                              for (final r in [if (mine == ShareRole.owner) ShareRole.admin, ShareRole.member, ShareRole.viewer])
                                if (r != m.role) PopupMenuItem(value: r.name, child: Text('Make ${r.label.toLowerCase()}')),
                              const PopupMenuItem(value: 'remove', child: Text('Remove from project')),
                            ],
                          )
                        : null,
                  ),
              const SizedBox(height: 8),
              if (mine.canManageMembers)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _invite(mine),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: Text(shared == null ? 'Invite someone' : 'Invite another person'),
                ),
              if (shared != null) ...[
                const SizedBox(height: 24),
                if (mine == ShareRole.owner)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: cs.error),
                    onPressed: _busy
                        ? null
                        : () async {
                            if (!await confirm(context, 'Stop sharing?', 'Everyone else loses this project on their phone. You keep it with all its tasks.', action: 'Stop sharing')) return;
                            await _run((api) => api.stopSharing(widget.projectId), done: 'This project is private again');
                          },
                    icon: const Icon(Icons.link_off),
                    label: const Text('Stop sharing'),
                  )
                else
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: cs.error),
                    onPressed: _busy
                        ? null
                        : () async {
                            if (!await confirm(context, 'Leave this project?', 'It disappears from your phone. Tasks assigned to you become unassigned.', action: 'Leave')) return;
                            await _run((api) => api.removeMember(widget.projectId, 'me'), done: 'You left the project');
                            if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                          },
                    icon: const Icon(Icons.exit_to_app),
                    label: const Text('Leave project'),
                  ),
              ],
              const SizedBox(height: 16),
              Text(
                'Your role: ${mine.label}. Sharing is not end-to-end encrypted: the person who runs the server can read shared tasks, like all your tasks.',
                style: TextStyle(color: cs.outline, fontSize: 12),
              ),
            ],
          ]);
        },
      ),
    );
  }
}

/// Asks for an invitation code and joins the project (FR-W1).
Future<void> showJoinDialog(BuildContext context) async {
  final catalog = AppScope.of(context);
  final api = catalog.sync?.api;
  if (api == null) {
    showMessage(context, 'Set up sync first (Settings, Sync). Sharing goes through your sync server.');
    return;
  }
  final code = await promptText(context, 'Join a shared project', hint: 'Invitation code, like ABCD-2345', action: 'Join');
  if (code == null || code.trim().isEmpty || !context.mounted) return;
  try {
    final projectId = await api.redeemInvite(code.trim());
    await catalog.sync?.syncNow();
    if (!context.mounted) return;
    final name = catalog.project(projectId)?.name;
    showMessage(context, name == null ? 'Joined. The project appears after the next sync.' : 'You joined "$name"');
  } catch (e) {
    if (context.mounted) showMessage(context, _problem(e));
  }
}
