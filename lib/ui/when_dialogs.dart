import 'package:flutter/material.dart';

import 'package:taskflow_core/date_parser.dart';
import 'package:taskflow_core/recurrence.dart';
import 'package:taskflow_core/reminder.dart';
import 'catalog.dart';
import 'common.dart';

/// The next few dates a repeat will produce, for the live preview.
List<DateTime> previewDates(Recurrence r, DateTime now, {int count = 3}) {
  if (r.isHourly) return const [];
  final out = <DateTime>[firstOccurrence(r, now)];
  while (out.length < count) {
    final next = nextOccurrence(r, currentDue: out.last, completedOn: out.last);
    if (next == null) break;
    out.add(next);
  }
  return out;
}

/// Picks a time of day; honours the 24-hour setting.
Future<int?> pickTimeMinutes(BuildContext context, {int? initial}) async {
  final use24h = AppScope.of(context).use24h;
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: (initial ?? 9 * 60) ~/ 60, minute: (initial ?? 9 * 60) % 60),
    builder: (ctx, child) => MediaQuery(
      data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: use24h),
      child: child!,
    ),
  );
  return t == null ? null : t.hour * 60 + t.minute;
}

String timeText(BuildContext context, String hhmm) {
  final m = parseClock(hhmm);
  return m == null ? hhmm : formatTime(m, use24h: AppScope.of(context).use24h);
}

/// Asks how often a task repeats. Returns the phrase, an empty string to
/// remove the repeat, or null if cancelled. The dialog explains problems and
/// shows the next dates before anything is saved (FR-R10).
Future<String?> showRepeatDialog(BuildContext context, {String? initial}) {
  final now = AppScope.repoOf(context).now;
  return showDialog<String>(
    context: context,
    builder: (_) => _RepeatDialog(initial: initial ?? '', now: now),
  );
}

class _RepeatDialog extends StatefulWidget {
  const _RepeatDialog({required this.initial, required this.now});
  final String initial;
  final DateTime now;

  @override
  State<_RepeatDialog> createState() => _RepeatDialogState();
}

class _RepeatDialogState extends State<_RepeatDialog> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Recurrence? _parsed;
  String? _error;

  void _check(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      _parsed = null;
      _error = null;
      return;
    }
    try {
      _parsed = parseRecurrence(trimmed, widget.now);
      _error = null;
    } on RecurrenceException catch (e) {
      _parsed = null;
      _error = e.message;
    }
  }

  @override
  void initState() {
    super.initState();
    _check(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final preview = _parsed == null ? const <DateTime>[] : previewDates(_parsed!, widget.now);
    return AlertDialog(
      title: const Text('Repeat'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: _c,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'every other week',
                errorText: _error,
                errorMaxLines: 4,
              ),
              onChanged: (v) => setState(() => _check(v)),
              onSubmitted: (_) => _parsed != null ? Navigator.pop(context, _c.text.trim()) : null,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final p in const ['every day', 'every weekday', 'every week', 'every month', 'every year'])
                ActionChip(label: Text(p), onPressed: () => setState(() {
                      _c.text = p;
                      _check(p);
                    })),
            ]),
            if (_parsed != null) ...[
              const SizedBox(height: 12),
              Text(
                _parsed!.isHourly
                    ? 'Repeats every ${_parsed!.interval} hour${_parsed!.interval == 1 ? '' : 's'}'
                    : 'Next: ${preview.map((d) => dueLabel(formatDate(d), widget.now)).join(', ')}',
                style: TextStyle(color: cs.primary),
              ),
              if (_parsed!.fromCompletion)
                Text('Counted from the day you finish it.', style: TextStyle(color: cs.outline, fontSize: 12)),
            ],
            const SizedBox(height: 8),
            Text(
              'Try: every other week · every mon, fri at 8pm · every 2, 15 · every 1st wed · every! 2 months · every day until oct 30',
              style: TextStyle(color: cs.outline, fontSize: 12),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (widget.initial.isNotEmpty) TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Remove')),
        FilledButton(
          onPressed: _parsed == null ? null : () => Navigator.pop(context, _c.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Picks a reminder: a preset, a time of day, or custom text like "45 min before".
Future<ReminderSpec?> showReminderDialog(BuildContext context, {required bool hasDueTime}) async {
  final cs = Theme.of(context).colorScheme;
  final choice = await showDialog<Object>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Add a reminder'),
      children: [
        if (!hasDueTime)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Add a time to the task to use "before" reminders.', style: TextStyle(color: cs.outline, fontSize: 12)),
          ),
        for (final (m, label) in const [
          (0, 'At due time'),
          (10, '10 minutes before'),
          (30, '30 minutes before'),
          (60, '1 hour before'),
          (1440, '1 day before'),
        ])
          SimpleDialogOption(
            onPressed: hasDueTime ? () => Navigator.pop(ctx, ReminderSpec.before(m)) : null,
            child: Text(label, style: TextStyle(color: hasDueTime ? null : cs.outline)),
          ),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'clock'), child: const Text('At a time of day…')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'custom'), child: const Text('Custom…')),
      ],
    ),
  );
  if (choice is ReminderSpec) return choice;
  if (!context.mounted) return null;
  if (choice == 'clock') {
    final m = await pickTimeMinutes(context);
    return m == null ? null : ReminderSpec.at(m);
  }
  if (choice == 'custom') {
    final text = await promptText(context, 'Reminder', hint: '45 min before, 2pm, 1 day before', action: 'Add');
    if (text == null) return null;
    final spec = parseReminderText(text);
    if (spec == null && context.mounted) showMessage(context, 'I could not read that. Try "30 min before" or "14:00".');
    return spec;
  }
  return null;
}

