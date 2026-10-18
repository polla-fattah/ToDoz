import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/core/quick_add.dart';

// Wednesday 14 October 2026.
final now = DateTime(2026, 10, 14, 9);

void main() {
  test('the 1.0 example line', () {
    final r = parseQuickAdd('Review paper tomorrow p1 @reading #work', now);
    expect(r.title, 'Review paper');
    expect(r.due, DateTime(2026, 10, 15));
    expect(r.priority, 1);
    expect(r.labels, ['reading']);
    expect(r.projectName, 'work');
    expect(r.sectionName, isNull);
  });

  test('a plain line is left alone', () {
    final r = parseQuickAdd('Buy milk', now);
    expect(r.title, 'Buy milk');
    expect(r.due, isNull);
    expect(r.priority, isNull);
    expect(r.labels, isEmpty);
    expect(r.tokens, isEmpty);
  });

  test('% and @ both mark labels, duplicates collapse, case is folded', () {
    final r = parseQuickAdd('Plan trip %Travel @travel %Errands', now);
    expect(r.labels, ['travel', 'errands']);
    expect(r.title, 'Plan trip');
  });

  test('a section is recognised only after a project', () {
    final withProject = parseQuickAdd('Fix bug #work /backlog', now);
    expect(withProject.projectName, 'work');
    expect(withProject.sectionName, 'backlog');
    expect(withProject.title, 'Fix bug');

    final without = parseQuickAdd('Read a/b notes /backlog', now);
    expect(without.sectionName, isNull);
    expect(without.title, 'Read a/b notes /backlog');
  });

  test('quoted names may contain spaces', () {
    final r = parseQuickAdd('Draft #"Work & Research" /"In Progress" outline', now);
    expect(r.projectName, 'Work & Research');
    expect(r.sectionName, 'In Progress');
    expect(r.title, 'Draft outline');
  });

  test('priority must be a whole word between p1 and p4', () {
    expect(parseQuickAdd('Ship p4', now).priority, 4);
    expect(parseQuickAdd('Ship p5', now).priority, isNull);
    expect(parseQuickAdd('Ship p1x', now).priority, isNull);
    expect(parseQuickAdd('Ship p1x', now).title, 'Ship p1x');
  });

  test('email addresses and mid-word symbols are not tokens', () {
    final r = parseQuickAdd('Write to sam@example.com about c#', now);
    expect(r.labels, isEmpty);
    expect(r.projectName, isNull);
    expect(r.title, 'Write to sam@example.com about c#');
  });

  test('tokens inside labels do not leak into the date parser', () {
    final r = parseQuickAdd('Pay rent @monday', now);
    expect(r.labels, ['monday']);
    expect(r.due, isNull);
  });

  test('smart date recognition can be switched off', () {
    final r = parseQuickAdd('Plan for tomorrow p2', now, parseDates: false);
    expect(r.due, isNull);
    expect(r.title, 'Plan for tomorrow');
    expect(r.priority, 2);
  });

  test('token spans point at the original text for live highlighting', () {
    const line = 'Call Sam next fri p2 @work';
    final r = parseQuickAdd(line, now);
    String text(QuickAddKind k) {
      final t = r.tokens.firstWhere((t) => t.kind == k);
      return line.substring(t.start, t.end);
    }

    expect(text(QuickAddKind.date), 'next fri');
    expect(text(QuickAddKind.priority), 'p2');
    expect(text(QuickAddKind.label), '@work');
    expect(r.title, 'Call Sam');
  });

  test('a line that is only tokens leaves an empty title', () {
    final r = parseQuickAdd('tomorrow p1', now);
    expect(r.title, isEmpty);
    expect(r.due, DateTime(2026, 10, 15));
  });

  test('normaliseName matches 1.0 project-id style references', () {
    expect(normaliseName('Work & Research'), 'work-&-research');
    expect(normaliseName('  Personal  '), 'personal');
    expect(normaliseName('Work Research'), 'work-research');
  });
}
