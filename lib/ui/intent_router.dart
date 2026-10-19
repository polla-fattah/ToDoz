// The context here is the app's root navigator, which lives as long as the app, so using it after a wait is safe.
// ignore_for_file: use_build_context_synchronously

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:taskflow_core/backup.dart' show inboxId;

import '../data/repository.dart';
import '../platform/intents.dart';
import 'catalog.dart';
import 'quick_add_sheet.dart';
import 'views.dart' show SearchScreen;

/// Carries out what Android asked for: share-sheet content, launcher
/// shortcuts, and commands from other apps (FR-C5, FR-I2, FR-I7).
class IntentRouter {
  IntentRouter(this.catalog, this.navigatorKey);

  final Catalog catalog;
  final GlobalKey<NavigatorState> navigatorKey;

  Repo get repo => catalog.repo;

  void start() => AndroidIntents.listen(handle);

  BuildContext? get _context => navigatorKey.currentContext;

  void _say(String text) {
    final c = _context;
    if (c == null) return;
    ScaffoldMessenger.maybeOf(c)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> handle(IntentMessage m) async {
    // The first frame may not be up yet when the app is started by an intent.
    for (var i = 0; i < 40 && _context == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final context = _context;
    if (context == null) return;
    try {
      switch (m.type) {
        case 'today':
          catalog.navRequest.value = 'today';
        case 'search':
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));
        case 'add':
          if (m.text != null && m.silent) {
            await _quickAdd(m.text!);
          } else {
            await showQuickAdd(context, initialText: m.text);
          }
        case 'complete':
          await _complete(m.text);
        case 'share':
          await _share(context, m);
      }
    } on RuleException catch (e) {
      _say(e.message);
    } catch (e) {
      _say('Could not do that: ${e.toString().split('\n').first}');
    }
  }

  /// Creates a task from a Quick Add line without opening the sheet (for other apps).
  Future<void> _quickAdd(String line) async {
    final plan = await repo.planQuickAdd(line, weekStart: catalog.weekStart);
    if (plan.parsed.title.isEmpty) {
      _say('A task needs a title');
      return;
    }
    await repo.addFromPlan(plan, createMissing: true);
    _say('Added: ${plan.parsed.title}');
  }

  Future<void> _complete(String? title) async {
    if (title == null) {
      _say('Say which task to complete');
      return;
    }
    final wanted = title.toLowerCase();
    final open = await repo.watchAllOpen().first;
    final exact = open.where((t) => t.title.toLowerCase() == wanted).toList();
    final hits = exact.isNotEmpty ? exact : open.where((t) => t.title.toLowerCase().contains(wanted)).toList();
    if (hits.isEmpty) {
      _say('No open task called "$title"');
      return;
    }
    await repo.completeTask(hits.first.id);
    _say('Completed: ${hits.first.title}');
  }

  Future<void> _share(BuildContext context, IntentMessage m) async {
    if (m.files.isEmpty && m.unreadable > 0) {
      _say(m.unreadable == 1 ? 'Could not read the shared file (files over 100 MB are not accepted).' : 'Could not read the ${m.unreadable} shared files.');
      if (m.text == null && m.subject == null) return;
    }
    if (m.files.isEmpty) {
      // Text or a link: let the person tidy it in the Quick Add sheet before saving.
      final line = [if (m.subject != null && (m.text == null || !m.text!.contains(m.subject!))) m.subject!, ?m.text].join(' ');
      await showQuickAdd(context, initialText: line);
      return;
    }
    final store = catalog.attachments;
    if (store == null) {
      _say('Files cannot be attached in this build');
      return;
    }
    final title = (m.subject ?? m.text ?? m.files.first.name).split('\n').first;
    final taskId = await repo.addTask(title: title.length > 200 ? title.substring(0, 200) : title, projectId: inboxId);
    var attached = 0;
    for (final f in m.files) {
      try {
        await store.attachFile(taskId, File(f.path), fileName: f.name, mimeType: f.mime.isEmpty ? null : f.mime);
        attached++;
      } on RuleException catch (e) {
        _say('${f.name}: ${e.message}');
      } finally {
        try {
          await File(f.path).delete();
        } catch (_) {}
      }
    }
    if (m.text != null && m.subject != null) await repo.addComment(taskId, m.text!);
    _say('Added to Inbox with $attached ${attached == 1 ? 'file' : 'files'}');
  }
}
