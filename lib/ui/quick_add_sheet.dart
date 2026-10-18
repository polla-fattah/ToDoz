import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import '../core/backup.dart' show inboxId;
import '../core/date_parser.dart';
import '../core/quick_add.dart';
import '../data/repository.dart';
import 'catalog.dart';
import 'common.dart';

/// Opens the Quick Add sheet. [defaultProjectId] and [defaultDue] come from
/// the screen it was opened on (a project view, or Today).
Future<void> showQuickAdd(
  BuildContext context, {
  String defaultProjectId = inboxId,
  String? defaultSectionId,
  String? defaultDue,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => QuickAddSheet(
      outerContext: context,
      defaultProjectId: defaultProjectId,
      defaultSectionId: defaultSectionId,
      defaultDue: defaultDue,
    ),
  );
}

/// A text field that colours recognised Quick Add tokens as you type (FR-Q1).
class HighlightController extends TextEditingController {
  HighlightController({required this.now});
  final DateTime now;
  bool highlight = true;

  static Color colorFor(QuickAddKind k, ColorScheme cs) => switch (k) {
        QuickAddKind.date => const Color(0xFF058527),
        QuickAddKind.priority => const Color(0xFFD1453B),
        QuickAddKind.label => const Color(0xFF8D4EC0),
        QuickAddKind.project => cs.primary,
        QuickAddKind.section => cs.tertiary,
      };

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (!highlight || text.isEmpty) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final cs = Theme.of(context).colorScheme;
    final r = parseQuickAdd(text, now);
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final t in r.tokens) {
      if (t.start > cursor) spans.add(TextSpan(text: text.substring(cursor, t.start)));
      final c = colorFor(t.kind, cs);
      spans.add(TextSpan(
        text: text.substring(t.start, t.end),
        style: TextStyle(color: c, fontWeight: FontWeight.w600, backgroundColor: c.withValues(alpha: 0.12)),
      ));
      cursor = t.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(style: style, children: spans);
  }
}

class QuickAddSheet extends StatefulWidget {
  const QuickAddSheet({
    super.key,
    required this.outerContext,
    required this.defaultProjectId,
    this.defaultSectionId,
    this.defaultDue,
  });

  final BuildContext outerContext;
  final String defaultProjectId;
  final String? defaultSectionId;
  final String? defaultDue;

