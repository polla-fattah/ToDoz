import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:taskflow_core/backup.dart';
import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/reminder.dart' show ReminderSpec;
import '../data/repository.dart';
import 'catalog.dart';
import 'places_screen.dart';
import '../platform/auto_backup.dart';
import '../security/app_lock.dart';
import 'common.dart';
import 'integrations_screen.dart';
import 'lock_screen.dart';
import '../platform/attachment_store.dart';
import 'attachments_ui.dart' show formatBytes;
import 'progress_screen.dart';
import 'sync_screen.dart';
import '../sync/sync_service.dart' show SyncState;
import 'help_screen.dart';
import 'when_dialogs.dart' show pickTimeMinutes;

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        const _Heading('Appearance'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
            ],
            selected: {catalog.themeMode},
            onSelectionChanged: (s) => repo.setSetting('themeMode', switch (s.first) {
              ThemeMode.dark => 'dark',
              ThemeMode.light => 'light',
              ThemeMode.system => 'system',
            }),
          ),
        ),
        const _Heading('Goals and Karma'),
        SwitchListTile(
          title: const Text('Karma, streaks and goals'),
          subtitle: const Text('Turn off to hide the goal bar, the Productivity page and celebrations.'),
          value: catalog.karmaEnabled,
          onChanged: (v) => repo.setSetting('karma.enabled', '$v'),
        ),
        if (catalog.karmaEnabled)
          ListTile(
            title: Text(catalog.dailyGoal == 0 ? 'Daily goal: off' : 'Daily goal: ${catalog.dailyGoal} tasks'),
            subtitle: Text(catalog.weeklyGoal == 0 ? 'Weekly goal: off' : 'Weekly goal: ${catalog.weeklyGoal} tasks'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProgressScreen())),
          ),
        const _Heading('Time and dates'),
        SwitchListTile(
          title: const Text('24-hour clock'),
          value: catalog.use24h,
          onChanged: (v) => repo.setSetting('use24h', '$v'),
        ),
        ListTile(
          title: const Text('Week starts on'),
          subtitle: Text(const ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][catalog.weekStart]),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await pickFromList<int>(
              context,
              'Week starts on',
              const [(1, 'Monday'), (6, 'Saturday'), (7, 'Sunday')],
              selected: catalog.weekStart,
            );
            if (picked != null) await repo.setSetting('weekStart', '$picked');
          },
        ),
        const _Heading('Reminders'),
        ListTile(
          title: const Text('Automatic reminder'),
          subtitle: Text(catalog.autoReminderMinutes == null
              ? 'Off'
              : '${ReminderSpec.before(catalog.autoReminderMinutes!).describe()} a task with a due time'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await pickFromList<String>(
              context,
              'Automatic reminder',
              const [('off', 'Off'), ('0', 'When due'), ('10', '10 minutes before'), ('30', '30 minutes before'), ('60', '1 hour before')],
              selected: catalog.autoReminderMinutes?.toString() ?? 'off',
            );
            if (picked != null) await repo.setSetting('autoReminder', picked);
          },
        ),
        SwitchListTile(
          title: const Text('Daily digest'),
          subtitle: Text(catalog.digestMinutes == null
              ? 'A morning summary of what is due'
              : 'Every day at ${formatTime(catalog.digestMinutes!, use24h: catalog.use24h)}'),
          value: catalog.digestMinutes != null,
          onChanged: (v) async {
            if (!v) {
              await repo.setSetting('digestTime', 'off');
              return;
            }
            final m = await pickTimeMinutes(context, initial: 8 * 60);
            if (m != null) await repo.setSetting('digestTime', formatTime(m));
          },
        ),
        if (catalog.digestMinutes != null)
          ListTile(
            title: const Text('Digest time'),
            trailing: Text(formatTime(catalog.digestMinutes!, use24h: catalog.use24h)),
            onTap: () async {
              final m = await pickTimeMinutes(context, initial: catalog.digestMinutes);
              if (m != null) await repo.setSetting('digestTime', formatTime(m));
            },
          ),
        ListTile(
          leading: const Icon(Icons.place_outlined),
          title: const Text('Places'),
          subtitle: const Text('Where location reminders fire: "when I arrive at Work"'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PlacesScreen())),
        ),
        if (catalog.notifications?.supported ?? false) const _PermissionTile(),
        if (!(catalog.notifications?.supported ?? false))
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Reminders are available on Android and Windows'),
            subtitle: Text('This device cannot show them yet.'),
          ),
        const _Heading('Sync'),
        Builder(builder: (context) {
          final sync = catalog.sync;
          final status = sync == null
              ? 'Not available'
              : switch (sync.state) {
                  SyncState.unpaired => 'Keep your devices in step through your own server',
                  SyncState.syncing => 'Syncing…',
                  SyncState.idle => 'Signed in as ${sync.userName ?? ''}${sync.pendingChanges > 0 ? ' · ${sync.pendingChanges} changes waiting' : ' · up to date'}',
                  SyncState.error => 'Could not sync: ${sync.lastError ?? ''}',
                  SyncState.signedOut => 'This device was signed out by the server',
                };
          return ListTile(
            leading: Icon(sync?.state == SyncState.error || sync?.state == SyncState.signedOut ? Icons.cloud_off_outlined : Icons.cloud_sync_outlined),
            title: Text(sync?.paired == true ? 'Sync' : 'Set up sync'),
            subtitle: Text(status),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
          );
        }),
        const _Heading('Security'),
        const _AppLockTiles(),
        ListTile(
          leading: const Icon(Icons.event_available_outlined),
          title: const Text('Calendar and integrations'),
          subtitle: const Text('Google Calendar, a calendar link, API access and webhooks'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const IntegrationsScreen())),
        ),
        const _Heading('Backup'),
        const _AutoBackupTiles(),
        ListTile(
          leading: const Icon(Icons.upload_file_outlined),
          title: const Text('Export backup'),
          subtitle: const Text('Saves everything to a JSON file you choose.'),
          onTap: () => _export(context),
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('Restore from backup'),
          subtitle: const Text('Works with ToDoz (TaskFlow 2.0) backups and TaskFlow 1.0 backups.'),
          onTap: () => _restore(context),
        ),
        const _Heading('Your data'),
        const _StorageTiles(),
        ListTile(
          leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
          title: Text('Delete all my data', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          subtitle: const Text('Removes every task and setting from this device (and the server, if you choose).'),
          onTap: () => _deleteEverything(context),
        ),
        const _Heading('Help'),
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: const Text('Quick Add, repeats and filters'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HelpScreen())),
        ),
        const _Heading('About'),
        const ListTile(
          title: Text('ToDoz'),
          subtitle: Text(
            'Your tasks are stored on this device. Export a backup before uninstalling or changing phones. '
            'No analytics or ads. Sync is optional and goes only to a server you run; family sharing arrives in a later release.',
          ),
        ),
      ]),
    );
  }

  /// FR-U6: erase this device (and optionally the server copy) after a typed confirmation.
  Future<void> _deleteEverything(BuildContext context) async {
    final catalog = AppScope.of(context);
    final sync = catalog.sync;
    final paired = sync?.paired ?? false;
    final c = TextEditingController();
    var alsoServer = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Delete all my data?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Every task, project, label, comment and setting on this device is erased. This cannot be undone. Export a backup first if you might want it.'),
            if (paired)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: alsoServer,
                onChanged: (v) => set(() => alsoServer = v ?? false),
                title: const Text('Also delete my account and data on the server'),
                subtitle: const Text('Otherwise the server keeps its copy and this device is just unpaired.'),
              ),
            const SizedBox(height: 8),
            TextField(controller: c, decoration: const InputDecoration(labelText: 'Type DELETE EVERYTHING'), onChanged: (_) => set(() {})),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: c.text.trim() == 'DELETE EVERYTHING' ? () => Navigator.pop(ctx, true) : null, child: const Text('Delete')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      if (paired) {
        if (alsoServer) {
          await sync!.deleteServerData();
        } else {
          await sync!.unpair();
        }
      }
      await catalog.repo.deleteEverything();
      if (context.mounted) {
        showMessage(context, 'Everything on this device was deleted');
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } catch (e) {
      if (context.mounted) showMessage(context, 'Could not delete: $e');
    }
  }

  Future<void> _export(BuildContext context) async {
    final repo = AppScope.repoOf(context);
    final bundle = await repo.exportBundle();
    final today = formatDate(dateOnly(repo.now));
    final bytes = utf8.encode(bundle.toJsonString());
    try {
      final saved = await FilePicker.saveFile(
        fileName: 'ToDoz-backup-$today.json',
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: 'Save ToDoz backup',
      );
      if (context.mounted && saved != null) showMessage(context, 'Backup saved');
    } catch (_) {
      if (context.mounted) showMessage(context, 'Could not save the backup. Please try another location.');
    }
  }

  Future<void> _restore(BuildContext context) async {
    final repo = AppScope.repoOf(context);
    final String raw;
    try {
      final file = await FilePicker.pickFile(dialogTitle: 'Choose a ToDoz backup');
      if (file == null) return;
      if ((await file.length() ?? 0) > 50 * 1024 * 1024) throw const FormatException('too large');
      raw = utf8.decode(await file.readAsBytes());
    } catch (_) {
      if (context.mounted) showMessage(context, 'Could not read that file.');
      return;
    }
    final Bundle bundle;
    try {
      bundle = Bundle.parse(raw);
    } on FormatException {
      if (context.mounted) showMessage(context, 'Invalid backup. Existing tasks were kept.');
      return;
    }
    if (!context.mounted) return;
    final open = bundle.tasks.where((t) => t.completedAt == null).length;
    final done = bundle.tasks.length - open;
    final ok = await confirm(
      context,
      'Replace everything with this backup?',
      '${bundle.sourceVersion == 1 ? 'TaskFlow 1.0 backup' : 'ToDoz backup'}\n'
      '${bundle.projects.length} projects, $open open tasks, $done completed, ${bundle.comments.length} comments.\n\n'
      'Your current data is saved to a safety copy first.',
      action: 'Restore',
    );
    if (!ok || !context.mounted) return;
    try {
      await _snapshot(repo);
      await repo.replaceAll(bundle);
      if (context.mounted) {
        showMessage(context, 'Backup restored');
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } catch (_) {
      if (context.mounted) showMessage(context, 'Restore failed. Your existing data was kept.');
    }
  }

  /// FR-X3: keep a copy of the current data before a restore replaces it.
  Future<void> _snapshot(Repo repo) async {
    final bundle = await repo.exportBundle();
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'TaskFlow', 'backups'));
    await dir.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    await File(p.join(dir.path, 'pre-restore-$stamp.json')).writeAsString(bundle.toJsonString());
  }
}

