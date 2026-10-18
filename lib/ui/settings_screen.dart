import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/backup.dart';
import '../core/date_parser.dart';
import '../data/repository.dart';
import 'catalog.dart';
import 'common.dart';

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
        const _Heading('Daily goal'),
        ListTile(
          title: Text('${catalog.dailyGoal} tasks a day'),
          subtitle: const Text('Shown as a progress bar on Today.'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Fewer',
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: catalog.dailyGoal > 1 ? () => repo.setSetting('dailyGoal', '${catalog.dailyGoal - 1}') : null,
            ),
            IconButton(
              tooltip: 'More',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: catalog.dailyGoal < 100 ? () => repo.setSetting('dailyGoal', '${catalog.dailyGoal + 1}') : null,
            ),
          ]),
        ),
        const _Heading('Backup'),
        ListTile(
          leading: const Icon(Icons.upload_file_outlined),
          title: const Text('Export backup'),
          subtitle: const Text('Saves everything to a JSON file you choose.'),
          onTap: () => _export(context),
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('Restore from backup'),
          subtitle: const Text('Works with TaskFlow 2.0 backups and TaskFlow 1.0 backups.'),
          onTap: () => _restore(context),
        ),
        const _Heading('About'),
        const ListTile(
          title: Text('TaskFlow 2.0 (R1 foundation)'),
          subtitle: Text(
            'Your tasks are stored on this device. Export a backup before uninstalling or changing phones. '
            'No account, analytics or ads. Reminders, recurring tasks, filters and sync arrive in later releases.',
          ),
        ),
      ]),
    );
  }

  Future<void> _export(BuildContext context) async {
    final repo = AppScope.repoOf(context);
    final bundle = await repo.exportBundle();
    final today = formatDate(dateOnly(repo.now));
    final bytes = utf8.encode(bundle.toJsonString());
    try {
      final saved = await FilePicker.saveFile(
        fileName: 'TaskFlow-backup-$today.json',
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: 'Save TaskFlow backup',
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
      final file = await FilePicker.pickFile(dialogTitle: 'Choose a TaskFlow backup');
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
      '${bundle.sourceVersion == 1 ? 'TaskFlow 1.0 backup' : 'TaskFlow 2.0 backup'}\n'
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

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
