import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:taskflow_core/date_parser.dart' show formatDate;
import 'package:taskflow_core/progress.dart';

import 'catalog.dart';
import 'common.dart';

/// Goals, streaks, Karma and charts (FR-K1..K5).
class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

enum _Range { days, weeks, months }

class _ProgressScreenState extends State<ProgressScreen> {
  _Range _range = _Range.days;

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    return Scaffold(
      appBar: AppBar(title: const Text('Productivity')),
      body: Live<Progress>(
        id: '${catalog.dailyGoal}/${catalog.weeklyGoal}/${catalog.daysOff.join()}/${catalog.vacations.length}/${catalog.weekStart}',
        create: () => repo.watchProgress(catalog.goals),
        builder: (context, p) {
          if (p == null) return const SizedBox.shrink();
          final k = p.karma;
          final cs = Theme.of(context).colorScheme;
          final daily = p.dailyStreak, weekly = p.weeklyStreak;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.emoji_events_outlined, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(k.level.name, style: Theme.of(context).textTheme.titleLarge),
                    const Spacer(),
                    Text('${k.points} Karma', style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: k.progress, minHeight: 8, borderRadius: BorderRadius.circular(8)),
                  const SizedBox(height: 6),
                  Text(
                    k.next == null ? 'Top level reached' : '${k.next!.from - k.points} more to reach ${k.next!.name}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _StreakCard(title: 'Daily streak', goalText: catalog.dailyGoal == 0 ? 'Goal off' : 'Goal ${catalog.dailyGoal} a day', streak: daily, unit: 'days')),
              const SizedBox(width: 8),
              Expanded(child: _StreakCard(title: 'Weekly streak', goalText: catalog.weeklyGoal == 0 ? 'Goal off' : 'Goal ${catalog.weeklyGoal} a week', streak: weekly, unit: 'weeks')),
            ]),
            const SizedBox(height: 16),
            Text('Tasks completed', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<_Range>(
              segments: const [
                ButtonSegment(value: _Range.days, label: Text('Days')),
                ButtonSegment(value: _Range.weeks, label: Text('Weeks')),
                ButtonSegment(value: _Range.months, label: Text('Months')),
              ],
              selected: {_range},
              onSelectionChanged: (s) => setState(() => _range = s.first),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 200,
              child: switch (_range) {
                _Range.days => _BarChart(bars: p.perDay(14), label: (d) => DateFormat('d').format(d), goal: catalog.dailyGoal, key: const ValueKey('chart-days')),
                _Range.weeks => _BarChart(bars: p.perWeek(12), label: (d) => DateFormat('d MMM').format(d), goal: catalog.weeklyGoal, key: const ValueKey('chart-weeks')),
                _Range.months => _BarChart(bars: p.perMonth(12), label: (d) => DateFormat('MMM').format(d), goal: 0, key: const ValueKey('chart-months')),
              },
            ),
            const SizedBox(height: 24),
            Text('Goals', style: Theme.of(context).textTheme.titleMedium),
            _GoalRow(
              label: 'Daily goal',
              value: catalog.dailyGoal,
              limit: 100,
              onChanged: (v) => repo.setSetting('dailyGoal', '$v'),
            ),
            _GoalRow(
              label: 'Weekly goal',
              value: catalog.weeklyGoal,
              limit: 700,
              step: 5,
              onChanged: (v) => repo.setSetting('weeklyGoal', '$v'),
            ),
            const SizedBox(height: 8),
            Text('Days off', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Wrap(spacing: 6, children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d - 1]),
                  selected: catalog.daysOff.contains(d),
                  onSelected: (on) {
                    final next = {...catalog.daysOff};
                    on ? next.add(d) : next.remove(d);
                    repo.setSetting('daysOff', (next.toList()..sort()).join(','));
                  },
                ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Vacation mode'),
              subtitle: const Text('Freezes your streaks while you are away.'),
              value: catalog.onVacation,
              onChanged: (on) {
                final today = formatDate(DateTime(repo.now.year, repo.now.month, repo.now.day));
                final list = [...catalog.vacations];
                if (on) {
                  list.add((today, null));
                } else {
                  final i = list.lastIndexWhere((r) => r.$2 == null);
                  if (i >= 0) list[i] = (list[i].$1, today);
                }
                repo.setSetting('vacations', Goals.encodeVacations(list));
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Celebrate reaching the daily goal'),
              value: catalog.celebrate,
              onChanged: (v) => repo.setSetting('karma.celebrate', '$v'),
            ),
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('How Karma works'),
              children: const [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Karma is this app\'s own score, not Todoist\'s (that formula is not public). It is worked out from your history, so it is the same on every device and never changes between updates.\n\n'
                    '• 10 points for each completed task\n'
                    '• +5 if it was done on or before its due date (or had none)\n'
                    '• +9, +6 or +3 for priority 1, 2 or 3\n'
                    '• +20 for each day you reach the daily goal, +50 for each week you reach the weekly goal\n'
                    '• −1 point for each day beyond the third that an open task is overdue, at most 14 per task\n\n'
                    'The total never goes below 0. Levels: Beginner 0, Novice 500, Intermediate 2,500, Professional 5,000, Expert 7,500, Master 10,000, Grandmaster 20,000, Enlightened 30,000.',
                  ),
                ),
              ],
            ),
          ]);
        },
      ),
    );
  }
}