/// How much room attachments take, with a clean-up (FR-C6).
class _StorageTiles extends StatefulWidget {
  const _StorageTiles();

  @override
  State<_StorageTiles> createState() => _StorageTilesState();
}

class _StorageTilesState extends State<_StorageTiles> {
  Future<StorageStats>? _stats;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _stats = AppScope.of(context).attachments?.stats();
  }

  void _refresh() => setState(() {
        _stats = AppScope.of(context).attachments?.stats();
      });

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final store = catalog.attachments;
    if (store == null) return const SizedBox.shrink();
    return FutureBuilder<StorageStats>(
      future: _stats,
      builder: (context, snap) {
        final s = snap.data;
        if (s == null) return const SizedBox.shrink();
        final canOffload = catalog.sync?.paired ?? false;
        return Column(children: [
          ListTile(
            leading: const Icon(Icons.attach_file),
            title: Text('Attachments: ${s.files} ${s.files == 1 ? 'file' : 'files'}, ${formatBytes(s.bytes)}'),
            subtitle: Text('${formatBytes(s.localBytes)} on this device${s.orphanBytes > 0 ? ', ${formatBytes(s.orphanBytes)} of it unused' : ''}'),
          ),
          if (s.orphanBytes > 0)
            ListTile(
              title: const Text('Clean up unused files'),
              subtitle: const Text('Removes files left behind by deleted comments.'),
              onTap: () async {
                final freed = await store.cleanUp();
                if (context.mounted) showMessage(context, 'Freed ${formatBytes(freed)}');
                _refresh();
              },
            ),
          if (canOffload && s.localBytes > 0)
            ListTile(
              title: const Text('Free up space on this device'),
              subtitle: const Text('Removes the local copy of files already on the server. They download again when you open them.'),
              onTap: () async {
                final freed = await store.offloadUploaded();
                if (context.mounted) showMessage(context, 'Freed ${formatBytes(freed)}');
                _refresh();
              },
            ),
        ]);
      },
    );
  }
}