/// Asks how long a task takes. Returns minutes, 0 to clear, or null if cancelled (FR-D3).
Future<int?> showDurationDialog(BuildContext context, {int? initial}) {
  return showDialog<int>(context: context, builder: (_) => _DurationDialog(initial: initial));
}

class _DurationDialog extends StatefulWidget {
  const _DurationDialog({this.initial});
  final int? initial;

  @override
  State<_DurationDialog> createState() => _DurationDialogState();
}

class _DurationDialogState extends State<_DurationDialog> {
  late final TextEditingController _n;
  late String _unit;

  @override
  void initState() {
    super.initState();
    final m = widget.initial;
    if (m == null) {
      _n = TextEditingController(text: '30');
      _unit = 'minutes';
    } else if (m % 1440 == 0) {
      _n = TextEditingController(text: '${m ~/ 1440}');
      _unit = 'days';
    } else if (m % 60 == 0) {
      _n = TextEditingController(text: '${m ~/ 60}');
      _unit = 'hours';
    } else {
      _n = TextEditingController(text: '$m');
      _unit = 'minutes';
    }
  }

  @override
  void dispose() {
    _n.dispose();
    super.dispose();
  }

  int? get _minutes {
    final n = int.tryParse(_n.text.trim());
    if (n == null || n < 1) return null;
    final m = n * (_unit == 'days' ? 1440 : (_unit == 'hours' ? 60 : 1));
    return m > 14400 ? null : m;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Duration'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, children: [
            for (final (label, min) in const [('15m', 15), ('30m', 30), ('1h', 60), ('2h', 120), ('1d', 1440)])
              ActionChip(label: Text(label), onPressed: () => Navigator.pop(context, min)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 80,
              child: TextField(controller: _n, keyboardType: TextInputType.number, onChanged: (_) => setState(() {})),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: _unit,
              items: const [
                DropdownMenuItem(value: 'minutes', child: Text('minutes')),
                DropdownMenuItem(value: 'hours', child: Text('hours')),
                DropdownMenuItem(value: 'days', child: Text('days')),
              ],
              onChanged: (v) => setState(() => _unit = v ?? _unit),
            ),
          ]),
          if (_minutes == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Enter 1 minute to 10 days.', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          if (widget.initial != null) TextButton(onPressed: () => Navigator.pop(context, 0), child: const Text('Remove')),
          FilledButton(onPressed: _minutes == null ? null : () => Navigator.pop(context, _minutes), child: const Text('Save')),
        ],
      );
}
