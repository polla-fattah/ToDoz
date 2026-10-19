import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:taskflow_core/csv_io.dart';

import '../data/repository.dart';
import 'catalog.dart';
import 'common.dart';
import 'views.dart' show ProjectScreen;

/// Import tasks from a Todoist export (CSV or backup ZIP), a text or Markdown
/// list, or an iCalendar file (FR-X4, FR-X5, FR-X7), and the template gallery (FR-X6).
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

enum _Source { todoist, text, ics }

class _ImportScreenState extends State<ImportScreen> {
  _Source _source = _Source.todoist;
  String? _projectId; // null = a new project
  bool _busy = false;

  String get _hint => switch (_source) {
        _Source.todoist => 'A Todoist project export (.csv) or a Todoist backup (.zip of CSV files). Each CSV becomes a project, with sections, sub-tasks, labels, dates, repeats and comments.',
        _Source.text => 'A text or Markdown file: one task per line. Checkboxes, bullets and indentation (sub-tasks) are understood, and # headings become sections.',
        _Source.ics => 'An iCalendar file (.ics) with tasks. Titles, notes, due dates and times, priority, done and simple repeats are imported.',
      };

  Future<void> _pick() async {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    setState(() => _busy = true);
    try {
      final file = await FilePicker.pickFile(dialogTitle: 'Choose a file to import');
      if (file == null) return;
      if ((await file.length() ?? 0) > 50 * 1024 * 1024) throw const FormatException('That file is too large (over 50 MB)');
      final bytes = await file.readAsBytes();
      final name = p.basenameWithoutExtension(file.name);
      final results = <String>[];
      String? lastProject;

      Future<void> run(String projectName, ImportReport report) async {
        if (_projectId != null && results.isEmpty) {
          final r = await repo.importItems(report, projectId: _projectId!, weekStart: catalog.weekStart);
          lastProject = _projectId;
          results.add(r.summary);
        } else {
          final (id, r) = await repo.importAsNewProject(projectName, report, weekStart: catalog.weekStart);
          lastProject = id;
          results.add('${projectName.isEmpty ? 'Imported' : projectName}: ${r.summary}');
        }
      }

      String decode(List<int> b) => utf8.decode(b, allowMalformed: true);
      switch (_source) {
        case _Source.todoist:
          if (file.name.toLowerCase().endsWith('.zip')) {
            final zip = ZipDecoder().decodeBytes(bytes);
            var any = false;
            for (final f in zip.files) {
              if (!f.isFile || !f.name.toLowerCase().endsWith('.csv')) continue;
              if (f.size > 20 * 1024 * 1024) continue;
              any = true;
              await run(p.basenameWithoutExtension(f.name), parseTodoistCsv(decode(f.content)));
            }
            if (!any) throw const FormatException('There are no CSV files in that ZIP');
          } else {
            await run(name, parseTodoistCsv(decode(bytes)));
          }
        case _Source.text:
          await run(name, parseTextTasks(decode(bytes)));
        case _Source.ics:
          await run(name, parseIcsTasks(decode(bytes)));
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import finished'),
          content: Text(results.join('\n')),
          actions: [
            if (lastProject != null)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProjectScreen(projectId: lastProject!)));
                },
                child: const Text('Open project'),
              ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    } on FormatException catch (e) {
      if (mounted) showMessage(context, e.message);
    } on RuleException catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) showMessage(context, 'Could not import that file: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Import')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Import from', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<_Source>(
          segments: const [
            ButtonSegment(value: _Source.todoist, label: Text('Todoist'), icon: Icon(Icons.checklist)),
            ButtonSegment(value: _Source.text, label: Text('Text / Markdown'), icon: Icon(Icons.notes)),
            ButtonSegment(value: _Source.ics, label: Text('Calendar'), icon: Icon(Icons.event_note_outlined)),
          ],
          selected: {_source},
          onSelectionChanged: (s) => setState(() => _source = s.first),
        ),
        const SizedBox(height: 8),
        Text(_hint, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        const SizedBox(height: 16),
        DropdownButtonFormField<String?>(
          initialValue: _projectId,
          decoration: const InputDecoration(labelText: 'Put the tasks in'),
          items: [
            const DropdownMenuItem(value: null, child: Text('A new project')),
            DropdownMenuItem(value: catalog.inbox.id, child: const Text('Inbox')),
            for (final (pr, _) in catalog.projectTree()) DropdownMenuItem(value: pr.id, child: Text(pr.name)),
          ],
          onChanged: (v) => setState(() => _projectId = v),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _pick,
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.file_open_outlined),
          label: const Text('Choose a file…'),
        ),
        const SizedBox(height: 8),
        Text('Nothing is changed in tasks you already have. A file that cannot be read is refused as a whole.', style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 12)),
        const Divider(height: 40),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.copy_all_outlined),
          title: const Text('Templates'),
          subtitle: const Text('Start a new project from one of your saved templates.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TemplatesScreen())),
        ),
      ]),
    );
  }
}

/// Your saved templates: make a project from one, or delete it (FR-X6).
class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key});

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  late Future<List<ProjectTemplate>> _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load = AppScope.repoOf(context).templates();
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.repoOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Templates')),
      body: FutureBuilder<List<ProjectTemplate>>(
        future: _load,
        builder: (context, snap) {
          final list = snap.data;
          if (list == null) return const SizedBox.shrink();
          if (list.isEmpty) {
            return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No templates yet. Open a project, choose the menu, then "Save as template".')));
          }
          return ListView(children: [
            for (final t in list)
              ListTile(
                leading: const Icon(Icons.copy_all_outlined),
                title: Text(t.name),
                subtitle: Text('${parseTodoistCsv(t.csv).taskCount} tasks'),
                onTap: () async {
                  final name = await promptText(context, 'New project from "${t.name}"', hint: 'Project name', initial: t.name, action: 'Create');
                  if (name == null || name.trim().isEmpty || !context.mounted) return;
                  await guarded(context, () async {
                    final id = await repo.useTemplate(t.id, name);
                    if (context.mounted) {
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProjectScreen(projectId: id)));
                    }
                  });
                },
                trailing: IconButton(
                  tooltip: 'Delete template',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (!await confirm(context, 'Delete template "${t.name}"?', 'Projects already made from it are not affected.')) return;
                    await repo.deleteTemplate(t.id);
                    if (context.mounted) {
                      setState(() {
                        _load = repo.templates();
                      });
                    }
                  },
                ),
              ),
          ]);
        },
      ),
    );
  }
}

/// Saves a project's CSV to a file the person chooses.
Future<void> exportProjectToFile(BuildContext context, String projectId, {required bool template}) async {
  final repo = AppScope.repoOf(context);
  final project = AppScope.of(context).project(projectId);
  final csv = await repo.exportProjectCsv(projectId, template: template);
  final safe = (project?.name ?? 'project').replaceAll(RegExp(r'[^\w\- ]'), '_');
  try {
    final saved = await FilePicker.saveFile(
      fileName: '$safe${template ? ' (template)' : ''}.csv',
      bytes: utf8.encode(csv),
      mimeType: 'text/csv',
      dialogTitle: template ? 'Save template file' : 'Export project to CSV',
    );
    if (context.mounted && saved != null) showMessage(context, 'Saved');
  } catch (_) {
    if (context.mounted) showMessage(context, 'Could not save the file. Please try another location.');
  }
}