/// App lock (FR-U4): PIN, optional fingerprint or face.
class _AppLockTiles extends StatelessWidget {
  const _AppLockTiles();

  @override
  Widget build(BuildContext context) {
    final lock = AppScope.of(context).lock;
    if (lock == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) {
        if (!lock.enabled) {
          return ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Turn on app lock'),
            subtitle: const Text('Ask for a PIN when the app opens or comes back after a minute away.'),
            onTap: () async {
              final pin = await askNewPin(context);
              if (pin == null) return;
              final bio = await lock.canUseBiometric();
              await lock.enable(pin, useBiometric: bio);
              if (context.mounted) showMessage(context, bio ? 'App lock is on. Fingerprint or face unlock is on too.' : 'App lock is on');
            },
          );
        }
        return Column(children: [
          ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('App lock is on'),
            subtitle: const Text('Locks when the app opens and after a minute in the background.'),
            trailing: TextButton(onPressed: lock.lockNow, child: const Text('Lock now')),
          ),
          FutureBuilder<bool>(
            future: lock.canUseBiometric(),
            builder: (context, snap) => snap.data == true
                ? SwitchListTile(
                    title: const Text('Unlock with fingerprint or face'),
                    value: lock.biometricEnabled,
                    onChanged: (v) => lock.setBiometric(v),
                  )
                : const SizedBox.shrink(),
          ),
          ListTile(
            title: const Text('Change PIN'),
            onTap: () async {
              final old = await askPin(context, title: 'Enter your current PIN');
              if (old == null || !context.mounted) return;
              if (await lock.unlock(old) != UnlockResult.ok) {
                if (context.mounted) showMessage(context, 'That is not your PIN');
                return;
              }
              if (!context.mounted) return;
              final pin = await askNewPin(context, title: 'Choose a new PIN');
              if (pin != null) await lock.enable(pin, useBiometric: lock.biometricEnabled);
            },
          ),
          ListTile(
            title: const Text('Turn off app lock'),
            onTap: () async {
              final pin = await askPin(context);
              if (pin == null || !context.mounted) return;
              final ok = await lock.disable(pin);
              if (context.mounted) showMessage(context, ok ? 'App lock is off' : 'That is not your PIN');
            },
          ),
        ]);
      },
    );
  }
}

