import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:taskflow_core/date_parser.dart' show formatDate, dateOnly;

import '../data/repository.dart';

/// Writes a backup file once a day to a folder, and keeps the newest N (FR-X2).
///
/// It runs when the app starts, when it comes back to the foreground and once
/// an hour while it is open: Android does not let an app that is not running
/// do work at a chosen time without a background job (not built yet).
class AutoBackup with WidgetsBindingObserver {
  AutoBackup(this.repo, {required this.defaultFolder, this.interval = const Duration(hours: 1)});

  final Repo repo;

  /// Where backups go until the owner picks a folder.
  final Future<Directory> Function() defaultFolder;
  final Duration interval;
  Timer? _timer;
  bool _running = false;

  static const prefix = 'TaskFlow-auto-';
  static const defaultKeep = 14;

  void start() {
    unawaited(runIfDue());
    _timer = Timer.periodic(interval, (_) => runIfDue());
    WidgetsBinding.instance.addObserver(this);
  }

  void stop() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(runIfDue());
  }

  Future<bool> get enabled async => (await repo.getSetting('backup.auto')) != 'false';
  Future<int> get keep async => (int.tryParse(await repo.getSetting('backup.keep') ?? '') ?? defaultKeep).clamp(1, 365);
  Future<String?> get folder => repo.getSetting('backup.folder');
  Future<DateTime?> get lastRun async {
    final v = await repo.getSetting('backup.last');
    return v == null ? null : DateTime.tryParse(v);
  }

  Future<String?> get lastError => repo.getSetting('backup.error');

  Future<Directory> _target() async {
    final picked = await folder;
    if (picked != null && picked.isNotEmpty) return Directory(picked);
    return defaultFolder();
  }

  /// Writes today's backup unless one exists already. Returns the file written, or null.
  Future<File?> runIfDue() async {
    if (_running || !await enabled) return null;
    _running = true;
    try {
      final today = formatDate(dateOnly(repo.now));
      final dir = await _target();
      final file = File(p.join(dir.path, '$prefix$today.json'));
      if (await file.exists()) return null;
      return await backupNow(dir: dir);
    } finally {
      _running = false;
    }
  }

  /// Writes a backup now (the "Back up now" button), replacing today's.
  Future<File?> backupNow({Directory? dir}) async {
    try {
      dir ??= await _target();
      await dir.create(recursive: true);
      final bundle = await repo.exportBundle();
      final today = formatDate(dateOnly(repo.now));
      final file = File(p.join(dir.path, '$prefix$today.json'));
      // Write beside it first, so a crash never leaves a half-written backup under the real name.
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(bundle.toJsonString(), flush: true);
      await temp.rename(file.path);
      await _prune(dir, await keep);
      await repo.setSetting('backup.last', repo.now.toIso8601String());
      await repo.setSetting('backup.error', '');
      return file;
    } catch (e) {
      await repo.setSetting('backup.error', 'Could not write the backup: ${e.toString().split('\n').first}');
      return null;
    }
  }

  Future<void> _prune(Directory dir, int keep) async {
    final files = [
      for (final e in await dir.list().toList())
        if (e is File && p.basename(e.path).startsWith(prefix) && e.path.endsWith('.json')) e,
    ]..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path))); // newest name first (dates sort as text)
    for (final f in files.skip(keep)) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}