  @override
  State<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<QuickAddSheet> {
  late final HighlightController _text;
  String? _manualDue; // FR-Q4: a picked date beats a parsed one
  bool _clearDue = false;
  int? _manualPriority;
  String? _manualProject;
  final _extraLabels = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _text = HighlightController(now: DateTime.now())..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  QuickAddResult get _parsed => parseQuickAdd(_text.text, _text.now);

  String? get _effectiveDue {
    if (_clearDue) return null;
    if (_manualDue != null) return _manualDue;
    final p = _parsed.due;
    return p != null ? formatDate(p) : widget.defaultDue;
  }

  int get _effectivePriority => _manualPriority ?? _parsed.priority ?? 4;

  Future<void> _submit() async {
    if (_busy) return;
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final navigator = Navigator.of(context);
    final messenger = widget.outerContext;
    final parsed = _parsed;
    if (parsed.title.isEmpty) {
      showMessage(context, 'Please include a task title.');
      return;
    }
    setState(() => _busy = true);
    try {
      var plan = await repo.planQuickAdd(_text.text, defaultProjectId: widget.defaultProjectId);
      var sectionId = plan.sectionId ?? (plan.projectId == widget.defaultProjectId ? widget.defaultSectionId : null);
      if (_manualProject != null) {
        plan = QuickAddPlan(
          parsed: plan.parsed, projectId: _manualProject!, sectionId: null,
          labelIds: plan.labelIds, unknownLabels: plan.unknownLabels,
        );
        sectionId = null;
      }
      var create = false;
      if (plan.hasUnknown) {
        if (!mounted) return;
        final names = [
          if (plan.unknownProject != null) '#${plan.unknownProject}',
          if (plan.unknownSection != null) '/${plan.unknownSection}',
          for (final l in plan.unknownLabels) '%$l',
        ].join(', ');
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Create new items?'),
            content: Text('These do not exist yet: $names'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, 'skip'), child: const Text('Skip them')),
              FilledButton(onPressed: () => Navigator.pop(ctx, 'create'), child: const Text('Create')),
            ],
          ),
        );
        if (choice == null) {
          setState(() => _busy = false);
          return;
        }
        create = choice == 'create';
      }
      final due = _effectiveDue;
      final id = await repo.addFromPlan(plan, createMissing: create, overrideDue: due);
      // Apply the sheet's own choices on top of what the text said.
      await repo.updateTask(
        id,
        priority: _manualPriority ?? plan.parsed.priority ?? 4,
        dueDate: Value(due),
        labelIds: {...plan.labelIds, ..._extraLabels, ...(await _createdLabelIds(repo, plan, create))}.toList(),
      );
      if (sectionId != null && plan.sectionId == null) {
        await repo.moveTask(id, projectId: plan.projectId, sectionId: sectionId);
      }
      navigator.pop();
      if (messenger.mounted) {
        showUndo(messenger, 'Task added', () => repo.deleteTask(id));
      }
    } on RuleException catch (e) {
      if (mounted) {
        showMessage(context, e.message);
        setState(() => _busy = false);
      }
    }
  }

  /// When labels were just created from the text, find their ids by name.
  Future<List<String>> _createdLabelIds(Repo repo, QuickAddPlan plan, bool created) async {
    if (!created) return const [];
    final all = await repo.watchLabels().first;
    return [
      for (final name in plan.unknownLabels)
        for (final l in all)
          if (l.name.toLowerCase() == name) l.id,
    ];
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final current = _effectiveDue == null ? null : parseIsoDate(_effectiveDue!);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) {
      setState(() {
        _manualDue = formatDate(picked);
        _clearDue = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final parsed = _parsed;
    final due = _effectiveDue;
    final projectId = _manualProject ??
        _resolveProject(catalog, parsed.projectName) ??
        widget.defaultProjectId;
    final project = catalog.project(projectId);
    final unknownProject = _manualProject == null && parsed.projectName != null && _resolveProject(catalog, parsed.projectName) == null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _text,
            autofocus: true,
            maxLength: 500,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: 'Review paper tomorrow p1 %reading #work',
              border: InputBorder.none,
              counterText: '',
            ),
            style: Theme.of(context).textTheme.titleMedium,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 4, children: [
            ActionChip(
              avatar: Icon(Icons.event_outlined, size: 18, color: due != null ? const Color(0xFF058527) : null),
              label: Text(due == null ? 'Date' : dueLabel(due, _text.now)),
              onPressed: _pickDate,
            ),
            if (due != null)
              ActionChip(
                avatar: const Icon(Icons.close, size: 16),
                label: const Text('No date'),
                onPressed: () => setState(() {
                  _clearDue = true;
                  _manualDue = null;
                }),
              ),
            PopupMenuButton<int>(
              tooltip: 'Priority',
              onSelected: (p) => setState(() => _manualPriority = p),
              itemBuilder: (_) => [
                for (final p in [1, 2, 3, 4])
                  PopupMenuItem(
                    value: p,
                    child: Row(children: [
                      Icon(Icons.flag, color: priorityColor(p, cs), size: 18),
                      const SizedBox(width: 8),
                      Text('Priority $p'),
                    ]),
                  ),
              ],
              child: Chip(
                avatar: Icon(Icons.flag_outlined, size: 18, color: priorityColor(_effectivePriority, cs)),
                label: Text('P$_effectivePriority'),
              ),
            ),
            ActionChip(
              avatar: Icon(Icons.circle, size: 12, color: Color(project?.color ?? 0xFF6A6A6A)),
              label: Text(unknownProject ? '#${parsed.projectName} (new)' : (project?.name ?? 'Inbox')),
              onPressed: () async {
                final items = <(String, String)>[
                  (inboxId, 'Inbox'),
                  for (final (p, depth) in catalog.projectTree()) (p.id, '${'    ' * depth}${p.name}'),
                ];
                final picked = await pickFromList<String>(context, 'Project', items, selected: projectId);
                if (picked != null) setState(() => _manualProject = picked);
              },
            ),
            ActionChip(
              avatar: const Icon(Icons.sell_outlined, size: 18),
              label: Text(_labelSummary(catalog, parsed)),
              onPressed: catalog.labels.isEmpty ? null : () => _pickLabels(catalog),
            ),
          ]),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _busy || parsed.title.isEmpty ? null : _submit,
              icon: const Icon(Icons.add),
              label: const Text('Add task'),
            ),
          ),
        ]),
      ),
    );
  }

  String? _resolveProject(Catalog catalog, String? typed) {
    if (typed == null) return null;
    final wanted = normaliseName(typed);
    for (final p in catalog.projects) {
      if (normaliseName(p.name) == wanted || p.id.toLowerCase() == wanted) return p.id;
    }
    return null;
  }

  String _labelSummary(Catalog catalog, QuickAddResult parsed) {
    final names = <String>{...parsed.labels, for (final id in _extraLabels) catalog.label(id)?.name.toLowerCase() ?? ''}..remove('');
    if (names.isEmpty) return 'Labels';
    return names.map((n) => '%$n').join(' ');
  }

  Future<void> _pickLabels(Catalog catalog) async {
    final chosen = {..._extraLabels};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Labels'),
          content: SizedBox(
            width: 320,
            child: ListView(shrinkWrap: true, children: [
              for (final l in catalog.labels)
                CheckboxListTile(
                  value: chosen.contains(l.id),
                  title: Text(l.name),
                  secondary: Icon(Icons.sell, color: Color(l.color), size: 18),
                  onChanged: (v) => setInner(() => v == true ? chosen.add(l.id) : chosen.remove(l.id)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, chosen), child: const Text('Done')),
          ],
        ),
      ),
    );
    if (result != null) setState(() => _extraLabels..clear()..addAll(result));
  }
}
