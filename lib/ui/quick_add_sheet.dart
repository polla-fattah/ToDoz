import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import 'package:taskflow_core/backup.dart' show inboxId;
import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/quick_add.dart';
import 'package:taskflow_core/recurrence.dart';
import 'package:taskflow_core/reminder.dart';
import '../data/repository.dart';
import 'catalog.dart';
import 'common.dart';
import 'when_dialogs.dart';

/// Opens the Quick Add sheet. [defaultProjectId] and [defaultDue] come from
/// the screen it was opened on (a project view, or Today).
Future<void> showQuickAdd(
  BuildContext context, {
  String defaultProjectId = inboxId,
  String? defaultSectionId,
  String? defaultDue,
  String? initialText,
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
      initialText: initialText,
    ),
  );
}

/// A text field that colours recognised Quick Add tokens as you type (FR-Q1).
class HighlightController extends TextEditingController {
  HighlightController({required this.now, this.weekStart = 1});
  final DateTime now;
  final int weekStart;
  bool highlight = true;

  static Color colorFor(QuickAddKind k, ColorScheme cs) => switch (k) {
        QuickAddKind.date => const Color(0xFF058527),
        QuickAddKind.time => const Color(0xFF058527),
        QuickAddKind.repeat => const Color(0xFF058527),
        QuickAddKind.deadline => const Color(0xFFB8255F),
        QuickAddKind.reminder => const Color(0xFFC77100),
        QuickAddKind.priority => const Color(0xFFD1453B),
        QuickAddKind.label => const Color(0xFF8D4EC0),
        QuickAddKind.project => cs.primary,
        QuickAddKind.section => cs.tertiary,
        QuickAddKind.assignee => const Color(0xFF1E88E5),
      };

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (!highlight || text.isEmpty) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final cs = Theme.of(context).colorScheme;
    final r = parseQuickAdd(text, now, weekStart: weekStart);
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
    this.initialText,
  });

  final BuildContext outerContext;
  final String defaultProjectId;
  final String? defaultSectionId;
  final String? defaultDue;

  /// Text to start with, for content shared from another app.
  final String? initialText;

  @override
  State<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<QuickAddSheet> {
  late final HighlightController _text = _makeController();

  // The owner's own choices. absent = use what the text says (FR-Q4: a picked
  // value beats a parsed one); a present null = cleared.
  Value<String?> _date = const Value.absent();
  Value<String?> _time = const Value.absent();
  Value<String?> _repeat = const Value.absent();
  Value<String?> _deadline = const Value.absent();
  final _extraReminders = <ReminderSpec>[];
  int? _manualPriority;
  String? _manualProject;
  final _extraLabels = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialText;
    if (initial != null && initial.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _text.value = TextEditingValue(text: initial, selection: TextSelection.collapsed(offset: initial.length));
      });
    }
  }

  HighlightController _makeController() {
    final catalog = AppScope.of(context);
    return HighlightController(now: catalog.repo.now, weekStart: catalog.weekStart)..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  QuickAddResult get _parsed => parseQuickAdd(_text.text, _text.now, weekStart: AppScope.of(context).weekStart);

  // The values that will be saved, combining the text and the owner's choices.
  String? get _effectiveRepeat => _repeat.present ? _repeat.value : _parsed.recurrence?.text;

  String? get _effectiveTime {
    if (_time.present) return _time.value;
    final t = _parsed.dueTime;
    return t == null ? null : formatTime(t);
  }

  String? get _effectiveDate {
    if (_date.present) return _date.value;
    final p = _parsed.due;
    if (p != null) return formatDate(p);
    final repeat = _effectiveRepeat;
    if (repeat != null) {
      try {
        return formatDate(firstOccurrence(parseRecurrence(repeat, _text.now), _text.now));
      } on RecurrenceException {
        // fall through to the default
      }
    }
    if (_effectiveTime != null) return formatDate(dateOnly(_text.now)); // a time alone means today
    return widget.defaultDue;
  }

  String? get _effectiveDeadline {
    if (_deadline.present) return _deadline.value;
    final d = _parsed.deadline;
    return d == null ? null : formatDate(d);
  }

  int get _effectivePriority => _manualPriority ?? _parsed.priority ?? 4;

  List<ReminderSpec> get _effectiveReminders => [..._parsed.reminders, ..._extraReminders];

  TaskFields get _fields => TaskFields(
        dueDate: _effectiveDate,
        dueTime: _effectiveDate == null ? null : _effectiveTime,
        recurrence: _effectiveDate == null ? null : _effectiveRepeat,
        deadline: _effectiveDeadline,
        reminders: _effectiveReminders,
        priority: _effectivePriority,
      );

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
      var plan = await repo.planQuickAdd(_text.text, defaultProjectId: widget.defaultProjectId, weekStart: catalog.weekStart);
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
      final id = await repo.addFromPlan(plan, createMissing: create, fields: _fields, extraLabelIds: _extraLabels.toList());
      if (sectionId != null && plan.sectionId == null) {
        await repo.moveTask(id, projectId: plan.projectId, sectionId: sectionId);
      }
      navigator.pop();
      if (messenger.mounted) showUndo(messenger, 'Task added', () => repo.deleteTask(id));
    } on RuleException catch (e) {
      if (mounted) {
        showMessage(context, e.message);
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _pickDate() async {
    final now = _text.now;
    final current = _effectiveDate == null ? null : parseIsoDate(_effectiveDate!);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) setState(() => _date = Value(formatDate(picked)));
  }

  Future<void> _pickDeadline() async {
    final now = _text.now;
    final current = _effectiveDeadline == null ? null : parseIsoDate(_effectiveDeadline!);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      helpText: 'Deadline',
    );
    if (picked != null) setState(() => _deadline = Value(formatDate(picked)));
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final parsed = _parsed;
    final date = _effectiveDate;
    final time = _effectiveTime;
    final repeat = _effectiveRepeat;
    final deadline = _effectiveDeadline;
    final reminders = _effectiveReminders;
    final projectId = _manualProject ?? _resolveProject(catalog, parsed.projectName) ?? widget.defaultProjectId;
    final project = catalog.project(projectId);
    final unknownProject = _manualProject == null && parsed.projectName != null && _resolveProject(catalog, parsed.projectName) == null;
    const green = Color(0xFF058527);

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
              hintText: 'Review paper tomorrow 4pm p1 %reading #work',
              border: InputBorder.none,
              counterText: '',
            ),
            style: Theme.of(context).textTheme.titleMedium,
            onSubmitted: (_) => _submit(),
          ),
          if (parsed.repeatError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(parsed.repeatError!, style: TextStyle(color: cs.error, fontSize: 12)),
            ),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 4, children: [
            ActionChip(
              avatar: Icon(Icons.event_outlined, size: 18, color: date != null ? green : null),
              label: Text(date == null ? 'Date' : dueLabel(date, _text.now)),
              onPressed: _pickDate,
            ),
            ActionChip(
              avatar: Icon(Icons.schedule, size: 18, color: time != null ? green : null),
              label: Text(time == null ? 'Time' : timeText(context, time)),
              onPressed: () async {
                final m = await pickTimeMinutes(context, initial: time == null ? null : parseClock(time));
                if (m != null) setState(() => _time = Value(formatTime(m)));
              },
            ),
            ActionChip(
              avatar: Icon(Icons.repeat, size: 18, color: repeat != null ? green : null),
              label: Text(repeat ?? 'Repeat'),
              onPressed: () async {
                final r = await showRepeatDialog(context, initial: repeat);
                if (r != null) setState(() => _repeat = Value(r.isEmpty ? null : r));
              },
            ),
            if (date != null || time != null || repeat != null)
              ActionChip(
                avatar: const Icon(Icons.close, size: 16),
                label: const Text('Clear'),
                onPressed: () => setState(() {
                  _date = const Value(null);
                  _time = const Value(null);
                  _repeat = const Value(null);
                }),
              ),
            ActionChip(
              avatar: Icon(Icons.flag_circle_outlined, size: 18, color: deadline != null ? const Color(0xFFB8255F) : null),
              label: Text(deadline == null ? 'Deadline' : dueLabel(deadline, _text.now)),
              onPressed: _pickDeadline,
            ),
            ActionChip(
              avatar: const Icon(Icons.notifications_none, size: 18),
              label: Text(reminders.isEmpty ? 'Reminder' : '${reminders.length} reminder${reminders.length == 1 ? '' : 's'}'),
              onPressed: () async {
                final r = await showReminderDialog(context, hasDueTime: time != null);
                if (r != null) setState(() => _extraReminders.add(r));
              },
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
          if (_extraReminders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 6, children: [
                for (final r in _extraReminders)
                  InputChip(
                    label: Text(r.describe(use24h: catalog.use24h)),
                    onDeleted: () => setState(() => _extraReminders.remove(r)),
                  ),
              ]),
            ),
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