class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.title, required this.goalText, required this.streak, required this.unit});
  final String title, goalText, unit;
  final Streak streak;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Icon(Icons.local_fire_department_outlined, color: streak.current > 0 ? Colors.deepOrange : cs.outline),
            const SizedBox(width: 4),
            Text('${streak.current}', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(width: 4),
            Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(unit)),
          ]),
          Text('Longest ${streak.longest}', style: TextStyle(color: cs.outline)),
          Text(goalText, style: TextStyle(color: cs.outline, fontSize: 12)),
        ]),
      ),
    );
  }
}

class _GoalRow extends StatelessWidget {
  const _GoalRow({required this.label, required this.value, required this.limit, required this.onChanged, this.step = 1});
  final String label;
  final int value, limit, step;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text(value == 0 ? 'Off' : '$value tasks'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: 'Fewer $label',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: value > 0 ? () => onChanged(max(0, value - step)) : null,
          ),
          IconButton(
            tooltip: 'More $label',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: value < limit ? () => onChanged(min(limit, value + step)) : null,
          ),
        ]),
      );
}

/// A small bar chart with a dashed goal line, drawn without a chart package.
class _BarChart extends StatelessWidget {
  const _BarChart({super.key, required this.bars, required this.label, required this.goal});
  final List<(DateTime, int)> bars;
  final String Function(DateTime) label;
  final int goal;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final top = max(1, max(bars.map((b) => b.$2).fold(0, max), goal));
    return Semantics(
      label: 'Bar chart: ${bars.map((b) => '${label(b.$1)} ${b.$2}').join(', ')}',
      child: LayoutBuilder(builder: (context, box) {
        const labelH = 22.0, valueH = 16.0;
        final plotH = box.maxHeight - labelH - valueH;
        final slot = box.maxWidth / bars.length;
        return Stack(children: [
          if (goal > 0)
            Positioned(
              left: 0,
              right: 0,
              top: valueH + plotH * (1 - goal / top),
              child: CustomPaint(size: Size(box.maxWidth, 1), painter: _DashedLine(cs.primary.withValues(alpha: 0.6))),
            ),
          for (var i = 0; i < bars.length; i++)
            Positioned(
              left: i * slot,
              width: slot,
              top: 0,
              bottom: 0,
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                SizedBox(height: valueH, child: Text(bars[i].$2 == 0 ? '' : '${bars[i].$2}', style: const TextStyle(fontSize: 10))),
                Container(
                  height: plotH * bars[i].$2 / top,
                  margin: EdgeInsets.symmetric(horizontal: slot * 0.15),
                  decoration: BoxDecoration(color: cs.primary, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))),
                ),
                SizedBox(
                  height: labelH,
                  child: Center(child: Text(label(bars[i].$1), style: TextStyle(fontSize: bars.length > 8 ? 9 : 11, color: cs.outline), maxLines: 1, overflow: TextOverflow.clip)),
                ),
              ]),
            ),
        ]);
      }),
    );
  }
}

class _DashedLine extends CustomPainter {
  _DashedLine(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 1.2;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(min(x + 4, size.width), 0), paint);
    }
  }

  @override
  bool shouldRepaint(_DashedLine old) => old.color != color;
}

/// Confetti over the app for a couple of seconds when the daily goal is reached (FR-K5).
class CelebrationHost extends StatefulWidget {
  const CelebrationHost({super.key, required this.catalog, required this.child});
  final Catalog catalog;
  final Widget child;

  @override
  State<CelebrationHost> createState() => _CelebrationHostState();
}

class _CelebrationHostState extends State<CelebrationHost> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  int _seen = 0;

  @override
  void initState() {
    super.initState();
    _seen = widget.catalog.celebrations;
    widget.catalog.addListener(_check);
  }

  void _check() {
    if (widget.catalog.celebrations != _seen) {
      _seen = widget.catalog.celebrations;
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.click);
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    widget.catalog.removeListener(_check);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => _c.isAnimating
                  ? Stack(children: [
                      CustomPaint(size: Size.infinite, painter: _Confetti(_c.value)),
                      Align(
                        alignment: const Alignment(0, -0.2),
                        child: Opacity(
                          opacity: (1 - (_c.value - 0.6).clamp(0, 0.4) / 0.4).toDouble(),
                          child: Material(
                            color: Colors.transparent,
                            child: Text('Daily goal reached!', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                          ),
                        ),
                      ),
                    ])
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ]);
}

class _Confetti extends CustomPainter {
  _Confetti(this.t);
  final double t;
  static const _colors = [Color(0xFFE53935), Color(0xFFFDD835), Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA), Color(0xFFFB8C00)];

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = Random(7); // the same pieces every time; only time moves them
    for (var i = 0; i < 90; i++) {
      final x0 = rnd.nextDouble() * size.width;
      final speed = 0.6 + rnd.nextDouble() * 0.8;
      final sway = (rnd.nextDouble() - 0.5) * 120;
      final y = -20 + (size.height + 40) * (t * speed);
      final x = x0 + sin(t * 8 + i) * 20 + sway * t;
      final paint = Paint()..color = _colors[i % _colors.length].withValues(alpha: (1 - t * 0.7).clamp(0, 1));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(t * 10 + i);
      canvas.drawRect(const Rect.fromLTWH(-4, -2, 8, 4), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Confetti old) => old.t != t;
}