/// Daily automatic backups to a folder (FR-X2).
class _AutoBackupTiles extends StatefulWidget {
  const _AutoBackupTiles();

  @override
  State<_AutoBackupTiles> createState() => _AutoBackupTilesState();
}

class _AutoBackupTilesState extends State<_AutoBackupTiles> {
  Future<({bool on, String? folder, int keep, DateTime? last, String? error})> _load(AutoBackup b) async =>
      (on: await b.enabled, folder: await b.folder, keep: await b.keep, last: await b.lastRun, error: await b.lastError);

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final b = catalog.autoBackup;
    if (b == null) return const SizedBox.shrink();
    final repo = catalog.repo;
    // Reload whenever one of the backup settings changes.
    return StreamBuilder<String?>(
      stream: repo.watchSetting('backup.last'),
      builder: (context, _) => StreamBuilder<String?>(
        stream: repo.watchSetting('backup.auto'),
        builder: (context, _) => FutureBuilder(
          future: _load(b),
          builder: (context, snap) {
            final s = snap.data;
            if (s == null) return const SizedBox.shrink();
            return Column(children: [
              SwitchListTile(
                title: const Text('Automatic daily backup'),
                subtitle: Text(s.last == null
                    ? 'Writes a backup file every day and keeps the newest ${s.keep}.'
                    : 'Last backup ${formatDate(dateOnly(s.last!))} at ${formatTime(s.last!.hour * 60 + s.last!.minute, use24h: catalog.use24h)}. Keeps the newest ${s.keep}.'),
                value: s.on,
                onChanged: (v) => repo.setSetting('backup.auto', '$v'),
              ),
              if (s.error != null && s.error!.isNotEmpty)
                ListTile(leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error), title: Text(s.error!)),
              if (s.on) ...[
                ListTile(
                  title: const Text('Backup folder'),
                  subtitle: Text(s.folder == null || s.folder!.isEmpty ? 'Inside the app (lost if you uninstall it). Choose a folder you keep.' : s.folder!),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    try {
                      final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Choose where backups are saved');
                      if (dir == null) return;
                      await repo.setSetting('backup.folder', dir);
                      final file = await b.backupNow();
                      if (context.mounted) showMessage(context, file == null ? 'That folder cannot be written to. Pick another.' : 'Backup saved to that folder');
                    } catch (_) {
                      if (context.mounted) showMessage(context, 'Could not use that folder');
                    }
                  },
                ),
                ListTile(
                  title: const Text('Copies to keep'),
                  trailing: Text('${s.keep}'),
                  onTap: () async {
                    final picked = await pickFromList<int>(context, 'Copies to keep', const [(7, '7'), (14, '14'), (30, '30'), (90, '90')], selected: s.keep);
                    if (picked != null) {
                      await repo.setSetting('backup.keep', '$picked');
                      setState(() {});
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Back up now'),
                  onTap: () async {
                    final f = await b.backupNow();
                    if (context.mounted) showMessage(context, f == null ? 'The backup failed' : 'Backup written');
                  },
                ),
              ],
            ]);
          },
        ),
      ),
    );
  }
}

/// Shows whether reminders can fire on time and lets the owner grant the
/// permissions (FR-N4).
class _PermissionTile extends StatefulWidget {
  const _PermissionTile();

  @override
  State<_PermissionTile> createState() => _PermissionTileState();
}

class _PermissionTileState extends State<_PermissionTile> {
  ({bool notifications, bool exact})? _status;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  Future<void> _refresh() async {
    final c = AppScope.of(context).notifications;
    final s = await c?.permissionStatus();
    if (mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final ok = s != null && s.notifications && s.exact;
    return ListTile(
      leading: Icon(ok ? Icons.check_circle_outline : Icons.warning_amber_rounded, color: ok ? Colors.green : Colors.orange),
      title: Text(ok ? 'Reminders can fire on time' : 'Reminders need permission'),
      subtitle: Text(s == null
          ? 'Checking...'
          : ok
              ? (Platform.isWindows ? 'Reminders appear as Windows notifications, also when ToDoz is closed. Focus assist or Do not disturb can hide them.' : 'Notifications and exact alarms are allowed.')
              : [
                  if (!s.notifications) 'Notifications are off.',
                  if (!s.exact) 'Exact alarms are not allowed, so reminders may be a few minutes late.',
                ].join(' ')),
      trailing: ok ? null : const Icon(Icons.chevron_right),
      onTap: ok
          ? null
          : () async {
              await AppScope.of(context).notifications?.requestPermissions();
              await _refresh();
            },
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
